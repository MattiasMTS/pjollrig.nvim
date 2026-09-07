local H = require("helpers")

local ctx

---Block until an async `:PjollrigReview` attached its files (the
---command returns within a frame with a resolving shell; the pairs
---land from the resolver's callback).
local function wait_attached()
  local R = require("pjollrig.review")
  vim.wait(10000, function()
    local s = R.state()
    return s ~= nil and not s.resolving
  end, 10)
  local s = R.state()
  assert.is_truthy(s, "review session never attached (resolve failed?)")
  assert.is_nil(s.resolving, "review session still resolving")
end

---Block until the deferred per-pair diffstat fill landed (kicked at
---attach; the winbar breadcrumb and panel rows gain their counts on
---its one refresh).
local function wait_diffstat()
  local R = require("pjollrig.review")
  vim.wait(2000, function()
    return R.diffstat() ~= nil
  end, 5)
  assert.is_truthy(R.diffstat(), "deferred diffstat fill did not land")
end

local function make_pairs(n)
  local files = {}
  for i = 1, n do
    local left = ctx.artifact_root .. ("/left/f%d.lua"):format(i)
    local right = ctx.root .. ("/f%d.lua"):format(i)
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ ("return %d -- old"):format(i) }, left)
    vim.fn.writefile({ ("return %d -- new"):format(i) }, right)
    files[i] = { left = left, right = right, status = "M", path = ("f%d.lua"):format(i) }
  end
  return files
end

