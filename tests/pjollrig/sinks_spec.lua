local H = require("helpers")

local ctx

local function setup_env()
  ctx = H.setup()
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

describe("pjollrig sink helpers", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("formats comments as an agent-ready markdown review", function()
    local path = H.write_project_file(ctx, "src/sinks.lua", {
      "local value = 1",
      "return value",
    })
    local record = {
      body = "first line\nsecond line",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 1, 0 } },
      uri = "file://" .. path,
    }

    local text = require("pjollrig.sinks.helpers").format_markdown_review({
      record,
    }, {
      pre_text = "Before comments",
      post_text = "After comments",
    })

    assert.is_truthy(text:find("Pjollrig review (1 comment):", 1, true))
    assert.is_truthy(text:find("Before comments", 1, true))
    assert.is_truthy(text:find("## M1 src/sinks.lua:1-2", 1, true))
    assert.is_truthy(text:find("first line\nsecond line", 1, true))
    assert.is_truthy(text:find("After comments", 1, true))
  end)

  it("formats raw codediff URIs as project-relative paths", function()
    local comment = {
      body = "from old codediff record",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
      uri = ("codediff:///%s///fedfddb447cd91e8042810ce517e84c6701f55f0/infra/terraform-gcp-core/sherlog.tf"):format(
        ctx.root
      ),
    }

    local text = require("pjollrig.sinks.helpers").format_markdown_review({ comment })

    assert.is_truthy(text:find("## M1 infra/terraform-gcp-core/sherlog.tf:2", 1, true))
    assert.is_nil(text:find("codediff:", 1, true))
  end)

  it("registers builtin integrations from sink config", function()
    require("pjollrig.sinks")._reset()
    local bin = H.fake_cmux(ctx)
    require("pjollrig.sinks").setup({
      github = false,
      clipboard = {
        pre_text = "clipboard header",
        post_text = "clipboard footer",
      },
      cmux = {
        enabled = true,
        command = bin,
        workspace_id = "workspace-1",
        pre_text = "cmux header",
        post_text = "cmux footer",
      },
    })

    local names = require("pjollrig.sinks").list()
    assert.are.same({ "clipboard", "cmux" }, names)
    -- The socket sink registers (dispatchable by name from a review job)
    -- but is hidden from selection listing: it can never validate without
    -- a caller-supplied ctx.socket.
    assert.is_truthy(require("pjollrig.sinks").get("socket"))
    assert.are.equal("sink", require("pjollrig.sinks").get("clipboard").type)
    assert.are.equal("integration", require("pjollrig.sinks").get("cmux").type)
    assert.is_false(require("pjollrig.sinks").get("cmux").clear_on_success)
    assert.are.equal("clipboard header", require("pjollrig.sinks").get("clipboard").pre_text)
    assert.are.equal("clipboard footer", require("pjollrig.sinks").get("clipboard").post_text)
    assert.are.equal("cmux header", require("pjollrig.sinks").get("cmux").pre_text)
    assert.are.equal("cmux footer", require("pjollrig.sinks").get("cmux").post_text)
  end)

  it("wraps clipboard sink output with configured pre and post text", function()
    local copied_reg, copied
    local old_setreg = vim.fn.setreg
    vim.fn.setreg = function(reg, value, ...)
      copied_reg = reg
      copied = value
      return old_setreg("", value, ...)
    end
    local path = H.write_project_file(ctx, "src/clip.lua", {
      "return true",
    })
    local record = {
      body = "clipboard note",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      uri = "file://" .. path,
    }
    local sink = require("pjollrig.sinks.clipboard").setup({
      pre_text = "Review starts",
      post_text = "Review ends",
    })

    local ok, err = pcall(function()
      sink.send({ record }, {}, function() end)
    end)
    vim.fn.setreg = old_setreg
    if not ok then
      error(err)
    end
    assert.are.equal("+", copied_reg)
    assert.are.equal("Review starts\n\nsrc/clip.lua:1: clipboard note\n\nReview ends", copied)
  end)

  it("can paste a cmux review without auto-submitting", function()
    local bin, log = H.fake_cmux(ctx)
    local path = H.write_project_file(ctx, "src/manual.lua", {
      "return true",
    })
    local comment = {
      body = "manual submit note",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      uri = "file://" .. path,
    }
    local sink = require("pjollrig.sinks.cmux").setup({
      command = bin,
      workspace_id = "workspace-1",
      auto_submit = false,
      cache = false,
      agent_state_dir = ctx.state,
    })

    local sent
    sink.send({ comment }, { surface = "surface:2" }, function(ok, err)
      sent = { ok = ok, err = err }
    end)
    -- The send path is asynchronous (vim.system callbacks); wait for the cb.
    vim.wait(2000, function()
      return sent ~= nil
    end)

    local log_text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_true(sent.ok)
    assert.is_nil(sent.err)
    assert.is_truthy(log_text:find("paste%-buffer\tsurface:2\tpjollrig%-", 1, false))
    assert.is_truthy(log_text:find("manual submit note", 1, true))
    assert.is_nil(log_text:find("key\tsurface:2\tenter", 1, true))
  end)

  it("chunks a large multiline cmux review into byte-exact pieces", function()
    local bin, log = H.fake_cmux(ctx)

    -- Build a large multi-line payload (> 4KB, many lines) so the sink must
    -- split it across several paste-buffer chunks.
    local lines = {}
    for i = 1, 200 do
      table.insert(lines, ("M%d some-file.lua:%d: this is review comment number %d"):format(i, i, i))
    end
    local payload = table.concat(lines, "\n")
    assert.is_true(#payload > 4096)

    local chunk_bytes = 1024
    local sink = require("pjollrig.sinks.cmux").setup({
      command = bin,
      workspace_id = "workspace-1",
      cache = false,
      agent_state_dir = ctx.state,
      paste_chunk_bytes = chunk_bytes,
      paste_chunk_delay_ms = 0,
      submit_delay_ms = 0,
    })

    -- Drive send_text through the public sink by passing a record whose
    -- formatted markdown body is our large payload, then send directly.
    local record = {
      body = payload,
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      uri = "file://" .. ctx.root .. "/big.lua",
    }

    local sent
    sink.send({ record }, { surface = "surface:2" }, function(ok, err)
      sent = { ok = ok, err = err }
    end)
    -- The send path is asynchronous (vim.system callbacks); wait for the cb.
    vim.wait(2000, function()
      return sent ~= nil
    end)

    assert.is_true(sent.ok)
    assert.is_nil(sent.err)

    -- The exact text the sink formatted and sent to the agent.
    local expected = require("pjollrig.sinks.helpers").format_markdown_review({ record }, {})
    assert.is_truthy(expected:find(payload, 1, true))

    -- Read raw log bytes. The fake-cmux command logs are not safe to split on
    -- newlines (chunk payloads embed their own newlines), so count CLI
    -- invocations by scanning the raw bytes for each command token.
    local function read_bytes(path)
      local fh = assert(io.open(path, "rb"))
      local data = fh:read("*a") or ""
      fh:close()
      return data
    end
    local function count_occurrences(haystack, needle)
      local count, pos = 0, 1
      while true do
        local s = haystack:find(needle, pos, true)
        if not s then
          break
        end
        count = count + 1
        pos = s + 1
      end
      return count
    end

    local raw_log = read_bytes(log)
    local set_count = count_occurrences(raw_log, "set-buffer\t")
    local paste_count = count_occurrences(raw_log, "paste-buffer\tsurface:2\t")

    -- Chunking happened: multiple set-buffer + paste-buffer pairs.
    assert.is_true(set_count > 1, "expected more than one chunk, got " .. tostring(set_count))
    assert.are.equal(set_count, paste_count)

    -- Pastes are strictly ordered by chunk index even though the
    -- set-buffer uploads may complete in any order.
    local paste_order = {}
    for idx in raw_log:gmatch("paste%-buffer\tsurface:2\tpjollrig%-%d+%-(%d+)\t") do
      table.insert(paste_order, tonumber(idx))
    end
    assert.are.equal(paste_count, #paste_order)
    for i, idx in ipairs(paste_order) do
      assert.are.equal(i, idx)
    end

    -- The sink never falls back to `cmux send` for the multiline payload.
    assert.is_nil(raw_log:find("\nsend\tsurface:2", 1, true))
    assert.is_nil(raw_log:find("^send\tsurface:2"))

    -- Each chunk is persisted to its own byte-exact buffer file named
    -- pjollrig-<stamp>-<idx>. Order by the numeric idx suffix and verify
    -- byte-exact reassembly + the per-chunk byte bound.
    local buffer_files = vim.fn.glob(log .. ".buffer.*", false, true)
    assert.are.equal(set_count, #buffer_files)
    table.sort(buffer_files, function(a, b)
      return (tonumber(a:match("%-(%d+)$")) or 0) < (tonumber(b:match("%-(%d+)$")) or 0)
    end)

    local reassembled = {}
    for _, file in ipairs(buffer_files) do
      local chunk = read_bytes(file)
      assert.is_true(#chunk <= chunk_bytes, ("chunk %s is %d bytes (> %d)"):format(file, #chunk, chunk_bytes))
      table.insert(reassembled, chunk)
    end
    assert.are.equal(expected, table.concat(reassembled))

    -- Exactly one Enter keypress at the end (auto_submit default).
    assert.are.equal(1, count_occurrences(raw_log, "key\tsurface:2\tenter"))
  end)

  it("keeps enabled cmux disabled when unavailable", function()
    require("pjollrig.sinks")._reset()
    require("pjollrig.sinks").setup({
      clipboard = false,
      github = false,
      cmux = {
        enabled = true,
        command = ctx.state .. "/missing-cmux",
        workspace_id = "workspace-1",
      },
    })

    assert.is_nil(require("pjollrig.sinks").get("cmux"))
    -- Socket stays registered but hidden, so nothing is listed for selection.
    assert.are.same({}, require("pjollrig.sinks").list())
    assert.is_truthy(require("pjollrig.sinks").get("socket"))
  end)

  it("hides the socket sink from selection listing but keeps it registered", function()
    require("pjollrig.sinks")._reset()
    require("pjollrig.sinks").setup({
      clipboard = false,
      github = false,
      cmux = false,
    })

    local sinks = require("pjollrig.sinks")
    assert.are.same({}, sinks.list())
    local socket = sinks.get("socket")
    assert.is_truthy(socket)
    assert.is_true(socket.hidden)
  end)

  it("discovers Pi from cmux resume metadata before scanning stale screen content", function()
    local bin = H.fake_cmux(ctx, {
      surfaces = {
        { id = "surface-current", ref = "surface:1", title = "pjollrig.nvim" },
        {
          id = "surface-pi",
          ref = "surface:2",
          title = "dotfiles",
          resume_binding = { kind = "pi", name = "Pi" },
        },
      },
      tree = {
        'surface:1 [terminal] "pjollrig.nvim" tty=ttys001 here',
        'surface:2 [terminal] "dotfiles" tty=ttys002',
      },
      screens = {
        ["surface:2"] = "old notes mentioning OpenAI Codex\nContext 0 tokens",
      },
    })

    local surfaces, err = require("pjollrig.sinks.cmux").list_agent_surfaces({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      cache = false,
      agent_state_dir = ctx.state,
    })

    assert.is_nil(err)
    assert.are.equal(1, #surfaces)
    assert.are.equal("surface:2", surfaces[1].ref)
    assert.are.equal("Pi", surfaces[1].agent)
    assert.are.equal("metadata", surfaces[1].detected_by)
  end)

  it("discovers Pi from its unicode cmux title", function()
    local bin = H.fake_cmux(ctx, {
      surfaces = {
        { id = "surface-current", ref = "surface:1", title = "pjollrig.nvim" },
        { id = "surface-pi", ref = "surface:2", title = "π - dotfiles" },
      },
      tree = {
        'surface:1 [terminal] "pjollrig.nvim" tty=ttys001 here',
        'surface:2 [terminal] "π - dotfiles" tty=ttys002',
      },
      screens = {},
    })

    local surfaces, err = require("pjollrig.sinks.cmux").list_agent_surfaces({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      screen_fallback = false,
      cache = false,
      agent_state_dir = ctx.state,
    })

    assert.is_nil(err)
    assert.are.equal(1, #surfaces)
    assert.are.equal("surface:2", surfaces[1].ref)
    assert.are.equal("Pi", surfaces[1].agent)
    assert.are.equal("title", surfaces[1].detected_by)
  end)

  it("discovers a generic-titled split pane by reading the agent screen", function()
    local bin = H.fake_cmux(ctx, {
      surfaces = {
        { id = "surface-current", ref = "surface:1", title = "pjollrig.nvim" },
        { id = "surface-agent", ref = "surface:2", title = "pjollrig.nvim" },
      },
      tree = {
        'surface:1 [terminal] "pjollrig.nvim" tty=ttys001 here',
        'surface:2 [terminal] "pjollrig.nvim" tty=ttys002',
      },
      screens = {
        ["surface:2"] = "OpenAI Codex\nContext 0 tokens\nReady",
      },
    })

    local surfaces, err = require("pjollrig.sinks.cmux").list_agent_surfaces({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      cache = false,
      agent_state_dir = ctx.state,
    })

    assert.is_nil(err)
    assert.are.equal(1, #surfaces)
    assert.are.equal("surface:2", surfaces[1].ref)
    assert.are.equal("Codex", surfaces[1].agent)
    assert.are.equal("screen", surfaces[1].detected_by)
  end)

  it("screen-scans remaining panes after finding another agent by title", function()
    local bin = H.fake_cmux(ctx, {
      surfaces = {
        { id = "surface-current", ref = "surface:1", title = "pjollrig.nvim" },
        { id = "surface-amp", ref = "surface:2", title = "Amp" },
        { id = "surface-codex", ref = "surface:3", title = "pjollrig.nvim" },
      },
      tree = {
        'surface:1 [terminal] "pjollrig.nvim" tty=ttys001 here',
        'surface:2 [terminal] "Amp" tty=ttys002',
        'surface:3 [terminal] "pjollrig.nvim" tty=ttys003',
      },
      screens = {
        ["surface:3"] = "OpenAI Codex\nContext 0 tokens\nReady",
      },
    })

    local surfaces, err = require("pjollrig.sinks.cmux").list_agent_surfaces({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      cache = false,
      agent_state_dir = ctx.state,
    })

    assert.is_nil(err)
    assert.are.equal(2, #surfaces)
    local by_ref = {}
    for _, surface in ipairs(surfaces) do
      by_ref[surface.ref] = surface
    end
    assert.are.equal("title", by_ref["surface:2"].detected_by)
    assert.are.equal("screen", by_ref["surface:3"].detected_by)
    assert.are.equal("Codex", by_ref["surface:3"].agent)
  end)

  it("errors when registering a sink under an already-registered name", function()
    local sinks = require("pjollrig.sinks")
    sinks.register({
      name = "dup",
      send = function(_, _, cb)
        cb(true)
      end,
    })

    local ok, err = pcall(sinks.register, {
      name = "dup",
      send = function(_, _, cb)
        cb(true)
      end,
    })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("already registered", 1, true))
  end)

  it("re-registers builtins on repeated setup without duplicate errors", function()
    local sinks = require("pjollrig.sinks")
    sinks._reset()
    sinks.setup({ github = false, cmux = false })
    sinks.setup({ github = false, cmux = false })

    assert.are.same({ "clipboard" }, sinks.list())
  end)

  it("requires a dispatch callback", function()
    local sinks = require("pjollrig.sinks")
    sinks.register({
      name = "needs-cb",
      send = function(_, _, cb)
        cb(true)
      end,
    })

    local ok, err = pcall(sinks.dispatch, "needs-cb", {}, {})

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("cb", 1, true))
  end)

  it("reports thrown validate and send callbacks as dispatch failures", function()
    local sinks = require("pjollrig.sinks")
    sinks.register({
      name = "bad-validate",
      send = function(_, _, cb)
        cb(true)
      end,
      validate = function()
        error("validate exploded")
      end,
    })
    sinks.register({
      name = "bad-send",
      send = function()
        error("send exploded")
      end,
    })

    local validate_result
    sinks.dispatch("bad-validate", {}, {}, function(ok, err)
      validate_result = { ok = ok, err = err }
    end)
    assert.is_false(validate_result.ok)
    assert.is_truthy(validate_result.err:find("validate failed", 1, true))

    local send_result
    sinks.dispatch("bad-send", {}, {}, function(ok, err)
      send_result = { ok = ok, err = err }
    end)
    assert.is_false(send_result.ok)
    assert.is_truthy(send_result.err:find("send failed", 1, true))
  end)

  it("detects pi from wrapped process commands", function()
    local internal = require("pjollrig.sinks.cmux")._internal
    assert.are.equal("Pi", internal.detect_agent_from_command("node /nix/store/abc/pi-coding-agent/dist/main.js"))
    assert.are.equal("Pi", internal.detect_agent_from_command("/usr/local/bin/pi --resume"))
    assert.are.equal("Pi", internal.detect_agent_from_command("pi"))
  end)

  it("does not detect pi from bare pi substrings in commands", function()
    local internal = require("pjollrig.sinks.cmux")._internal
    assert.is_nil(internal.detect_agent_from_command("pip install requests"))
    assert.is_nil(internal.detect_agent_from_command("spotify"))
    assert.is_nil(internal.detect_agent_from_command("vim pi.txt"))
  end)

  it("does not detect pi from argument tokens of unrelated commands", function()
    local internal = require("pjollrig.sinks.cmux")._internal
    assert.is_nil(internal.detect_agent_from_command("sudo -u pi bash"))
    assert.is_nil(internal.detect_agent_from_command("chown pi file"))
    assert.is_nil(internal.detect_agent_from_command("ssh -l pi host"))
    assert.is_nil(internal.detect_agent_from_command("ls /home/pi"))
  end)

  it("detects pi from screen contents", function()
    local internal = require("pjollrig.sinks.cmux")._internal
    assert.are.equal("Pi", internal.detect_agent_from_screen("π  dotfiles\nready for input"))
    assert.are.equal("Pi", internal.detect_agent_from_screen("node running pi-coding-agent v1"))
  end)

  it("does not detect pi from plain prose containing pi in screens", function()
    local internal = require("pjollrig.sinks.cmux")._internal
    assert.is_nil(internal.detect_agent_from_screen("we computed pi to 10 digits\nnothing agent-like here"))
  end)
end)
