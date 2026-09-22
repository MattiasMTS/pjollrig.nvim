local H = require("helpers")
local W = require("pjollrig.sinks.wezterm")
local ctx, bin, old_select, picks, selected, panes

local function write_panes(value)
  vim.fn.writefile({ vim.json.encode(value) }, ctx.state .. "/panes")
end

local function contents(name)
  local path = ctx.state .. "/" .. name
  return vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path, "b"), "\n") or nil
end

local function sink(opts)
  return W.setup(vim.tbl_extend("force", { command = bin, current_pane = 1, submit_delay_ms = 0 }, opts or {}))
end

local function send(spec, dispatch_ctx, comments)
  local result
  spec.send(
    comments or { { uri = "file:///project/a.lua", body = "review", range = { start = { 0, 0 } } } },
    dispatch_ctx or {},
    function(ok, err)
      assert.is_nil(result, "send completed twice")
      result = { ok = ok, err = err }
    end
  )
  assert.is_true(
    vim.wait(3000, function()
      return result ~= nil
    end, 10),
    "send did not finish"
  )
  return result
end

describe("WezTerm sink", function()
  before_each(function()
    ctx = H.setup()
    bin = ctx.state .. "/wezterm"
    vim.fn.writefile({
      "#!/bin/sh",
      'cd "$(dirname "$0")" || exit 1',
      'printf "%s\\n" "$*" >> commands',
      '[ "$1" = cli ] && [ "$2" = --no-auto-start ] || exit 2',
      'case "$3" in',
      "list) if [ -f fail-list ]; then echo unavailable >&2; exit 1; fi; cat panes ;;",
      "send-text)",
      '  if [ "$6" = --no-paste ]; then',
      "    cat > submit",
      "    [ ! -f fail-submit ] || exit 1",
      "  else",
      "    cat > payload",
      '    printf "%s" "$5" > target',
      "    [ ! -f fail-paste ] || exit 1",
      "  fi ;;",
      "*) exit 2 ;;",
      "esac",
    }, bin)
    vim.fn.setfperm(bin, "rwx------")
    panes = {
      { pane_id = 1, tab_id = 10, title = "nvim" },
      { pane_id = 2, tab_id = 10, title = "Fix tests", cwd = "file:///project" },
      { pane_id = 3, tab_id = 20, title = "other tab" },
      { pane_id = 4, tab_id = 10, title = "shell" },
    }
    write_panes(panes)
    picks, selected = 0, 1
    old_select = require("pjollrig.ui.select").select
    require("pjollrig.ui.select").select = function(choices, opts, cb)
      picks = picks + 1
      assert.are.same(
        { 2, 4 },
        vim.tbl_map(function(p)
          return p.pane_id
        end, choices)
      )
      assert.is_truthy(opts.format_item(choices[1]):find("Fix tests", 1, true))
      cb(choices[selected])
    end
  end)

  after_each(function()
    require("pjollrig.ui.select").select = old_select
    H.teardown(ctx)
  end)

  it("registers only with an executable and current pane, and can be disabled", function()
    assert.is_false(W.is_available({ command = bin }))
    assert.is_false(W.is_available({ command = bin .. "missing", current_pane = 1 }))
    assert.is_true(W.is_available({ command = bin, current_pane = 1 }))
    local registry = require("pjollrig.sinks")
    registry.setup({ clipboard = false, cmux = false, github = false, wezterm = { command = bin, current_pane = 1 } })
    assert.are.same({ "wezterm" }, registry.list())
    assert.is_true(registry.get("wezterm").clear_on_success)
    registry.setup({ clipboard = false, cmux = false, github = false, wezterm = false })
    assert.are.same({}, registry.list())
  end)

  it("picks a sibling and preserves a large Unicode multiline payload via stdin", function()
    local comments = { { uri = "file:///project/a.lua", body = string.rep("å π 😀 `code` $HOME\n\n", 4000) } }
    local opts = { pre_text = "Please fix", post_text = "Thank you" }
    assert.is_true(send(sink(opts), nil, comments).ok)
    assert.are.equal(require("pjollrig.sinks.helpers").format_markdown_review(comments, opts), contents("payload"))
    assert.are.equal("2", contents("target"))
    assert.is_nil(contents("submit"))
    assert.are.equal(1, picks)
  end)

  it("rejects invalid submission and timeout options before sending", function()
    for _, opts in ipairs({
      { auto_submit = "false" },
      { clear_on_success = "false" },
      { submit_delay_ms = -1 },
      { submit_delay_ms = "120" },
      { submit_delay_ms = math.huge },
      { timeout_ms = 0 },
      { timeout_ms = 1.5 },
    }) do
      assert.is_false(pcall(sink, opts))
    end
    assert.is_nil(contents("commands"))
  end)

  it("does not stay busy after a synchronous formatting error", function()
    local spec = sink()
    assert.is_false(pcall(spec.send, false, {}, function() end))
    assert.is_true(send(spec).ok)
  end)

  it("remembers the target and allows explicit reselection", function()
    local spec = sink()
    assert.is_true(send(spec).ok)
    selected = 2
    assert.is_true(send(spec).ok)
    assert.are.equal("2", contents("target"))
    assert.are.equal(1, picks)
    assert.is_true(send(spec, { pick = true }).ok)
    assert.are.equal("4", contents("target"))
    assert.are.equal(2, picks)
  end)

  it("repicks when the remembered pane moves to another tab", function()
    local spec = sink()
    assert.is_true(send(spec).ok)
    panes[2].tab_id = 20
    write_panes(panes)
    require("pjollrig.ui.select").select = function(choices, _, cb)
      assert.are.same(
        { 4 },
        vim.tbl_map(function(p)
          return p.pane_id
        end, choices)
      )
      cb(choices[1])
    end
    assert.is_true(send(spec).ok)
    assert.are.equal("4", contents("target"))
  end)

  it("rejects a pane closed while the picker is open", function()
    require("pjollrig.ui.select").select = function(choices, _, cb)
      write_panes({ panes[1], panes[4] })
      cb(choices[1])
    end
    local result = send(sink())
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("no longer", 1, true))
    assert.is_nil(contents("payload"))
  end)

  it("cancels without sending and can send again", function()
    selected = 99
    local spec = sink()
    assert.are.equal("cancelled", send(spec).err)
    assert.is_nil(contents("payload"))
    selected = 1
    assert.is_true(send(spec).ok)
  end)

  it("submits separately after pasting when enabled", function()
    assert.is_true(send(sink({ auto_submit = true })).ok)
    assert.are.equal("\r", contents("submit"))
    assert.is_truthy(contents("commands"):find("send-text --pane-id 2 --no-paste", 1, true))
  end)

  it("does not submit or retry after paste failure", function()
    vim.fn.writefile({}, ctx.state .. "/fail-paste")
    local result = send(sink({ auto_submit = true }))
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("check the target pane", 1, true))
    assert.is_nil(contents("submit"))
    local _, count = contents("commands"):gsub("send%-text", "")
    assert.are.equal(1, count)
  end)

  it("reports submission failure distinctly from paste failure", function()
    vim.fn.writefile({}, ctx.state .. "/fail-submit")
    local result = send(sink({ auto_submit = true }))
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("review pasted but submission failed", 1, true))
    assert.is_truthy(contents("payload"))
  end)

  it("reports missing source, no siblings, malformed JSON and discovery failures", function()
    for _, case in ipairs({
      { value = {}, message = "Neovim's pane" },
      { value = { panes[1] }, message = "no other WezTerm panes" },
      { value = { false }, message = "invalid pane entry" },
      { value = { bad = true }, message = "invalid pane list" },
    }) do
      write_panes(case.value)
      local result = send(sink())
      assert.is_false(result.ok)
      assert.is_truthy(result.err:find(case.message, 1, true), result.err)
    end
    vim.fn.writefile({ "{" }, ctx.state .. "/panes")
    assert.is_truthy(send(sink()).err:find("invalid pane list", 1, true))
    vim.fn.writefile({}, ctx.state .. "/fail-list")
    assert.is_truthy(send(sink()).err:find("pane discovery failed", 1, true))
    assert.is_nil(contents("payload"))
  end)

  it("reports launch and picker failures without leaving the sink busy", function()
    local spec = sink()
    require("pjollrig.ui.select").select = function()
      error("picker broke")
    end
    assert.is_truthy(send(spec).err:find("picker failed", 1, true))
    require("pjollrig.ui.select").select = function(choices, _, cb)
      cb(choices[1])
    end
    assert.is_true(send(spec).ok)
    vim.fn.delete(bin)
    assert.is_truthy(send(spec).err:find("pane discovery failed", 1, true))
  end)

  it("rejects overlapping sends while the picker is open", function()
    local choose, first
    require("pjollrig.ui.select").select = function(_, _, cb)
      choose = cb
    end
    local spec = sink()
    spec.send({}, {}, function(ok, err)
      first = { ok = ok, err = err }
    end)
    assert.is_true(vim.wait(3000, function()
      return choose ~= nil
    end, 10))
    assert.is_truthy(send(spec).err:find("already in progress", 1, true))
    choose(nil)
    assert.are.equal("cancelled", first.err)
  end)

  it("routes the pick command through dispatch and retains comments when clearing is opted out", function()
    H.edit_project_file(ctx, "a.lua", { "local a = 1" })
    require("pjollrig").add({ body = "check this" })
    local spec = sink({ clear_on_success = false })
    assert.is_false(spec.clear_on_success)
    local original_send = spec.send
    local result
    spec.send = function(comments, dispatch_ctx, cb)
      assert.is_true(dispatch_ctx.pick)
      original_send(comments, dispatch_ctx, function(ok, err)
        cb(ok, err)
        result = { ok = ok, err = err }
      end)
    end
    require("pjollrig").register_sink(spec)
    vim.cmd("runtime plugin/pjollrig.lua")
    vim.cmd("PjollrigSend wezterm pick")
    assert.is_true(vim.wait(3000, function()
      return result ~= nil
    end, 10))
    assert.is_true(result.ok, result.err)
    assert.are.equal(1, #require("pjollrig").list())
    assert.are.same({ "pick" }, vim.fn.getcompletion("PjollrigSend wezterm p", "cmdline"))
  end)

  it("clears comments after delivery by default, even when the file moved meanwhile", function()
    H.edit_project_file(ctx, "a.lua", { "local a = 1" })
    local pj = require("pjollrig")
    pj.add({ body = "check this" })
    assert.is_true(require("pjollrig.store").save(ctx.root))
    local spec = sink({ auto_submit = true })
    assert.is_true(spec.clear_on_success)
    local original_send = spec.send
    local result
    spec.send = function(comments, dispatch_ctx, cb)
      original_send(comments, dispatch_ctx, function(ok, err)
        cb(ok, err)
        result = { ok = ok, err = err }
      end)
      -- The agent edits the reviewed file before wezterm acks.
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- inserted" })
      pj.list()
    end
    pj.register_sink(spec)
    pj.send("wezterm")
    assert.is_true(vim.wait(3000, function()
      return result ~= nil
    end, 10))
    assert.is_true(result.ok, result.err)
    assert.is_truthy(contents("submit"))
    assert.are.equal(0, #pj.list())
  end)
end)