describe("pjollrig review session", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("opens a diff pair with a protected left buffer", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))

    local wins = vim.api.nvim_tabpage_list_wins(0)
    -- 3 windows: 2 diff + 1 panel
    assert.are.equal(3, #wins)
    local saw_left, saw_right = false, false
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      -- Skip the panel window
      if vim.bo[buf].filetype ~= "pjollrig-panel" then
        assert.is_true(vim.wo[win].diff)
        if name:find("/left/", 1, true) then
          saw_left = true
          assert.is_false(vim.bo[buf].modifiable)
        else
          saw_right = true
          assert.is_true(vim.bo[buf].modifiable)
        end
      end
    end
    assert.is_true(saw_left)
    assert.is_true(saw_right)
  end)

  it("cycles pairs with next/prev and wraps", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "test" }))
    assert.are.equal(1, R.state().index)
    R.next()
    assert.are.equal(2, R.state().index)
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("f2.lua", 1, true))
    R.next() -- wraps
    assert.are.equal(1, R.state().index)
    R.prev() -- wraps back
    assert.are.equal(2, R.state().index)
  end)

  it("maps <Tab>/<S-Tab> in review buffers and removes them on stop", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "tabnav" }))

    local right_buf = vim.fn.bufnr(R.state().files[1].right)
    assert.is_true(right_buf > 0, "right buffer not loaded")
    local function buf_map(bufnr, lhs)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if map.lhs:lower() == lhs:lower() then
          return map
        end
      end
      return nil
    end

    local tab_map = buf_map(right_buf, "<Tab>")
    assert.is_truthy(tab_map, "<Tab> not mapped in review buffer")
    assert.is_truthy(buf_map(right_buf, "<S-Tab>"), "<S-Tab> not mapped in review buffer")

    -- Invoking the mapping advances the pair.
    tab_map.callback()
    assert.are.equal(2, R.state().index)

    R.stop()
    assert.is_nil(buf_map(right_buf, "<Tab>"), "<Tab> map leaked past stop()")
    assert.is_nil(buf_map(right_buf, "<S-Tab>"), "<S-Tab> map leaked past stop()")
  end)

  it("stop() clears state and closes the session tab", function()
    local R = require("pjollrig.review")
    local tabs_before = #vim.api.nvim_list_tabpages()
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))
    R.stop()
    assert.is_nil(R.state())
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
  end)

  it("start() caches the session's root and uris once", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "cache" }))

    local state = R.state()
    local uri_mod = require("pjollrig.uri")
    local uri1 = uri_mod.for_path(files[1].right)
    local uri2 = uri_mod.for_path(files[2].right)
    -- Index-aligned array, membership set, and uri -> pair index map.
    assert.are.same({ uri1, uri2 }, state.uris)
    assert.is_true(state.uri_set[uri1])
    assert.is_true(state.uri_set[uri2])
    assert.are.equal(1, state.uri_index[uri1])
    assert.are.equal(2, state.uri_index[uri2])
    -- helpers.project_dir plants a .git marker in ctx.root.
    assert.are.equal(ctx.root, state.root)
  end)

  it("diffstat() fills deferred once per session and caches on it", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    files[2].status = "D"
    assert.is_true(R.start({ files = files, label = "diffstat" }))

    -- Deferred: start() returns before the fill's scheduled chunks ran,
    -- so the argless form reports nil (panel rows omit the counts).
    assert.is_nil(R.diffstat(), "diffstat filled synchronously in start()")
    wait_diffstat()

    local stats = R.diffstat()
    -- make_pairs writes a one-line change; the D pair counts its left side.
    assert.are.same({ added = 1, removed = 1 }, stats[1])
    assert.are.same({ added = 0, removed = 1 }, stats[2])

    -- Cached on the session: the same table comes back, and worktree
    -- edits mid-session do not change it (as-of-attach by design).
    vim.fn.writefile({ "return 1", "-- more", "-- lines" }, files[1].right)
    assert.are.equal(stats, R.diffstat())
    assert.are.same({ added = 1, removed = 1 }, R.diffstat()[1])

    R.stop()
    assert.is_nil(R.diffstat(), "diffstat must be nil without a session")
  end)

  it("diffstat(files) computes explicit pairs, bypassing the session cache", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    files[2].status = "D"

    -- Works without any session at all.
    assert.is_nil(R.state())
    local stats = R.diffstat(files)
    assert.are.same({ added = 1, removed = 1 }, stats[1])
    assert.are.same({ added = 0, removed = 1 }, stats[2])

    -- With a session active the explicit form recomputes rather than
    -- returning (or filling) the cached session table. rawequal: the
    -- assertion is about table IDENTITY, not contents.
    assert.is_true(R.start({ files = files, label = "explicit" }))
    wait_diffstat()
    local cached = R.diffstat()
    assert.is_true(rawequal(cached, R.diffstat()), "argless form lost its session cache")
    assert.is_false(rawequal(cached, R.diffstat(files)), "explicit form returned the session cache")
  end)

  it("stop() deletes owned stage dirs and wipes buffers pointing into them", function()
    local R = require("pjollrig.review")
    -- Both sides staged, like a pr-head-not-checked-out session: the
    -- RIGHT buffer is a plain file buffer (no bufhidden=wipe), so stop()
    -- must wipe it before removing the files it points at.
    local stage = ctx.artifact_root .. "/owned-stage"
    local left = stage .. "/base/x.lua"
    local right = stage .. "/head/x.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.mkdir(vim.fn.fnamemodify(right, ":h"), "p")
    vim.fn.writefile({ "return 1" }, left)
    vim.fn.writefile({ "return 2" }, right)
    local files = { { left = left, right = right, status = "M", path = "x.lua" } }

    assert.is_true(R.start({ files = files, label = "cleanup", stage_dirs = { stage } }))
    assert.is_true(vim.fn.bufnr(right) > 0, "right staged buffer not loaded")

    R.stop()

    assert.are.equal(0, vim.fn.isdirectory(stage), "owned stage dir survived stop()")
    assert.are.equal(-1, vim.fn.bufnr(right), "a buffer still points at a removed staged file")
  end)

  it("start_from_job leaves external stage dirs alone unless the job opts in", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    local dir = ctx.artifact_root .. "/driver-stage"
    vim.fn.mkdir(dir, "p")

    -- No stage_dirs in the job: the external driver owns its files.
    local job_a = ctx.artifact_root .. "/job-a.json"
    vim.fn.writefile({ vim.json.encode({ label = "ext", files = files }) }, job_a)
    assert.is_true(R.start_from_job(job_a))
    R.stop()
    assert.are.equal(1, vim.fn.isdirectory(dir), "stop() deleted a dir the session never owned")

    -- Opt-in: the job lists the dirs pjollrig should delete on stop.
    local job_b = ctx.artifact_root .. "/job-b.json"
    vim.fn.writefile({ vim.json.encode({ label = "ext", files = files, stage_dirs = { dir } }) }, job_b)
    assert.is_true(R.start_from_job(job_b))
    R.stop()
    assert.are.equal(0, vim.fn.isdirectory(dir), "opted-in stage dir survived stop()")
  end)

  it(":PjollrigReview HEAD owns its staged baseline dir and stop() removes it", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local root = H.git_repo(ctx, { ["own.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/own.lua")
    local saved = vim.uv.cwd()
    vim.cmd.cd(root)
    vim.cmd("PjollrigReview HEAD")
    wait_attached()
    vim.cmd.cd(saved)

    local R = require("pjollrig.review")
    local state = assert(R.state(), "session did not start")
    assert.are.equal("table", type(state.stage_dirs))
    local dir = state.stage_dirs[1]
    assert.are.equal(1, vim.fn.isdirectory(dir))
    assert.are.equal(1, state.files[1].left:find(dir, 1, true))

    R.stop()
    assert.are.equal(0, vim.fn.isdirectory(dir), "staged baseline dir leaked past stop()")
  end)

  it("rejects an empty file list", function()
    local R = require("pjollrig.review")
    local ok, err = R.start({ files = {}, label = "test" })
    assert.is_false(ok)
    assert.is_truthy(err:find("no files", 1, true))
  end)

  it("finish() sends only the session's comments to the sink", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    -- A comment on a file OUTSIDE the review session must not be sent.
    local outside = ctx.root .. "/outside.lua"
    vim.fn.writefile({ "return 0" }, outside)

    local sent
    require("pjollrig").register_sink({
      name = "capture",
      send = function(comments, _, cb)
        sent = comments
        cb(true)
      end,
    })

    assert.is_true(R.start({ files = files, label = "test", sink = "capture" }))

    -- Find the right (non-qf) window and focus it
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype ~= "quickfix" and vim.bo[bufnr].modifiable then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end

    -- Comment on pair 1's worktree file (the current buffer after start).
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("session comment")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt

    -- Comment on the outside file.
    vim.cmd.edit(vim.fn.fnameescape(outside))
    ui.prompt = function(_opts, cb)
      cb("outside comment")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt

    assert.is_true(R.finish())
    vim.wait(200, function()
      return sent ~= nil
    end)
    assert.is_truthy(sent)
    assert.are.equal(1, #sent)
    assert.are.equal("session comment", sent[1].body)
  end)

  it("finish() with no comments returns false and does not dispatch", function()
    local R = require("pjollrig.review")
    local called = false
    require("pjollrig").register_sink({
      name = "capture",
      send = function(_, _, cb)
        called = true
        cb(true)
      end,
    })
    assert.is_true(R.start({ files = make_pairs(1), label = "test", sink = "capture" }))
    local ok, err = R.finish()
    assert.is_false(ok)
    assert.is_truthy(err:find("no comments", 1, true))
    assert.is_false(called)
  end)

  it("finish() and stop() are pure: ok,err returns, notifications live in the command layer", function()
    local R = require("pjollrig.review")
    local notified = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      notified[#notified + 1] = { msg = msg, level = level }
    end

    -- No session: both fail with an error string instead of notifying.
    local ok, err = R.finish()
    assert.is_false(ok)
    assert.is_truthy(err:find("no active review session", 1, true))
    local sok, serr = R.stop()
    assert.is_false(sok)
    assert.is_truthy(serr:find("no active review session", 1, true))
    assert.are.equal(0, #notified, "finish/stop notified instead of returning")
    vim.notify = original_notify

    -- Session without a sink: finish reports the missing sink; stop
    -- succeeds and reports true.
    assert.is_true(R.start({ files = make_pairs(1), label = "returns" }))
    local fok, ferr = R.finish()
    assert.is_false(fok)
    assert.is_truthy(ferr:find("no sink", 1, true))
    assert.is_true(R.stop())
  end)

  it("start_from_job wires files, label, and the socket sink", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    local job_path = ctx.artifact_root .. "/job.json"
    vim.fn.writefile({
      vim.json.encode({
        id = "job-7",
        label = "since-review",
        return_socket = ctx.artifact_root .. "/return.sock",
        files = files,
      }),
    }, job_path)

    assert.is_true(R.start_from_job(job_path))
    local state = R.state()
    assert.are.equal("since-review", state.label)
    assert.are.equal("socket", state.sink)
    assert.are.equal(ctx.artifact_root .. "/return.sock", state.ctx.socket)
    assert.are.equal("job-7", state.ctx.job)
  end)

  it("start_from_job rejects unreadable or invalid job files", function()
    local R = require("pjollrig.review")
    local ok, err = R.start_from_job(ctx.artifact_root .. "/absent.json")
    assert.is_false(ok)
    assert.is_truthy(err)

    local bad = ctx.artifact_root .. "/bad.json"
    vim.fn.writefile({ "{not json" }, bad)
    local ok2, err2 = R.start_from_job(bad)
    assert.is_false(ok2)
    assert.is_truthy(err2)
  end)

  it(":PjollrigReview <ref> starts a session via the git resolver", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local root = H.git_repo(ctx, { ["cmd.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/cmd.lua")
    local saved = vim.uv.cwd()
    vim.cmd.cd(root)

    vim.cmd("PjollrigReview HEAD")
    wait_attached()
    local state = require("pjollrig.review").state()
    vim.cmd.cd(saved)

    assert.is_truthy(state)
    assert.are.equal("HEAD", state.label)
    assert.are.equal(1, #state.files)
    assert.are.equal("cmd.lua", state.files[1].path)
  end)

  it(":PjollrigReview pr (bare) picks an open PR and labels with its title", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)

    -- Fake gh answering `pr list` (picker), `pr view` (resolver), and the
    -- comment-import endpoints.
    local bin = ctx.artifact_root .. "/bin"
    vim.fn.mkdir(bin, "p")
    vim.fn.writefile({
      "#!/bin/sh",
      'if [ "$1 $2" = "pr list" ]; then',
      '  echo \'[{"number":42,"title":"Add widgets","author":{"login":"octocat"}}]\';',
      'elif [ "$1 $2" = "pr view" ]; then',
      ('  echo \'{"baseRefOid":"%s","headRefOid":"%s","title":"Add widgets"}\';'):format(base_oid, head_oid),
      'elif [ "$1 $2" = "repo view" ]; then',
      '  echo \'{"nameWithOwner":"acme/widgets"}\';',
      "else",
      "  echo '[]';",
      "fi",
    }, bin .. "/gh")
    vim.fn.system({ "chmod", "+x", bin .. "/gh" })

    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path
    local saved_cwd = vim.uv.cwd()
    vim.cmd.cd(root)

    local original_select = vim.ui.select
    local seen_item
    vim.ui.select = function(items, select_opts, on_choice)
      seen_item = select_opts.format_item(items[1])
      on_choice(items[1])
    end
    local ok, err = pcall(vim.cmd, "PjollrigReview pr")
    -- The PR list fetch is async too now: the picker fires only when the
    -- fake gh answers, so the stub must stay installed until then.
    vim.wait(2000, function()
      return seen_item ~= nil
    end)
    vim.ui.select = original_select
    -- PATH/cwd stay in place until the ASYNC resolve chain (gh pr view,
    -- staging) has attached — the command only opened the shell.
    if ok then
      wait_attached()
    end
    vim.env.PATH = saved_path
    vim.cmd.cd(saved_cwd)
    assert.is_true(ok, err)

    assert.are.equal("#42 Add widgets \u{2014} octocat", seen_item)
    local state = require("pjollrig.review").state()
    assert.is_truthy(state, "picker did not start a session")
    assert.are.equal("pr 42: Add widgets", state.label)
  end)

  it("deleted-file (D) pairs accept comments on the left buffer", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local root = H.git_repo(ctx, { ["gone.lua"] = { "return 1" } })
    -- Delete the file from worktree so git resolver stages status=D.
    vim.fn.delete(root .. "/gone.lua")
    local saved = vim.uv.cwd()
    vim.cmd.cd(root)

    vim.cmd("PjollrigReview HEAD")
    wait_attached()
    local state = require("pjollrig.review").state()
    assert.is_truthy(state)
    assert.are.equal(1, #state.files)
    assert.are.equal("D", state.files[1].status)

    -- Current buffer is the left (staged baseline) for the D pair.
    -- Fake prompt and add a comment.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("deleted file note")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    assert.are.equal("deleted file note", records[1].body)
    -- Scope is session because the staged left file path no longer
    -- matches the nvim-runtime pattern after sources.lua fix.
    assert.are.equal("session", records[1].scope)

    vim.cmd.cd(saved)
  end)

  it("panel opens on start with file rows and focus stays in the diff", function()
    local R = require("pjollrig.review")
    local qf_size_before = #vim.fn.getqflist()
    assert.is_true(R.start({ files = make_pairs(2), label = "panel-test" }))

    -- Panel should be open: an owned pjollrig-panel buffer, no quickfix.
    local panel_winid
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "pjollrig-panel" then
        panel_winid = winid
        break
      end
    end
    assert.is_truthy(panel_winid, "panel window not found")

    -- Focus should be in the diff, not the panel
    assert.are_not.equal(panel_winid, vim.api.nvim_get_current_win())

    -- Panel should have 2 rows (one per pair)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel_winid), 0, -1, false)
    assert.are.equal(2, #lines)
    assert.is_truthy(lines[1]:find("f1.lua"))
    assert.is_truthy(lines[1]:find("0 comments"))

    -- The global quickfix list stays free for the user.
    assert.are.equal(qf_size_before, #vim.fn.getqflist())
  end)

  it("panel queries comments once when building file rows", function()
    local R = require("pjollrig.review")
    local pjollrig = require("pjollrig")
    local original_list = pjollrig.list
    local list_calls = 0
    pjollrig.list = function(opts)
      list_calls = list_calls + 1
      return original_list(opts)
    end
    local ok, start_ok, start_err = pcall(R.start, { files = make_pairs(3), label = "panel-test" })
    pjollrig.list = original_list

    assert.is_true(ok)
    assert.is_true(start_ok, start_err)
    assert.are.equal(1, list_calls)
  end)

  it("panel comment count updates when a comment is added", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "panel-test" }))
    local panel = require("pjollrig.review.panel")

    -- Initial count should be 0
    local lines = vim.api.nvim_buf_get_lines(panel.bufnr(), 0, -1, false)
    assert.is_truthy(lines[1]:find("0 comments"))

    -- Find the right (modifiable) window and focus it
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype ~= "pjollrig-panel" and vim.bo[bufnr].modifiable then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end

    -- Add a comment
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("test comment")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt

    -- Wait for refresh
    vim.wait(200)

    -- Count should now be 1
    lines = vim.api.nvim_buf_get_lines(panel.bufnr(), 0, -1, false)
    assert.is_truthy(lines[1]:find("1 comments"))
  end)

  it("<CR> in panel files view switches to that pair and keeps panel open", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "panel-test" }))

    local panel_winid = require("pjollrig.review.panel").winid()
    assert.is_truthy(panel_winid)

    -- Switch to panel and press <CR> on row 2 THROUGH buffer-local
    -- mappings (normal! bypasses maps and "\\<CR>" is literal chars).
    vim.api.nvim_set_current_win(panel_winid)
    vim.api.nvim_win_set_cursor(panel_winid, { 2, 0 })
    local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
    vim.api.nvim_feedkeys(cr, "x", false)

    -- Session index should now be 2
    assert.are.equal(2, R.state().index)

    -- Panel should still be open
    assert.is_true(vim.api.nvim_win_is_valid(panel_winid))
  end)

  it("panel shows files view with comment counts", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "panel-test" }))

    -- Find the right (modifiable) window and focus it
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype ~= "pjollrig-panel" and vim.bo[bufnr].modifiable then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end

    -- Add a comment so we have something in comments view
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("test comment")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt
    vim.wait(200)

    -- Files view should show both files with comment counts
    local lines = vim.api.nvim_buf_get_lines(require("pjollrig.review.panel").bufnr(), 0, -1, false)
    assert.is_true(#lines >= 1, "Expected at least 1 row, got " .. #lines)
    assert.is_truthy(lines[1]:find("comments"))
  end)

  local function add_comment(path, body)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb(body)
    end
    require("pjollrig").add()
    ui.prompt = original_prompt
  end

  local function panel_win()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "pjollrig-panel" then
        return winid
      end
    end
  end

  ---Rendered panel buffer lines.
  local function panel_lines()
    local winid = panel_win()
    assert.is_truthy(winid, "panel window not found")
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false)
  end

  ---1-indexed panel row carrying the current-pair line highlight, or nil.
  local function panel_current_row()
    local winid = panel_win()
    assert.is_truthy(winid, "panel window not found")
    local ns_current = vim.api.nvim_create_namespace("pjollrig.review.panel.current")
    local bufnr = vim.api.nvim_win_get_buf(winid)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_current, 0, -1, { details = true })) do
      if mark[4].line_hl_group == "PjollrigPanelCurrent" then
        return mark[2] + 1
      end
    end
    return nil
  end

  ---Press `lhs` in the panel window on `row` THROUGH buffer-local maps.
  local function press_in_panel(row, lhs)
    local winid = panel_win()
    assert.is_truthy(winid, "panel window not found")
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { row, 0 })
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "x", false)
  end

  ---`H` from the files view wraps straight to the Comments tab
  ---(the tab order is Files → Comments).
  local function to_comments_view(row)
    press_in_panel(row, "H")
  end

  it("<CR> on a commented file scopes the comments view to that file", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")
    add_comment(files[2].right, "second file comment")

    press_in_panel(1, "<CR>")

    local lines = panel_lines()
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("first file comment", 1, true))
  end)

  it("<Esc> in scoped comments view returns to files view", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")

    press_in_panel(1, "<CR>")
    assert.are.equal(1, #panel_lines())

    press_in_panel(1, "<Esc>")
    local lines = panel_lines()
    assert.are.equal(2, #lines)
    assert.is_truthy(lines[1]:find("\u{00B7} 1 comments", 1, true))
    assert.is_truthy(lines[2]:find("\u{00B7} 0 comments", 1, true))
  end)

  it("<CR> on a file without comments opens the pair", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")
    -- The add's panel refresh is scheduled (event bursts coalesce);
    -- wait for the live count before pressing.
    assert.is_true(vim.wait(1000, function()
      return panel_lines()[1]:find("\u{00B7} 1 comments", 1, true) ~= nil
    end, 10))

    press_in_panel(2, "<CR>")

    assert.are.equal(2, R.state().index)
    -- Still files view.
    assert.is_truthy(panel_lines()[1]:find("\u{00B7} 1 comments", 1, true))
  end)

  it("o on a commented file opens the pair anyway", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[2].right, "second file comment")

    press_in_panel(2, "o")

    assert.are.equal(2, R.state().index)
    -- Still files view.
    assert.is_truthy(panel_lines()[1]:find("\u{00B7} 0 comments", 1, true))
  end)

  it("tab switching clears a scoped comments view's file filter", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")
    add_comment(files[2].right, "second file comment")

    press_in_panel(1, "<CR>")
    assert.are.equal(1, #panel_lines())

    press_in_panel(1, "L") -- Comments wraps forward to Files
    assert.is_truthy(panel_lines()[1]:find("\u{00B7} 1 comments", 1, true), "L did not land on the files view")

    press_in_panel(1, "H") -- Files wraps back to Comments: ALL comments now
    local lines = panel_lines()
    assert.are.equal(2, #lines)
    local texts = table.concat(lines, "\n")
    assert.is_truthy(texts:find("first file comment", 1, true))
    assert.is_truthy(texts:find("second file comment", 1, true))
  end)

  ---A flat pair plus one nested under `sub/`, so the tree view differs
  ---visibly from the files view (a `▾ sub` directory row appears).
  local function make_nested_pair_set()
    local files = make_pairs(1)
    local left = ctx.artifact_root .. "/left/sub/nested.lua"
    local right = ctx.root .. "/sub/nested.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.mkdir(vim.fn.fnamemodify(right, ":h"), "p")
    vim.fn.writefile({ "return 9 -- old" }, left)
    vim.fn.writefile({ "return 9 -- new" }, right)
    files[2] = { left = left, right = right, status = "M", path = "sub/nested.lua" }
    return files
  end

  it("L cycles files → comments → files; t keeps its tree layout across the cycle", function()
    local R = require("pjollrig.review")
    local files = make_nested_pair_set()
    assert.is_true(R.start({ files = files, label = "cycle" }))
    add_comment(files[1].right, "cycle comment")
    vim.wait(200)

    press_in_panel(1, "t") -- tree layout: a directory row appears
    assert.is_truthy(table.concat(panel_lines(), "\n"):find("\u{25BE} sub", 1, true), "t is not the tree layout")
    press_in_panel(1, "L") -- comments
    assert.is_truthy(panel_lines()[1]:find("cycle comment", 1, true), "first L is not comments view")
    press_in_panel(1, "L") -- wraps back to files, tree layout intact
    assert.is_truthy(
      table.concat(panel_lines(), "\n"):find("\u{25BE} sub", 1, true),
      "second L did not return to the files tab's tree layout"
    )
  end)

  it("tree layout <CR> on a file row rebuilds that pair's diff", function()
    local R = require("pjollrig.review")
    local files = make_nested_pair_set()
    assert.is_true(R.start({ files = files, label = "tree-open" }))

    press_in_panel(1, "t")
    -- Rows: 1 = f1.lua (root file), 2 = ▾ sub, 3 = nested.lua.
    press_in_panel(3, "<CR>")

    assert.are.equal(2, R.state().index)
    local cur_name = vim.api.nvim_buf_get_name(0)
    assert.is_truthy(cur_name:find("/sub/nested.lua", 1, true), "expected the nested pair, got " .. cur_name)
    assert.is_truthy(panel_win(), "panel window closed by the tree open")
    -- Still the Files tab's tree layout, current marks on the nested
    -- file's row.
    assert.is_truthy(panel_lines()[2]:find("\u{25BE} sub", 1, true))
    assert.are.equal(3, panel_current_row())
  end)

  ---Like add_comment, but places the comment on a specific line.
  local function add_comment_at(path, line, body)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb(body)
    end
    require("pjollrig").add()
    ui.prompt = original_prompt
  end

  it("<CR> in comments view rebuilds the pair's diff and jumps to the comment", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    vim.fn.writefile({ "return 2 -- new", "-- pad", "-- target", "-- pad" }, files[2].right)
    assert.is_true(R.start({ files = files, label = "jump" }))
    add_comment_at(files[2].right, 3, "jump target")
    -- add_comment_at edited pair 2's file into pair 1's diff window;
    -- restore the pair 1 layout before exercising the jump.
    R.open_pair(1)

    to_comments_view(1) -- comments view (ALL)
    press_in_panel(1, "<CR>")

    assert.are.equal(2, R.state().index)

    -- Focused window shows pair 2's RIGHT worktree file, cursor on the
    -- comment's line.
    local cur_win = vim.api.nvim_get_current_win()
    local cur_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(cur_win))
    assert.is_truthy(cur_name:find("/f2.lua", 1, true), "expected right file, got " .. cur_name)
    assert.is_nil(cur_name:find("/left/", 1, true), "jump landed in the left buffer: " .. cur_name)
    assert.are.equal(3, vim.api.nvim_win_get_cursor(cur_win)[1])

    -- Panel window is still open.
    local pwin = panel_win()
    assert.is_truthy(pwin, "panel window closed by jump")

    -- Regression: the OTHER diff window must show pair 2's LEFT staged
    -- file — the default qf jump used to replace a diff window with the
    -- target buffer, leaving a broken non-pair layout.
    local left_seen = false
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= cur_win and winid ~= pwin then
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
        assert.is_truthy(name:find("/left/f2.lua", 1, true), "other diff window shows " .. name)
        left_seen = true
      end
    end
    assert.is_true(left_seen, "no second diff window found")
  end)

  it("<CR> in comments view on a deleted-pair comment lands in the left buffer", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    -- Realpath the staged dir: records store canonical uris, and the
    -- macOS TMPDIR symlink (/var -> /private/var) would otherwise make
    -- the pair uri miss the record uri.
    local uv = vim.uv
    local left_dir = uv.fs_realpath(ctx.artifact_root .. "/left") or (ctx.artifact_root .. "/left")
    local left = left_dir .. "/gone.lua"
    vim.fn.writefile({ "return 0 -- deleted" }, left)
    files[2] = { left = left, right = ctx.root .. "/gone.lua", status = "D", path = "gone.lua" }
    assert.is_true(R.start({ files = files, label = "jump-d" }))
    add_comment_at(left, 1, "note on deleted file")
    R.open_pair(1)

    to_comments_view(1)
    press_in_panel(1, "<CR>")

    assert.are.equal(2, R.state().index)
    local cur_name = vim.api.nvim_buf_get_name(0)
    assert.is_truthy(cur_name:find("/left/gone.lua", 1, true), "expected left buffer, got " .. cur_name)
    assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_truthy(panel_win(), "panel window closed by jump")
  end)

  it("<CR> in comments view on an unmatched comment warns and keeps the layout", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "jump-warn" }))
    add_comment_at(files[1].right, 1, "orphan-to-be")
    R.open_pair(1)

    to_comments_view(1)

    -- Break the session's uri -> pair mapping so the comment matches no
    -- pair (defensive path); review.state() returns the live table.
    local pwin = panel_win()
    R.state().uri_index = {}

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    press_in_panel(1, "<CR>")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN notification")
    assert.are.equal(1, R.state().index)
    -- Layout unchanged: focus still in the panel, both pair 1 diff
    -- windows intact.
    assert.are.equal(pwin, vim.api.nvim_get_current_win())
    local saw_left, saw_right = false, false
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= pwin then
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
        if name:find("/left/f1.lua", 1, true) then
          saw_left = true
        elseif name:find("/f1.lua", 1, true) then
          saw_right = true
        end
      end
    end
    assert.is_true(saw_left and saw_right, "pair 1 diff layout was disturbed")
  end)

  ---Persist an imported-from-GitHub record on `path` (project scope,
  ---line 1) with the given `meta.github` table.
  local function put_imported(path, gh_meta, body)
    local store = require("pjollrig.store")
    local now = os.time()
    local record = {
      id = require("pjollrig.id").new(),
      uri = require("pjollrig.uri").for_path(path),
      scope = "project",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = body or "from github",
      author = "octocat",
      created_at = now,
      updated_at = now,
      resolved = false,
      meta = { github = gh_meta },
    }
    store.put_record(record)
    assert(store.save(ctx.root))
    return record
  end

  it("r in comments view replies to an imported comment", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    put_imported(files[1].right, { id = 9001, imported = true, thread_id = 9001, pr = 42 })
    assert.is_true(R.start({ files = files, label = "reply" }))

    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("sounds good")
    end
    to_comments_view(1)
    press_in_panel(1, "r")
    ui.prompt = original_prompt

    local reply
    for _, r in ipairs(require("pjollrig.store").all(ctx.root)) do
      if r.body == "sounds good" then
        reply = r
      end
    end
    assert.is_truthy(reply, "reply record not created")
    assert.are.equal(require("pjollrig.uri").for_path(files[1].right), reply.uri)
    assert.are.same({ start = { 0, 0 }, end_ = { 0, 0 } }, reply.range)
    assert.are.same({ to = 9001, pr = 42 }, reply.meta.github_reply)
    assert.is_nil(reply.meta.github)
  end)

  it("r on a non-imported comment warns and creates nothing", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "reply-warn" }))
    add_comment(files[1].right, "local note")

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    to_comments_view(1)
    press_in_panel(1, "r")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN")
    assert.are.equal(1, #require("pjollrig").list(nil, { root = ctx.root }))
  end)

  ---Fake gh on PATH that logs every argv line and answers any call
  ---with an empty JSON object (enough for graphql mutations).
  local function fake_gh_resolve(dir)
    local home = dir .. "/gh-resolve"
    local bin = home .. "/bin"
    vim.fn.mkdir(bin, "p")
    vim.fn.writefile({
      "#!/bin/sh",
      "dir=" .. vim.fn.shellescape(home),
      'echo "$*" >> "$dir/argv.log"',
      "echo '{\"data\":{}}'",
    }, bin .. "/gh")
    vim.fn.system({ "chmod", "+x", bin .. "/gh" })
    return {
      bin = bin,
      argv = function()
        local ok, lines = pcall(vim.fn.readfile, home .. "/argv.log")
        return ok and lines or {}
      end,
    }
  end

  it("gr in comments view toggles GitHub thread resolution", function()
    local gh = fake_gh_resolve(ctx.artifact_root)
    local saved_path = vim.env.PATH
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    local record = put_imported(
      files[1].right,
      { id = 9001, imported = true, thread_id = 9001, thread_node = "RT_kwDO1", resolved = false, pr = 42 }
    )
    assert.is_true(R.start({ files = files, label = "resolve" }))

    to_comments_view(1)
    assert.is_nil(panel_lines()[1]:find("\u{2713}", 1, true))

    press_in_panel(1, "gr")

    -- The mutation runs through an async vim.system: the argv log, the
    -- flag flip, and the panel refresh all land in the callback.
    local store = require("pjollrig.store")
    vim.wait(2000, function()
      return store.get(ctx.root, record.id).meta.github.resolved == true
    end)

    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(argv:find("resolveReviewThread", 1, true))
    assert.is_truthy(argv:find("RT_kwDO1", 1, true))
    assert.is_nil(argv:find("unresolveReviewThread", 1, true))
    assert.is_true(store.get(ctx.root, record.id).meta.github.resolved)
    assert.is_truthy(panel_lines()[1]:find("\u{2713}", 1, true))

    press_in_panel(1, "gr")
    vim.wait(2000, function()
      return store.get(ctx.root, record.id).meta.github.resolved == false
    end)

    argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(argv:find("unresolveReviewThread", 1, true))
    assert.is_false(store.get(ctx.root, record.id).meta.github.resolved)
    assert.is_nil(panel_lines()[1]:find("\u{2713}", 1, true))

    vim.env.PATH = saved_path
  end)

  it("gr on a non-imported comment warns", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "resolve-warn" }))
    add_comment(files[1].right, "local note")

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    to_comments_view(1)
    press_in_panel(1, "gr")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN")
  end)

  it("gr on an imported comment without a thread id warns", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    put_imported(files[1].right, { id = 9002, imported = true, thread_id = 9002, pr = 42 })
    assert.is_true(R.start({ files = files, label = "resolve-no-node" }))

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    to_comments_view(1)
    press_in_panel(1, "gr")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN")
    assert.is_truthy(
      warned:find(":PjollrigReview pr", 1, true),
      "WARN must point at re-running :PjollrigReview pr <n>, got: " .. tostring(warned)
    )
  end)

  it("next/prev sync the panel's current-line highlight to the open pair", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "sync" }))
    local pwin = panel_win()
    assert.is_truthy(pwin, "panel window not found")

    R.next()
    assert.are.equal(2, panel_current_row())
    assert.are.equal(2, vim.api.nvim_win_get_cursor(pwin)[1])
    -- Focus must stay in the diff window, not the panel.
    assert.are_not.equal(pwin, vim.api.nvim_get_current_win())

    -- prev() is a literal step back to the pair just left, viewed or not.
    R.prev()
    assert.are.equal(1, panel_current_row())
    assert.are.equal(1, vim.api.nvim_win_get_cursor(pwin)[1])
  end)

  it("comment-add refresh keeps the panel index on the open pair", function()
    local R = require("pjollrig.review")
    local files = make_pairs(3)
    assert.is_true(R.start({ files = files, label = "sync-refresh" }))
    R.next() -- pair 2 open

    -- Adding a comment fires User PjollrigAdded, which rebuilds the
    -- panel rows; the rebuild must keep the current-line highlight on
    -- the open pair.
    add_comment(files[2].right, "note on pair 2")
    vim.wait(200)

    assert.is_truthy(panel_win(), "panel window not found")
    assert.are.equal(2, panel_current_row())
  end)

  it("next() in drill-down comments view leaves the comments list alone", function()
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "sync-drill" }))
    add_comment(files[1].right, "drill comment")
    R.open_pair(1)

    press_in_panel(1, "<CR>") -- drill into pair 1's scoped comments view
    assert.are.equal(1, #panel_lines())

    local ok, err = pcall(R.next)
    assert.is_true(ok, err)

    -- Comments list undisturbed by the pair switch.
    local lines = panel_lines()
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("drill comment", 1, true))
  end)

  it(":PjollrigToggle hides the panel during a session and keeps it running", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "toggle" }))
    assert.is_truthy(panel_win(), "panel window not found")

    vim.cmd("PjollrigToggle")

    assert.is_nil(panel_win(), "panel window still open after toggle")
    assert.is_truthy(R.state(), "toggle killed the session")
  end)

  it(":PjollrigToggle twice restores the panel in the same view", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local R = require("pjollrig.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "toggle" }))
    add_comment(files[1].right, "first file comment")
    add_comment(files[2].right, "second file comment")

    -- Drill into a comments view scoped to file 1.
    press_in_panel(1, "<CR>")
    assert.are.equal(1, #panel_lines())

    vim.cmd("PjollrigToggle")
    assert.is_nil(panel_win())
    vim.cmd("PjollrigToggle")

    local winid = panel_win()
    assert.is_truthy(winid, "panel window not reopened")
    -- Still the scoped comments view: one row, file 1's comment only.
    local lines = panel_lines()
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("first file comment", 1, true))
  end)

  it(":PjollrigToggle without a session still toggles comment visuals", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local render = require("pjollrig.ui.render")
    assert.is_true(render.is_visible())

    vim.cmd("PjollrigToggle")
    assert.is_false(render.is_visible())

    vim.cmd("PjollrigToggle")
    assert.is_true(render.is_visible())
  end)

  it("panel.toggle() without a session is a no-op returning false", function()
    assert.is_false(require("pjollrig.review.panel").toggle())
  end)

  it("finish() from a foreign cwd/unnamed buffer still sends session comments", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)

    local sent
    require("pjollrig").register_sink({
      name = "capture",
      send = function(comments, _, cb)
        sent = comments
        cb(true)
      end,
    })

    assert.is_true(R.start({ files = files, label = "root-hint", sink = "capture" }))
    add_comment(files[1].right, "session comment")

    -- Move to an unnamed scratch buffer with cwd OUTSIDE the reviewed
    -- project: list() resolves the store root from the CURRENT buffer,
    -- falling back to cwd, so without the session's `_root` hint the
    -- comment would be silently dropped ("review has no comments to send").
    local elsewhere = ctx.artifact_root .. "/elsewhere"
    vim.fn.mkdir(elsewhere, "p")
    local saved = vim.uv.cwd()
    vim.cmd.enew()
    vim.cmd.cd(elsewhere)

    R.finish()
    vim.wait(200, function()
      return sent ~= nil
    end)
    vim.cmd.cd(saved)

    assert.is_truthy(sent, "sink never received the session's comments")
    assert.are.equal(1, #sent)
    assert.are.equal("session comment", sent[1].body)
  end)

  it("VimLeavePre autoflush wait tracks the socket sink's ack timeout", function()
    local R = require("pjollrig.review")
    -- Default socket ack_timeout_ms is 2000; the historical 2500 floor holds.
    assert.are.equal(2500, R._autoflush_wait_ms())

    -- A user-configured ack_timeout_ms at or above the old hard-coded 2500
    -- must extend the wait past the sink's ack timer, or nvim exits before
    -- the never-lose-comments submit.json fallback fires. No restore
    -- needed: before_each's setup() rebuilds the config from defaults.
    require("pjollrig.config").get().sinks.socket = { ack_timeout_ms = 5000 }
    assert.is_true(R._autoflush_wait_ms() > 5000, "wait must outlive the ack timer")
  end)

  it("recreates the session tab after :tabclose so next() does not error", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "tabclose" }))
    local dead_tab = R.state().tab

    vim.cmd.tabclose() -- kill the review tab directly, bypassing stop()

    local ok, err = pcall(R.next)
    assert.is_true(ok, err)

    -- Session survived on a fresh, valid tab showing the next pair.
    local state = R.state()
    assert.is_truthy(state, "session died with the tab")
    assert.are.equal(2, state.index)
    assert.are_not.equal(dead_tab, state.tab)
    assert.is_true(vim.api.nvim_tabpage_is_valid(state.tab))
    assert.are.equal(state.tab, vim.api.nvim_get_current_tabpage())
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("f2.lua", 1, true))
    -- The panel comes back with the recreated tab.
    assert.is_truthy(panel_win(), "panel not reopened with the recreated tab")
  end)

  it("stop() closes the panel and clears autocmds", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "panel-test" }))

    -- Panel should be open
    local panel_winid = panel_win()
    assert.is_truthy(panel_winid)

    R.stop()

    -- Panel should be closed, with its augroup gone
    assert.is_false(vim.api.nvim_win_is_valid(panel_winid))
    assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = "PjollrigReviewPanel" }))
  end)
