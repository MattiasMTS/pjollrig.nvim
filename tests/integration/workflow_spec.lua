local H = require("helpers")

local ctx

local function setup_env()
  -- Several workflows assert on float popups; the shipped default is
  -- `ui.display_mode = "eol"`, so opt into float mode explicitly.
  ctx = H.setup({ ui = { display_mode = "float" } })
  H.edit_project_file(ctx, "src/example.lua", {
    "local value = 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

local function floating_windows_containing(text)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      if cfg.relative and cfg.relative ~= "" then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local lines = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if lines:find(text, 1, true) then
          table.insert(wins, winid)
        end
      end
    end
  end
  return wins
end

local function wait_for_popup_count(text, expected)
  return vim.wait(1000, function()
    return #floating_windows_containing(text) == expected
  end, 10)
end

local function new_store_client()
  return dofile(vim.fn.getcwd() .. "/lua/pjollrig/store.lua")
end

describe("pjollrig headless workflow", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("adds, lists, sends, and keeps comments when the sink is non-consuming", function()
    local events, stop_capture = H.capture_events({ "PjollrigAdded", "PjollrigSent" })
    local calls = H.register_fake_sink("fake")

    require("pjollrig").add({
      body = "review this line",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    assert.are.equal("review this line", records[1].body)
    assert.are.equal("project", records[1].scope)
    assert.are.equal(ctx.root, records[1].project_root)

    require("pjollrig").send("fake", nil, { target = "agent-a" })

    assert.are.equal(1, #calls)
    assert.are.equal("agent-a", calls[1].ctx.target)
    assert.are.equal(1, #calls[1].comments)
    assert.are.equal(records[1].id, calls[1].comments[1].id)
    assert.are.equal("review this line", calls[1].comments[1].body)

    local remaining = require("pjollrig").list()
    assert.are.equal(1, #remaining)
    assert.are.equal(records[1].id, remaining[1].id)

    assert.are.equal("PjollrigAdded", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)
    assert.are.equal("PjollrigSent", events[2].pattern)
    assert.are.equal("fake", events[2].data.sink)
    assert.are.equal(1, events[2].data.count)
    assert.is_true(events[2].data.ok)

    stop_capture()
  end)

  it("list() syncs extmark positions by default; opts.sync = false reads as-is", function()
    require("pjollrig").add({
      body = "tracks its line",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    local before = require("pjollrig").list()[1].range.start[1]

    -- Push the commented line down: the anchor extmark follows the text,
    -- but the record's stored range only catches up through a syncing
    -- list() (or another mutating path).
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- inserted above" })

    local stale = require("pjollrig").list(nil, { sync = false })[1]
    assert.are.equal(before, stale.range.start[1], "sync = false still moved the record")

    local synced = require("pjollrig").list()[1]
    assert.are.equal(before + 1, synced.range.start[1], "default list() did not sync the moved extmark")
  end)

  it("can drive the command path with a fake prompt and consuming sink", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local events, stop_capture = H.capture_events({ "PjollrigAdded", "PjollrigSent", "PjollrigDeleted" })
    local calls = H.register_fake_sink("consume", { clear_on_success = true })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("from prompt")
    end

    vim.cmd("PjollrigAdd")
    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    assert.are.equal("from prompt", records[1].body)

    vim.cmd("PjollrigSend consume")

    ui.prompt = original_prompt

    assert.are.equal(1, #calls)
    assert.are.equal(1, #calls[1].comments)
    assert.are.equal("from prompt", calls[1].comments[1].body)
    assert.are.equal(0, #require("pjollrig").list())

    assert.are.equal("PjollrigAdded", events[1].pattern)
    assert.are.equal("PjollrigSent", events[2].pattern)
    assert.are.equal("PjollrigDeleted", events[3].pattern)

    stop_capture()
  end)

  it("can drive add and edit through the command path", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local events, stop_capture = H.capture_events({ "PjollrigAdded", "PjollrigEdited" })
    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    local responses = { "initial body", "edited body" }
    ui.prompt = function(opts, cb)
      assert.is_truthy(opts.prompt:match("Comment") or opts.prompt:match("Edit"))
      cb(table.remove(responses, 1))
    end

    vim.cmd("PjollrigAdd")
    vim.cmd("PjollrigEdit 1")
    ui.prompt = original_prompt

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    assert.are.equal("edited body", records[1].body)
    assert.are.equal(0, #responses)

    assert.are.equal("PjollrigAdded", events[1].pattern)
    assert.are.equal("initial body", events[1].data.body)
    assert.are.equal("PjollrigEdited", events[2].pattern)
    assert.are.equal(records[1].id, events[2].data.id)
    assert.are.equal("edited body", events[2].data.body)

    stop_capture()
  end)

  it("jumps between current-buffer comments with commands and default maps", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    H.edit_project_file(ctx, "src/navigation.lua", {
      "local one = 1",
      "local two = 2",
      "local three = 3",
      "return one + two + three",
    })

    local pjollrig = require("pjollrig")
    pjollrig.add({
      body = "first jump target",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    pjollrig.add({
      body = "second jump target",
      range = { start = { 2, 0 }, end_ = { 2, 0 } },
    })
    pjollrig.add({
      body = "third jump target",
      range = { start = { 3, 0 }, end_ = { 3, 0 } },
    })

    assert.are.equal("Pjollrig: next comment", vim.fn.maparg("]m", "n", false, true).desc)
    assert.are.equal("Pjollrig: previous comment", vim.fn.maparg("[m", "n", false, true).desc)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_true(pjollrig.jump("next"))
    assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))

    assert.is_true(pjollrig.jump("prev"))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))

    vim.cmd("PjollrigNext 2")
    assert.are.same({ 4, 0 }, vim.api.nvim_win_get_cursor(0))

    vim.cmd("PjollrigPrev")
    assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("deletes a project record through the project comments panel", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local events, stop_capture = H.capture_events({ "PjollrigDeleted" })

    require("pjollrig").add({
      body = "delete from panel",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)

    local qf_title_before = vim.fn.getqflist({ title = 1 }).title
    vim.cmd("PjollrigList")

    -- :PjollrigList opens the panel in project mode and never touches
    -- the quickfix list.
    local panel = require("pjollrig.review.panel")
    local panel_winid = assert(panel.winid(), "project-mode panel did not open")
    assert.are.equal(panel_winid, vim.api.nvim_get_current_win())
    assert.are.equal("pjollrig-panel", vim.bo[vim.api.nvim_win_get_buf(panel_winid)].filetype)
    assert.are.equal(qf_title_before, vim.fn.getqflist({ title = 1 }).title)
    assert.are.equal(0, #vim.fn.getqflist())

    vim.api.nvim_win_set_cursor(panel_winid, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("dd", true, false, true), "mx", false)

    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(panel.bufnr(), 0, -1, false)
      return #require("pjollrig.store").all(ctx.root) == 0 and not lines[1]:find("delete from panel", 1, true)
    end, 10))
    assert.are.equal("PjollrigDeleted", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)

    panel.close()
    stop_capture()
  end)

  it("edits a project record through the panel and repaints the source popup", function()
    vim.cmd("runtime plugin/pjollrig.lua")

    require("pjollrig").add({
      body = "edit from panel before",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("edit from panel before", 1))

    vim.cmd("PjollrigList")
    local panel = require("pjollrig.review.panel")
    local panel_winid = assert(panel.winid(), "project-mode panel did not open")
    vim.api.nvim_set_current_win(panel_winid)
    vim.api.nvim_win_set_cursor(panel_winid, { 1, 0 })

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ce", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      return require("pjollrig.ui.editor").is_active()
    end, 10))

    local editor_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[editor_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "edit from panel after" })
    vim.bo[editor_bufnr].modifiable = false
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

    assert.is_true(vim.wait(1000, function()
      local records = require("pjollrig.store").all(ctx.root)
      return records[1] and records[1].body == "edit from panel after"
    end, 10))
    assert.is_true(vim.wait(1000, function()
      return not require("pjollrig.ui.editor").is_active()
    end, 10))

    assert.is_true(wait_for_popup_count("edit from panel before", 0))
    assert.is_true(wait_for_popup_count("edit from panel after", 1))
    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(panel.bufnr(), 0, -1, false)
      return #lines == 1 and lines[1]:find("edit from panel after", 1, true) ~= nil
    end, 10))

    panel.close()
  end)

  it("uses insert enter for newlines and normal enter for submitting the comment editor", function()
    vim.cmd("runtime plugin/pjollrig.lua")

    vim.cmd("PjollrigAdd")
    assert.is_true(vim.wait(1000, function()
      return require("pjollrig.ui.editor").is_active()
    end, 10))
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("iline one<CR>line two", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      return lines[1] == "line one" and lines[2] == "line two"
    end, 10))
    assert.is_true(require("pjollrig.ui.editor").is_active())

    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      return not require("pjollrig.ui.editor").is_active()
    end, 10))

    assert.is_true(vim.wait(1000, function()
      return #require("pjollrig").list() == 1
    end, 10))
    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    assert.are.equal("line one\nline two", records[1].body)
  end)

  it("cancels and discards the comment editor when focus leaves it", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local anchor_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(anchor_win)

    vim.cmd("PjollrigAdd")
    assert.is_true(vim.wait(1000, function()
      return require("pjollrig.ui.editor").is_active()
    end, 10))

    local editor_bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "discard this draft" })
    vim.api.nvim_set_current_win(target_win)

    assert.is_true(vim.wait(1000, function()
      return not require("pjollrig.ui.editor").is_active()
    end, 10))
    assert.are.equal(target_win, vim.api.nvim_get_current_win())
    assert.are.equal(0, #require("pjollrig").list())
  end)

  it("keeps insert enter as newline when other plugins map enter", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local augroup = vim.api.nvim_create_augroup("PjollrigTestEditorEnterConflict", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = augroup,
      once = true,
      callback = function(args)
        vim.keymap.set("i", "<CR>", function()
          vim.g.pjollrig_test_conflicting_cr = true
        end, { buffer = args.buf })
      end,
    })

    vim.cmd("PjollrigAdd")
    assert.is_true(vim.wait(1000, function()
      local map = vim.fn.maparg("<CR>", "i", false, true)
      return type(map) == "table" and map.rhs == "<CR>"
    end, 10))
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("iconflict first<CR>conflict second", true, false, true),
      "mx",
      false
    )
    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      return lines[1] == "conflict first" and lines[2] == "conflict second"
    end, 10))
    assert.is_nil(vim.g.pjollrig_test_conflicting_cr)

    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      return #require("pjollrig").list() == 1
    end, 10))
    local records = require("pjollrig").list()
    assert.are.equal("conflict first\nconflict second", records[1].body)
  end)

  it("keeps existing popups visible while the add editor is open", function()
    require("pjollrig").add({
      body = "visible while adding",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("visible while adding", 1))

    require("pjollrig").add({
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    assert.is_true(vim.wait(1000, function()
      return require("pjollrig.ui.editor").is_active()
    end, 10))

    vim.wait(50, function()
      return false
    end, 10)
    assert.is_true(wait_for_popup_count("visible while adding", 1))

    require("pjollrig.ui.editor").close_active()
    assert.is_true(vim.wait(1000, function()
      return not require("pjollrig.ui.editor").is_active()
    end, 10))
  end)

  it("keeps other visible popups rendered after deleting one comment", function()
    require("pjollrig").add({
      body = "delete only this popup",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "keep this popup visible",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    assert.is_true(wait_for_popup_count("delete only this popup", 1))
    assert.is_true(wait_for_popup_count("keep this popup visible", 1))

    local records = require("pjollrig").list()
    local delete_id
    for _, record in ipairs(records) do
      if record.body == "delete only this popup" then
        delete_id = record.id
      end
    end
    assert.is_truthy(delete_id)

    require("pjollrig").delete(delete_id)

    assert.is_true(wait_for_popup_count("delete only this popup", 0))
    assert.is_true(wait_for_popup_count("keep this popup visible", 1))
  end)

  it("polls the SQLite WAL store and renders comments from another client", function()
    require("pjollrig").setup({
      store = {
        dir = ctx.state .. "/",
        format = "json",
        canonicalize_symlinks = false,
        poll_interval_ms = 20,
      },
      sinks = {
        clipboard = false,
        cmux = false,
      },
    })
    local store_a = require("pjollrig.store")
    local store_b = new_store_client()
    local uri = require("pjollrig.uri").for_bufnr(0)

    assert.are.equal(0, #store_a.load(ctx.root))
    store_b.put(ctx.root, {
      id = "external-1",
      uri = uri,
      scope = "project",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "from another nvim",
      author = "",
      created_at = 1,
      updated_at = 1,
      resolved = false,
      meta = {},
    })
    assert.is_true(store_b.save(ctx.root))

    assert.is_true(wait_for_popup_count("from another nvim", 1))
    assert.are.equal(1, #store_a.all(ctx.root))
  end)

  it("persists extmark movement on write", function()
    local store = require("pjollrig.store")
    require("pjollrig").add({
      body = "follow the line",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    local root = store.root()
    assert.is_truthy(root)

    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted above" })
    vim.cmd("silent write")

    store._reset()
    local reloaded = store.all(root)
    assert.are.equal(1, #reloaded)
    assert.are.equal(2, reloaded[1].range.start[1])
  end)

  it("keeps rejected add and cancelled edit side-effect free", function()
    local events, stop_capture = H.capture_events({ "PjollrigAdded", "PjollrigEdited" })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    vim.cmd("enew")
    local rejected_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[rejected_bufnr].buftype = "quickfix"
    require("pjollrig").add({
      body = "should not persist",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    vim.notify = original_notify

    assert.are.equal(0, #require("pjollrig").list())
    assert.are.equal(0, #events)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("quickfix buffers don't accept comments", 1, true))

    H.edit_project_file(ctx, "src/example.lua", {
      "local value = 1",
      "return value",
    })
    require("pjollrig").add({
      body = "keep this body",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()
    assert.are.equal(1, #records)

    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("")
    end
    require("pjollrig").edit(records[1].id)
    ui.prompt = original_prompt

    local after_cancel = require("pjollrig").list()
    assert.are.equal(1, #after_cancel)
    assert.are.equal("keep this body", after_cancel[1].body)
    assert.are.equal(1, #events)
    assert.are.equal("PjollrigAdded", events[1].pattern)

    stop_capture()
  end)

  it("does not emit add events when persistence fails", function()
    local events, stop_capture = H.capture_events({ "PjollrigAdded" })
    local notifications = {}
    local store = require("pjollrig.store")
    local original_save = store.save
    local original_notify = vim.notify
    store.save = function()
      return false, "disk full"
    end
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    require("pjollrig").add({
      body = "must not emit",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    store.save = original_save
    vim.notify = original_notify

    assert.are.equal(0, #events)
    assert.are.equal(0, #require("pjollrig").list())
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("failed to persist new comment", 1, true))

    stop_capture()
  end)

  it("keeps comments when a consuming sink reports failure", function()
    local events, stop_capture = H.capture_events({ "PjollrigAdded", "PjollrigSent", "PjollrigDeleted" })
    local calls = H.register_fake_sink("fail-consume", {
      clear_on_success = true,
      ok = false,
      err = "sink exploded",
    })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    require("pjollrig").add({
      body = "must remain",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local before_send = require("pjollrig").list()
    require("pjollrig").send("fail-consume")
    vim.notify = original_notify

    local after_send = require("pjollrig").list()
    assert.are.equal(1, #calls)
    assert.are.equal(1, #after_send)
    assert.are.equal(before_send[1].id, after_send[1].id)
    assert.are.equal("must remain", after_send[1].body)

    assert.are.equal("PjollrigAdded", events[1].pattern)
    assert.are.equal("PjollrigSent", events[2].pattern)
    assert.are.equal("fail-consume", events[2].data.sink)
    assert.is_false(events[2].data.ok)
    assert.are.equal("sink exploded", events[2].data.err)
    assert.are.equal(2, #events)

    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find('sink "fail%-consume" failed'))

    stop_capture()
  end)

  it("paints the buffer in a single pass when a comment is added", function()
    local pjollrig = require("pjollrig")
    -- Drain callbacks scheduled by setup's edit (BufWinEnter attach).
    vim.wait(50, function()
      return false
    end, 10)

    local bufnr = vim.api.nvim_get_current_buf()
    local adapter = require("pjollrig.adapter")
    local original_identify = adapter.identify
    local identify_calls = 0
    adapter.identify = function(b, ...)
      if b == bufnr then
        identify_calls = identify_calls + 1
      end
      return original_identify(b, ...)
    end

    -- With a body, add() runs synchronously — nothing scheduled can
    -- inflate the count before the spy is removed.
    pjollrig.add({
      body = "single pass",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    adapter.identify = original_identify

    -- finalize_add resolves identity twice itself (record build + the
    -- invariant canary); the repaint must add exactly ONE more pass —
    -- not two (reconcile + viewport each re-identifying and re-reading
    -- the store).
    assert.are.equal(3, identify_calls)
  end)

  it("repaints buffers once per consuming send, not once per cleared record", function()
    local calls = H.register_fake_sink("consume-batch", { clear_on_success = true })
    local pjollrig = require("pjollrig")
    for i = 1, 3 do
      pjollrig.add({
        body = "batch clear " .. i,
        range = { start = { i - 1, 0 }, end_ = { i - 1, 0 } },
      })
    end
    assert.are.equal(3, #pjollrig.list())

    -- Drain callbacks already scheduled by the adds (and by earlier
    -- tests in this Neovim instance) so the counter below only sees
    -- work caused by the send itself.
    vim.wait(50, function()
      return false
    end, 10)

    local target_bufnr = vim.api.nvim_get_current_buf()
    local render = require("pjollrig.ui.render")
    local original_reconcile = render.reconcile
    local reconcile_calls = 0
    render.reconcile = function(bufnr, ...)
      if bufnr == target_bufnr then
        reconcile_calls = reconcile_calls + 1
      end
      return original_reconcile(bufnr, ...)
    end

    local events, stop_capture = H.capture_events({ "PjollrigDeleted" })
    pjollrig.send("consume-batch")
    render.reconcile = original_reconcile

    assert.are.equal(1, #calls)
    assert.are.equal(0, #pjollrig.list())
    -- Event semantics unchanged: one PjollrigDeleted per cleared record.
    assert.are.equal(3, #events)
    -- Repaint batched: ONE refresh sweep after the clear loop, not one
    -- editor-wide repaint per deleted record.
    assert.are.equal(1, reconcile_calls)

    stop_capture()
  end)

  it("clears the pre-rename URI snapshot when the buffer unloads before BufFilePost lands", function()
    local path, bufnr = H.edit_project_file(ctx, "src/rename_me.lua", { "local x = 1" })
    -- `:file` fires BufFilePre (URI snapshotted) then BufFilePost, whose
    -- handler is deferred via vim.schedule. Wipe the buffer BEFORE the
    -- schedule drains: the deferred handler early-returns on the dead
    -- buffer, so only the BufUnload/BufDelete handler can clear the
    -- snapshot — without it the bufnr slot leaks a stale URI.
    vim.cmd("file " .. vim.fn.fnameescape(path .. ".renamed"))
    vim.cmd("bwipeout! " .. bufnr)
    vim.wait(100, function()
      return false
    end, 10)
    assert.is_nil(require("pjollrig")._pre_rename_uris()[bufnr])
  end)

  it("can send to the bundled cmux integration through a fake cmux cli", function()
    local bin, log = H.fake_cmux(ctx, {
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
    require("pjollrig").register_sink(require("pjollrig.sinks.cmux").setup({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      agent_state_dir = ctx.state,
      clear_on_success = true,
      pre_text = "Custom review rules",
      post_text = "Report back with the M IDs you handled.",
    }))
    local events, stop_capture = H.capture_events({ "PjollrigAdded", "PjollrigSent", "PjollrigDeleted" })

    require("pjollrig").add({
      body = "send this to the agent",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()

    local original_notify = vim.notify
    vim.notify = function() end
    require("pjollrig").send("cmux")
    -- The cmux send path is asynchronous (vim.system callbacks); wait for
    -- the full Added -> Sent -> Deleted event chain before asserting.
    vim.wait(2000, function()
      return #events >= 3
    end)
    vim.notify = original_notify

    assert.are.equal(0, #require("pjollrig").list())
    local log_lines = vim.fn.readfile(log)
    local log_text = table.concat(log_lines, "\n")
    assert.is_truthy(log_text:find("set%-buffer\tpjollrig%-", 1, false))
    assert.is_truthy(log_text:find("paste%-buffer\tsurface:2\tpjollrig%-", 1, false))
    assert.is_truthy(log_text:find("Pjollrig review (1 comment):", 1, true))
    assert.is_truthy(log_text:find("Custom review rules", 1, true))
    assert.is_truthy(log_text:find("## M1", 1, true))
    assert.is_truthy(log_text:find("send this to the agent", 1, true))
    assert.is_truthy(log_text:find("Report back with the M IDs you handled.", 1, true))
    assert.is_nil(log_text:find("send\tsurface:2", 1, true))
    assert.is_truthy(log_text:find("key\tsurface:2\tenter", 1, true))

    assert.are.equal("PjollrigAdded", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)
    assert.are.equal("PjollrigSent", events[2].pattern)
    assert.are.equal("cmux", events[2].data.sink)
    assert.is_true(events[2].data.ok)
    assert.are.equal("PjollrigDeleted", events[3].pattern)

    stop_capture()
  end)
end)