end)

describe("pjollrig review viewed tracking", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("next() marks the pair it leaves as viewed and skips viewed pairs", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "viewed-skip" }))
    R.set_viewed(2, true)

    R.next()

    local state = R.state()
    assert.is_true(state.viewed[1], "leaving pair 1 did not mark it viewed")
    assert.are.equal(3, state.index, "next() did not skip the viewed pair")
  end)

  it("prev() steps back literally: no viewed-marking, no skipping", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "viewed-prev" }))

    -- <Tab> then <S-Tab> must return to the file just left, even though
    -- next() marked it viewed.
    R.next()
    assert.are.equal(2, R.state().index)
    R.prev()

    local state = R.state()
    assert.are.equal(1, state.index, "prev() did not return to the pair just left")
    -- Going back is not a completion gesture: pair 2 stays unviewed.
    assert.is_nil(state.viewed[2])

    -- Wraps backward from the first pair.
    R.prev()
    assert.are.equal(3, R.state().index)
  end)

  it("falls back to plain cycling when every pair is viewed", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "viewed-all" }))
    R.set_viewed(1, true)
    R.set_viewed(2, true)

    R.next()
    assert.are.equal(2, R.state().index)
    R.next() -- wraps, no infinite loop
    assert.are.equal(1, R.state().index)
    R.prev() -- wraps back
    assert.are.equal(2, R.state().index)
  end)

  it("set_viewed(index, false) un-marks so navigation stops skipping", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "viewed-unmark" }))
    R.set_viewed(2, true)
    R.set_viewed(2, false)

    R.next()
    assert.are.equal(2, R.state().index)
    assert.is_nil(R.state().viewed[2])
  end)

  it("set_viewed ignores out-of-range indexes and missing sessions", function()
    local R = require("pjollrig.review")
    R.set_viewed(1, true) -- no session: no error
    assert.is_true(R.start({ files = make_pairs(1), label = "viewed-range" }))
    R.set_viewed(99, true)
    assert.is_nil(R.state().viewed[99])
  end)

  it("viewed state is cleared per session", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "viewed-fresh" }))
    R.set_viewed(1, true)
    R.stop()

    assert.is_true(R.start({ files = make_pairs(2), label = "viewed-fresh-2" }))
    assert.are.same({}, R.state().viewed)
  end)
end)

describe("pjollrig review winbar breadcrumb", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  ---File windows of the current tab keyed by side: `left` matches
  ---"/left/", `right` is the other non-panel window.
  local function file_wins()
    local wins = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype ~= "pjollrig-panel" then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:find("/left/", 1, true) then
          wins.left = winid
        else
          wins.right = winid
        end
      end
    end
    return wins
  end

  it("split mode: breadcrumb on the right window, baseline tag on the left", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "winbar-split" }))
    -- The counts land with the deferred diffstat fill, which repaints
    -- the OPEN pair's breadcrumb (pair switches recompute their own).
    wait_diffstat()

    local wins = file_wins()
    assert.are.equal("f1.lua \u{00B7} M \u{00B7} +1 \u{2212}1", vim.wo[wins.right].winbar)
    assert.are.equal("f1.lua \u{00B7} baseline", vim.wo[wins.left].winbar)

    -- Pair switch re-labels the new pair's windows.
    R.next()
    wins = file_wins()
    assert.are.equal("f2.lua \u{00B7} M \u{00B7} +1 \u{2212}1", vim.wo[wins.right].winbar)
    assert.are.equal("f2.lua \u{00B7} baseline", vim.wo[wins.left].winbar)
  end)

  it("unified mode: breadcrumb on the single window", function()
    require("pjollrig.config").get().review.diff_mode = "unified"
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "winbar-unified" }))
    wait_diffstat()
    assert.are.equal("f1.lua \u{00B7} M \u{00B7} +1 \u{2212}1", vim.wo[vim.api.nvim_get_current_win()].winbar)
  end)

  it("omits zero diffstat components and handles D pairs", function()
    local R = require("pjollrig.review")
    local left = ctx.artifact_root .. "/left/gone.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ "one", "two" }, left)
    local files = { { left = left, right = ctx.root .. "/gone.lua", status = "D", path = "gone.lua" } }
    assert.is_true(R.start({ files = files, label = "winbar-d" }))
    wait_diffstat()
    -- D pair: one window (the baseline), removed count only.
    assert.are.equal("gone.lua \u{00B7} D \u{00B7} \u{2212}2", vim.wo[vim.api.nvim_get_current_win()].winbar)
  end)

  it("escapes % in the path for the statusline engine", function()
    local R = require("pjollrig.review")
    local left = ctx.artifact_root .. "/left/we%rd.lua"
    local right = ctx.root .. "/we%rd.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ "return 1 -- old" }, left)
    vim.fn.writefile({ "return 1 -- new" }, right)
    local files = { { left = left, right = right, status = "M", path = "we%rd.lua" } }
    assert.is_true(R.start({ files = files, label = "winbar-escape" }))
    wait_diffstat()

    local wins = file_wins()
    assert.are.equal("we%%rd.lua \u{00B7} M \u{00B7} +1 \u{2212}1", vim.wo[wins.right].winbar)
    assert.are.equal("we%%rd.lua \u{00B7} baseline", vim.wo[wins.left].winbar)
  end)

  it("stop() clears the winbar from surviving windows", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "winbar-clear" }))
    -- Reduce to the single-tab, worktree-window-only shape: stop()'s
    -- single-tab branch reuses this window instead of closing it.
    vim.cmd("tabonly")
    local right = file_wins().right
    vim.api.nvim_set_current_win(right)
    vim.cmd("only")
    assert.are_not.equal("", vim.wo[right].winbar)

    R.stop()

    assert.is_true(vim.api.nvim_win_is_valid(right), "single-tab stop() should reuse the window")
    assert.are.equal("", vim.wo[right].winbar, "winbar survived stop()")
  end)
end)

describe("pjollrig review document pairs", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  ---A `doc` pair: a prose file reviewed without a baseline — no `left`.
  local function make_doc_pair(name)
    local right = ctx.root .. "/" .. name
    vim.fn.writefile({ "# Plan", "", ("prose "):rep(40) }, right)
    return { right = right, status = "doc", path = name }
  end

  ---Non-panel windows of the current tab, in layout order.
  local function file_wins()
    local wins = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(winid)].filetype ~= "pjollrig-panel" then
        wins[#wins + 1] = winid
      end
    end
    return wins
  end

  local function buf_map(bufnr, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if map.lhs:lower() == lhs:lower() then
        return map
      end
    end
    return nil
  end

  it("opens plain: one window, no diff, prose wrapping, `path · doc` breadcrumb", function()
    local R = require("pjollrig.review")
    local pair = make_doc_pair("plan.md")
    assert.is_true(R.start({ files = { pair }, label = "doc" }))

    local wins = file_wins()
    assert.are.equal(1, #wins, "a doc pair must not split")
    local win = wins[1]
    local buf = vim.api.nvim_win_get_buf(win)
    assert.are.equal(win, vim.api.nvim_get_current_win())
    assert.are.equal(pair.right, vim.api.nvim_buf_get_name(buf))
    assert.is_false(vim.wo[win].diff)
    assert.is_true(vim.bo[buf].modifiable)
    assert.is_true(vim.wo[win].wrap)
    assert.is_true(vim.wo[win].linebreak)
    assert.is_true(vim.wo[win].breakindent)
    assert.are.equal("plan.md \u{00B7} doc", vim.wo[win].winbar)

    -- The deferred diffstat fill has nothing to count for a doc pair and
    -- leaves the breadcrumb without a `+N`.
    wait_diffstat()
    assert.is_nil(R.diffstat()[1])
    assert.are.equal("plan.md \u{00B7} doc", vim.wo[win].winbar)
  end)

  it("keeps <Tab>/<S-Tab> mapped in the doc buffer; stop() removes them and the session", function()
    local R = require("pjollrig.review")
    local files = { make_doc_pair("plan.md"), make_pairs(1)[1] }
    assert.is_true(R.start({ files = files, label = "doc-nav" }))
    local doc_buf = vim.api.nvim_get_current_buf()
    local tab_map = buf_map(doc_buf, "<Tab>")
    assert.is_truthy(tab_map, "<Tab> not mapped in the doc buffer")
    assert.is_truthy(buf_map(doc_buf, "<S-Tab>"), "<S-Tab> not mapped in the doc buffer")

    tab_map.callback()
    assert.are.equal(2, R.state().index)
    R.prev()
    assert.are.equal(1, R.state().index)
    assert.are.equal(doc_buf, vim.api.nvim_get_current_buf())

    assert.is_true(R.stop())
    assert.is_nil(R.state())
    assert.is_nil(buf_map(doc_buf, "<Tab>"), "<Tab> map leaked past stop()")
    assert.is_nil(buf_map(doc_buf, "<S-Tab>"), "<S-Tab> map leaked past stop()")
  end)

  it("diff-mode toggle on a doc pair re-opens it plain without error", function()
    local R = require("pjollrig.review")
    local pair = make_doc_pair("plan.md")
    assert.is_true(R.start({ files = { pair }, label = "doc-mode" }))
    for _, mode in ipairs({ "unified", "split" }) do
      assert.are.equal(mode, R.set_diff_mode(mode))
      local wins = file_wins()
      assert.are.equal(1, #wins, mode .. ": a doc pair must stay one window")
      assert.are.equal(pair.right, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[1])))
      assert.is_false(vim.wo[wins[1]].diff)
      assert.is_true(vim.wo[wins[1]].linebreak)
      assert.are.equal("plan.md \u{00B7} doc", vim.wo[wins[1]].winbar)
    end
  end)

  it("prose options stay with the doc buffer: the next pair's diff windows are unaffected", function()
    local R = require("pjollrig.review")
    local files = { make_doc_pair("plan.md"), make_pairs(1)[1] }
    assert.is_true(R.start({ files = files, label = "doc-leak" }))
    assert.is_true(vim.wo[vim.api.nvim_get_current_win()].linebreak)

    -- The pair switch reuses the doc's window for the M pair's right
    -- side (close_session_windows keeps the first file window).
    R.next()
    assert.are.equal(2, R.state().index)
    local wins = file_wins()
    assert.are.equal(2, #wins)
    for _, win in ipairs(wins) do
      assert.is_true(vim.wo[win].diff)
      assert.is_false(vim.wo[win].linebreak, "linebreak leaked onto a diff window")
      assert.is_false(vim.wo[win].breakindent, "breakindent leaked onto a diff window")
    end

    -- Back on the doc, its options come back with it.
    R.prev()
    assert.are.equal(1, R.state().index)
    local win = vim.api.nvim_get_current_win()
    assert.is_true(vim.wo[win].wrap)
    assert.is_true(vim.wo[win].linebreak)
    assert.is_true(vim.wo[win].breakindent)
  end)

  it("pair_path, the session uris, and diffstat see the right side and no counts", function()
    local R = require("pjollrig.review")
    local doc = make_doc_pair("plan.md")
    local files = { doc, make_pairs(1)[1] }
    assert.are.equal(doc.right, R.pair_path(doc))
    local stats = R.diffstat(files)
    assert.is_nil(stats[1], "a doc pair has no diffstat")
    assert.are.same({ added = 1, removed = 1 }, stats[2])

    assert.is_true(R.start({ files = files, label = "doc-cache" }))
    local state = R.state()
    local uri = require("pjollrig.uri").for_path(doc.right)
    assert.are.equal(uri, state.uris[1])
    assert.is_true(state.uri_set[uri])
    assert.are.equal(1, state.uri_index[uri])
    wait_diffstat()
    assert.is_nil(R.diffstat()[1])
    assert.are.same({ added = 1, removed = 1 }, R.diffstat()[2])
  end)

  it("comments on a doc pair count as the session's", function()
    local R = require("pjollrig.review")
    local doc = make_doc_pair("plan.md")
    assert.is_true(R.start({ files = { doc }, label = "doc-comment" }))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("tighten this paragraph")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt

    local state = R.state()
    local records = require("pjollrig").list({ uris = state.uri_set }, { root = state.root })
    assert.are.equal(1, #records)
    assert.are.equal("tighten this paragraph", records[1].body)
    assert.are.equal(state.uris[1], records[1].uri)
  end)
end)

describe("pjollrig review right panel + comments rail", function()
  before_each(function()
    ctx = H.setup({ review = { panel = { position = "right" } }, ui = { eol_expand = "rail" } })
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.ui.rail").close()
    end)
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("coexist: the rail opens beside a right-positioned panel", function()
    local R = require("pjollrig.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "rail-coexist" }))
    local panel_winid = require("pjollrig.review.panel").winid()
    assert.is_truthy(panel_winid, "panel window not open")

    -- Comment on the worktree line, then move the cursor onto it: the
    -- eol expansion renders into the rail (ui.eol_expand = "rail").
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("rail me")
    end
    -- Focus the worktree window (review.open leaves it current, but the
    -- panel may have been rendered since; be explicit).
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].modifiable and vim.bo[bufnr].filetype ~= "pjollrig-panel" then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("pjollrig").add()
    ui.prompt = original_prompt

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })

    local rail_winid
    vim.wait(1000, function()
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(winid)].filetype == "pjollrig-rail" then
          rail_winid = winid
          return true
        end
      end
      return false
    end, 10)

    assert.is_truthy(rail_winid, "rail did not open next to the right panel")
    assert.is_true(vim.api.nvim_win_is_valid(panel_winid), "rail displaced the right panel")
    -- Both are full-height right-side columns; neither stomped the other.
    assert.are_not.equal(rail_winid, panel_winid)
    local panel_col = vim.api.nvim_win_get_position(panel_winid)[2]
    local rail_col = vim.api.nvim_win_get_position(rail_winid)[2]
    assert.are_not.equal(panel_col, rail_col)
  end)
end)
