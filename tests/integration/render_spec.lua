local H = require("helpers")

local ctx

local function setup_env()
  -- These specs exercise float-popup behavior; the shipped default is
  -- `ui.display_mode = "eol"`, so opt into float mode explicitly.
  ctx = H.setup({ ui = { display_mode = "float" } })
  H.edit_project_file(ctx, "src/render.lua", {
    "local value = 1",
    "value = value + 1",
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

local function popup_title(winid)
  local title = vim.api.nvim_win_get_config(winid).title
  if type(title) == "string" then
    return title
  end
  if type(title) == "table" then
    local parts = {}
    for _, item in ipairs(title) do
      if type(item) == "string" then
        table.insert(parts, item)
      elseif type(item) == "table" and type(item[1]) == "string" then
        table.insert(parts, item[1])
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

-- Wait until a popup containing `text` carries a title that includes
-- `needle`. Switching back to an already-loaded buffer re-renders its
-- popups (and thus their counters) asynchronously, so the title trails
-- the popup-window count by a tick — poll instead of reading it once.
local function wait_for_popup_title(text, needle)
  return vim.wait(1000, function()
    local winid = floating_windows_containing(text)[1]
    return winid ~= nil and popup_title(winid):find(needle, 1, true) ~= nil
  end, 10)
end

-- Return true only if a popup containing `text` stays present for the
-- whole observation window. `vim.wait` returns true when the predicate
-- fires; we invert it so a `false` here means "never disappeared". This
-- catches a transient hide (count momentarily 0) even when a later
-- refresh re-shows the popup.
local function popup_stays_visible(text)
  local vanished = vim.wait(150, function()
    return #floating_windows_containing(text) == 0
  end, 5)
  return not vanished
end

local function popup_screen_top(winid)
  local cfg = vim.api.nvim_win_get_config(winid)
  local bufpos = cfg.bufpos or { 0, 0 }
  return (tonumber(bufpos[1]) or 0) + (tonumber(cfg.row) or 0)
end

local function popup_screen_bottom(winid)
  local cfg = vim.api.nvim_win_get_config(winid)
  return popup_screen_top(winid) + (tonumber(cfg.height) or 1) + 1
end

describe("pjollrig render lifecycle", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("hides, restores, and clears popup state without losing anchors", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()

    pjollrig.add({
      body = "render note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = pjollrig.list()
    assert.are.equal(1, #records)

    local id = records[1].id
    assert.is_truthy(render.mark_ids_for_buffer(bufnr)[id])
    assert.is_true(wait_for_popup_count("render note", 1))
    assert.is_truthy(popup_title(floating_windows_containing("render note")[1]):find("1/1", 1, true))

    render.hide_all_popups(bufnr)
    assert.is_true(wait_for_popup_count("render note", 0))
    assert.is_truthy(render.mark_ids_for_buffer(bufnr)[id])

    render.update_viewport_popups(bufnr, records)
    assert.is_true(wait_for_popup_count("render note", 1))

    render.hide()
    assert.is_false(render.is_visible())
    assert.is_true(wait_for_popup_count("render note", 0))
    assert.is_truthy(render.mark_ids_for_buffer(bufnr)[id])

    render.show()
    assert.is_true(render.is_visible())
    assert.is_true(wait_for_popup_count("render note", 1))

    render.clear_buffer(bufnr)
    assert.are.same({}, render.mark_ids_for_buffer(bufnr))
    assert.is_true(wait_for_popup_count("render note", 0))
  end)

  it("keeps popups while the source buffer stays visible but loses focus", function()
    local pjollrig = require("pjollrig")
    local source_win = vim.api.nvim_get_current_win()

    pjollrig.add({
      body = "some note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("some note", 1))

    -- Open the quickfix list: a new window takes focus while the source
    -- window stays on screen. BufLeave/WinLeave fire on the source buffer,
    -- but its popup must persist — uninterrupted — because the buffer is
    -- still visible. The pre-fix behavior hid the popup on the focus-loss
    -- tick (count momentarily 0), so assert it never vanishes, not merely
    -- that it eventually reappears.
    vim.cmd("botright copen")
    assert.is_true(popup_stays_visible("some note"))
    assert.is_true(wait_for_popup_count("some note", 1))

    -- Genuine off-screen case: replacing the buffer in the source window so
    -- it is no longer displayed anywhere must hide the popups.
    vim.cmd("cclose")
    vim.api.nvim_set_current_win(source_win)
    vim.cmd("enew")
    assert.is_true(wait_for_popup_count("some note", 0))
  end)

  it(":PjollrigToggle emits visibility events and rebuilds real popup windows", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local events, stop_capture = H.capture_events({ "PjollrigVisibility" })

    require("pjollrig").add({
      body = "toggle note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("toggle note", 1))

    vim.cmd("PjollrigToggle")
    assert.is_false(require("pjollrig.ui.render").is_visible())
    assert.is_true(wait_for_popup_count("toggle note", 0))

    vim.cmd("PjollrigToggle")
    assert.is_true(require("pjollrig.ui.render").is_visible())
    assert.is_true(wait_for_popup_count("toggle note", 1))

    assert.are.equal(2, #events)
    assert.is_true(events[1].data.hidden)
    assert.is_false(events[2].data.hidden)

    stop_capture()
  end)

  it("stacks same-line popups by popup height", function()
    require("pjollrig").add({
      body = "stack top\nwith another line",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "stack second",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("stack top", 1))
    assert.is_true(wait_for_popup_count("stack second", 1))

    local first = floating_windows_containing("stack top")[1]
    local second = floating_windows_containing("stack second")[1]
    assert.is_truthy(first)
    assert.is_truthy(second)

    local first_row = tonumber(vim.api.nvim_win_get_config(first).row) or 0
    local second_row = tonumber(vim.api.nvim_win_get_config(second).row) or 0
    assert.is_true(math.abs(first_row - second_row) >= 3)

    local titles = {
      popup_title(first),
      popup_title(second),
    }
    table.sort(titles)
    assert.is_truthy(table.concat(titles, "\n"):find("1/2", 1, true))
    assert.is_truthy(table.concat(titles, "\n"):find("2/2", 1, true))
  end)

  it("numbers and separates adjacent visible popups", function()
    require("pjollrig").add({
      body = "adjacent first",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "adjacent second",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    assert.is_true(wait_for_popup_count("adjacent first", 1))
    assert.is_true(wait_for_popup_count("adjacent second", 1))

    local first = floating_windows_containing("adjacent first")[1]
    local second = floating_windows_containing("adjacent second")[1]
    assert.is_truthy(first)
    assert.is_truthy(second)

    assert.is_truthy(popup_title(first):find("1/2", 1, true))
    assert.is_truthy(popup_title(second):find("2/2", 1, true))
    assert.is_true(popup_screen_top(second) > popup_screen_bottom(first))
  end)

  it("keeps window options and the popup tag across a reconfigure-reuse render", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()

    pjollrig.add({
      body = "reuse options",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("reuse options", 1))
    local winid = floating_windows_containing("reuse options")[1]

    -- A follow-up viewport pass takes the reconfigure path (the popup
    -- window is reused, not recreated). One-time window state — the
    -- orphan-prune tag and the float window options — must still be in
    -- place on the reused window.
    local records = pjollrig.list()
    render.update_viewport_popups(bufnr, records, records)
    assert.are.equal(winid, floating_windows_containing("reuse options")[1])
    assert.is_true(vim.w[winid].pjollrig_popup)
    local winhighlight = vim.wo[winid].winhighlight
    assert.is_truthy(winhighlight:find("FloatBorder:PjollrigCommentBorder", 1, true))
    -- The card surface paints the whole popup window; the footer hint
    -- takes the receded border gray.
    assert.is_truthy(winhighlight:find("NormalFloat:PjollrigCardBg", 1, true))
    assert.is_truthy(winhighlight:find("FloatFooter:PjollrigCommentHint", 1, true))
    assert.is_false(vim.wo[winid].wrap)
  end)

  it("prunes an orphaned popup but keeps the tracked one", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")

    pjollrig.add({
      body = "orphan target",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("orphan target", 1))

    -- The tracked popup's winid lives on the record's handle.
    local records = pjollrig.list()
    local tracked_winid = floating_windows_containing("orphan target")[1]
    assert.is_truthy(tracked_winid)

    -- Simulate a leaked/reloaded float: a separate floating window over a
    -- scratch buffer that shows the same text and carries the
    -- `pjollrig_popup` win-var, but which no handle tracks.
    local orphan_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(orphan_buf, 0, -1, false, { "orphan target" })
    local orphan_win = vim.api.nvim_open_win(orphan_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 1,
      style = "minimal",
    })
    vim.api.nvim_win_set_var(orphan_win, "pjollrig_popup", true)
    assert.is_true(wait_for_popup_count("orphan target", 2))

    render.prune_orphan_popups()

    -- Only the tracked popup survives — by winid, not just by count.
    assert.is_true(wait_for_popup_count("orphan target", 1))
    assert.is_false(vim.api.nvim_win_is_valid(orphan_win))
    assert.are.equal(tracked_winid, floating_windows_containing("orphan target")[1])

    -- A follow-up viewport update still shows the tracked popup.
    render.update_viewport_popups(vim.api.nvim_get_current_buf(), records)
    assert.is_true(wait_for_popup_count("orphan target", 1))
  end)

  it("never closes a tracked popup when pruning", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")

    pjollrig.add({
      body = "keep me",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("keep me", 1))

    render.prune_orphan_popups()
    assert.is_true(wait_for_popup_count("keep me", 1))
  end)

  it("is a no-op when there are no tagged floats", function()
    local render = require("pjollrig.ui.render")
    -- No comments added: no tagged floats exist, so pruning must not error
    -- and must not touch any window.
    local before = #vim.api.nvim_list_wins()
    render.prune_orphan_popups()
    assert.are.equal(before, #vim.api.nvim_list_wins())
  end)

  it("handles a float open failure without throwing or leaking a scratch buffer", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")
    local float = require("pjollrig.ui.float")
    local bufnr = vim.api.nvim_get_current_buf()

    pjollrig.add({
      body = "open failure note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = pjollrig.list()

    -- Simulate `nvim_open_win` throwing inside `open_or_reconfigure`
    -- (the pcall there returns nil on failure). `render_comment_popup`
    -- must bail cleanly: no popup, no thrown error, and the orphaned
    -- scratch buffer must not accumulate across repeated renders.
    local original = float.open_or_reconfigure
    float.open_or_reconfigure = function()
      return nil
    end

    local function count_listed_bufs()
      return #vim.api.nvim_list_bufs()
    end

    local ok = pcall(function()
      render.update_viewport_popups(bufnr, records)
      render.update_viewport_popups(bufnr, records)
    end)
    local bufs_after_two = count_listed_bufs()
    local ok2 = pcall(function()
      render.update_viewport_popups(bufnr, records)
      render.update_viewport_popups(bufnr, records)
    end)
    local bufs_after_four = count_listed_bufs()

    float.open_or_reconfigure = original

    assert.is_true(ok)
    assert.is_true(ok2)
    -- No popup ever appeared while the open was failing.
    assert.are.equal(0, #floating_windows_containing("open failure note"))
    -- The scratch buffer is reused, not leaked: extra render passes do
    -- not grow the buffer list.
    assert.are.equal(bufs_after_two, bufs_after_four)

    -- Recovery: with the real opener restored, the popup renders again.
    render.update_viewport_popups(bufnr, records)
    assert.is_true(wait_for_popup_count("open failure note", 1))
  end)

  it("numbers popups across project records", function()
    local first_path = H.edit_project_file(ctx, "src/a.lua", {
      "local first = true",
    })
    require("pjollrig").add({
      body = "project first",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local second_path = H.edit_project_file(ctx, "src/z.lua", {
      "local second = true",
    })
    require("pjollrig").add({
      body = "project second",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("project second", 1))
    assert.is_true(wait_for_popup_title("project second", "2/2"))

    vim.cmd.edit(vim.fn.fnameescape(first_path))
    assert.is_true(wait_for_popup_count("project first", 1))
    assert.is_true(wait_for_popup_title("project first", "1/2"))

    vim.cmd.edit(vim.fn.fnameescape(second_path))
    assert.is_true(wait_for_popup_count("project second", 1))
    assert.is_true(wait_for_popup_title("project second", "2/2"))
  end)

  it("renders only one popup when a file is open in a same-URI codediff buffer", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")

    -- Working-tree buffer for the file the comment anchors to.
    local lines = { "local a = 1", "return a" }
    H.edit_project_file(ctx, "src/a.lua", lines)
    local work_buf = vim.api.nvim_get_current_buf()

    pjollrig.add({
      body = "wow nice",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("wow nice", 1))

    -- Open a codediff buffer for the SAME file in a split. The adapter
    -- maps `codediff:///<root>///HEAD/<path>` to the working-tree URI, so
    -- both buffers resolve to the same URI and would each render the popup.
    local cd_name = ("codediff:///%s///HEAD/%s"):format(ctx.root, "src/a.lua")
    vim.cmd("vsplit")
    local cd_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(cd_buf, cd_name)
    vim.bo[cd_buf].buftype = "nofile"
    vim.api.nvim_buf_set_lines(cd_buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, cd_buf)

    -- Confirm the collision: codediff buffer resolves to the same URI as
    -- the working buffer — that's what makes both render the popup.
    local adapter = require("pjollrig.adapter")
    assert.are.equal(adapter.identify(work_buf).uri, adapter.identify(cd_buf).uri)

    -- Drive a render against the codediff buffer; before the fix this
    -- pushes the popup count to 2 (one per same-URI buffer).
    local records = pjollrig.list()
    render.reconcile(cd_buf, records, records)
    render.update_viewport_popups(cd_buf, records, records)
    assert.is_true(wait_for_popup_count("wow nice", 1))

    -- The dedup must survive an edit (refresh_all_loaded re-renders every
    -- loaded buffer, including both same-URI buffers).
    local original_prompt = package.loaded["pjollrig.ui"].prompt
    package.loaded["pjollrig.ui"].prompt = function(_, cb)
      cb("edited body")
    end
    local id = records[1].id
    pjollrig.edit(id)
    vim.wait(200, function()
      return false
    end, 10)
    package.loaded["pjollrig.ui"].prompt = original_prompt
    assert.is_true(wait_for_popup_count("edited body", 1))

    -- Focus-follow: switching back to the working window and refreshing
    -- its viewport keeps exactly one popup.
    vim.cmd("wincmd p")
    render.update_viewport_popups(work_buf, pjollrig.list(), pjollrig.list())
    assert.is_true(wait_for_popup_count("edited body", 1))
  end)
end)

-- Occlusion-aware float placement. The right-margin spot is only used
-- when every buffer line the popup would vertically span leaves it on
-- genuinely empty cells (1-cell gap); otherwise the popup — or its whole
-- same-line stack, as a unit — drops below the anchor line, left-aligned
-- like the inline box (above the anchor when the window bottom leaves no
-- room below). Measurement assumes 'nowrap' (like the margin layout
-- math itself), so the long-line fixtures pin it explicitly.
describe("pjollrig float placement", function()
  -- Wider than any margin column a test window can offer.
  local LONG_LINE = "-- " .. string.rep("x", 200)

  before_each(function()
    ctx = H.setup({ ui = { display_mode = "float" } })
  end)
  after_each(teardown_env)

  it("keeps the popup at the margin when the spanned lines are short", function()
    H.edit_project_file(ctx, "src/short.lua", {
      "local value = 1",
      "value = value + 1",
      "return value",
      "return value",
    })
    vim.wo.wrap = false
    require("pjollrig").add({
      body = "margin note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("margin note", 1))
    local cfg = vim.api.nvim_win_get_config(floating_windows_containing("margin note")[1])
    local win_width = vim.api.nvim_win_get_width(0)
    -- Existing margin layout math: right margin inset by the popup width
    -- + fixed gutter, no stagger for the first visible popup, top row on
    -- the anchor line.
    assert.are.equal(0, cfg.bufpos[1])
    assert.are.equal(0, tonumber(cfg.row))
    assert.are.equal(math.max(2, win_width - cfg.width - 6), tonumber(cfg.col))
  end)

  it("relocates the popup below the anchor when the margin would cover code", function()
    H.edit_project_file(ctx, "src/long.lua", { LONG_LINE, LONG_LINE, LONG_LINE, LONG_LINE })
    vim.wo.wrap = false
    require("pjollrig").add({
      body = "occluded note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("occluded note", 1))
    local cfg = vim.api.nvim_win_get_config(floating_windows_containing("occluded note")[1])
    local win_width = vim.api.nvim_win_get_width(0)
    -- Sanity: the margin spot really was hiding code (the spanned lines
    -- reach past the would-be left edge minus the 1-cell gap).
    assert.is_true(vim.fn.strdisplaywidth(LONG_LINE) + 1 > math.max(2, win_width - cfg.width - 6))
    -- Fallback: anchored at the commented line, one row below it,
    -- left-aligned like the inline box — nowhere near the right margin.
    assert.are.equal(0, cfg.bufpos[1])
    assert.are.equal(1, tonumber(cfg.row))
    assert.are.equal(1, tonumber(cfg.col))
  end)

  it("falls back a same-line stack as a unit, still vertically stacked", function()
    H.edit_project_file(ctx, "src/stack-long.lua", {
      LONG_LINE,
      LONG_LINE,
      LONG_LINE,
      LONG_LINE,
      LONG_LINE,
      LONG_LINE,
      LONG_LINE,
      LONG_LINE,
    })
    vim.wo.wrap = false
    require("pjollrig").add({
      body = "unit fallback one",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "unit fallback two",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("unit fallback one", 1))
    assert.is_true(wait_for_popup_count("unit fallback two", 1))
    local first_cfg = vim.api.nvim_win_get_config(floating_windows_containing("unit fallback one")[1])
    local second_cfg = vim.api.nvim_win_get_config(floating_windows_containing("unit fallback two")[1])

    -- BOTH left the margin (never split between margin and below-line),
    -- both anchored to the commented line at the inline-box column.
    assert.are.equal(0, first_cfg.bufpos[1])
    assert.are.equal(0, second_cfg.bufpos[1])
    assert.are.equal(1, tonumber(first_cfg.col))
    assert.are.equal(1, tonumber(second_cfg.col))

    -- Still vertically stacked below the anchor: the stack head sits one
    -- row below the line, the next member a full popup (card + borders)
    -- further down. The card is 5 content rows here — 2 quote lines (the
    -- long anchored line wraps to the two-line cap), author, blank
    -- separator, 1 body row — so the next member starts at 1 + 5 + 2.
    -- Stack order is created_at/id, so assert set-wise.
    local rows = { tonumber(first_cfg.row), tonumber(second_cfg.row) }
    table.sort(rows)
    assert.are.equal(1, rows[1])
    assert.are.equal(8, rows[2])
  end)

  it("places the popup above the anchor on the last visible line", function()
    local win_height = vim.api.nvim_win_get_height(0)
    local lines = {}
    for _ = 1, win_height do
      table.insert(lines, LONG_LINE)
    end
    H.edit_project_file(ctx, "src/bottom.lua", lines)
    vim.wo.wrap = false
    -- Keep the window scrolled to the top so the anchor is the LAST
    -- visible line: no room for the popup below it.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("pjollrig").add({
      body = "bottom note",
      range = { start = { win_height - 1, 0 }, end_ = { win_height - 1, 0 } },
    })

    assert.is_true(wait_for_popup_count("bottom note", 1))
    local cfg = vim.api.nvim_win_get_config(floating_windows_containing("bottom note")[1])
    -- Above the anchor: the popup's bottom border rests on the row just
    -- above the anchor line (5 card rows — 2 quote lines for the long
    -- anchored line, author, blank, 1 body row — + 2 border rows =
    -- offset -7).
    assert.are.equal(win_height - 1, cfg.bufpos[1])
    assert.are.equal(-7, tonumber(cfg.row))
    assert.are.equal(1, tonumber(cfg.col))
  end)
end)

-- Sticky-mode regressions (#5, #6). Dedicated describe so the sticky
-- config doesn't bleed into the non-sticky specs above. `H.setup`
-- deep-merges the opts into the base config, so `ui = { always_show_popups = true }`
-- flips the renderer into "always show a popup for every record" mode;
-- teardown resets render state + reloads the default config on the next
-- `H.setup`.
describe("pjollrig sticky render", function()
  before_each(function()
    -- Sticky is a float-mode concern; pin the display mode like the
    -- non-sticky describe above.
    ctx = H.setup({ ui = { always_show_popups = true, display_mode = "float" } })
    H.edit_project_file(ctx, "src/sticky.lua", {
      "local value = 1",
      "value = value + 1",
      "return value",
    })
  end)
  after_each(teardown_env)

  it("keeps the popup when the source buffer loses focus but stays visible (#6)", function()
    local pjollrig = require("pjollrig")
    local source_win = vim.api.nvim_get_current_win()

    pjollrig.add({
      body = "sticky qf note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("sticky qf note", 1))

    -- Open the quickfix list so the source window loses focus but stays on
    -- screen. Under sticky `refresh_viewport` early-returns, so the
    -- keep-branch must route through reconcile to rebuild the popup.
    vim.cmd("botright copen")
    assert.is_true(wait_for_popup_count("sticky qf note", 1))

    vim.cmd("cclose")
    vim.api.nvim_set_current_win(source_win)
  end)

  it("rebuilds the popup after the anchor window is closed (#6)", function()
    local pjollrig = require("pjollrig")

    pjollrig.add({
      body = "sticky split note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("sticky split note", 1))

    -- Same buffer in two windows. The original (lower) window owns the
    -- float's `relative='win'` anchor; closing it makes Neovim auto-close
    -- the float. The WinClosed handler must rebuild the popup against the
    -- surviving window where the buffer is still visible.
    local original = vim.api.nvim_get_current_win()
    vim.cmd("split")
    assert.is_true(wait_for_popup_count("sticky split note", 1))

    vim.api.nvim_set_current_win(original)
    vim.cmd("close")
    assert.is_true(wait_for_popup_count("sticky split note", 1))
  end)

  it("relocates a sticky popup below the anchor when the margin would cover code", function()
    -- The sticky render path computes its own layout (no precomputed
    -- viewport layout), so it must make the same occlusion-aware
    -- placement decision the viewport pass makes.
    local long_line = "-- " .. string.rep("x", 200)
    H.edit_project_file(ctx, "src/sticky-long.lua", { long_line, long_line, long_line, long_line })
    vim.wo.wrap = false
    require("pjollrig").add({
      body = "sticky occluded note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("sticky occluded note", 1))
    local cfg = vim.api.nvim_win_get_config(floating_windows_containing("sticky occluded note")[1])
    assert.are.equal(0, cfg.bufpos[1])
    assert.are.equal(1, tonumber(cfg.row))
    assert.are.equal(1, tonumber(cfg.col))
  end)

  it("does not leak an orphaned float when the buffer is wiped before the scheduled render (#5)", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")

    -- Create a fresh, isolated buffer so wiping it can't disturb the
    -- project source buffer. Add a session-scope record to it, which
    -- schedules a sticky popup render, then wipe the buffer before the
    -- scheduled callback flushes. The stale render must be a no-op.
    local scratch = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(scratch)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "scratch line one", "scratch line two" })

    pjollrig.add({
      body = "sticky orphan note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    -- Wipe immediately, before flushing scheduled callbacks. clear_buffer
    -- (BufUnload/BufDelete) clears the handle, so the scheduled sticky
    -- render's liveness guard must bail without opening a float.
    vim.cmd("bwipeout! " .. scratch)

    -- Give every queued schedule a chance to run; assert no orphaned float
    -- ever appears.
    vim.wait(150, function()
      return false
    end, 10)
    assert.are.equal(0, #floating_windows_containing("sticky orphan note"))
  end)
end)

-- Google-Docs-style comment cards: every annotation view (float popup,
-- inline box, eol expansion) renders a quoted anchor excerpt, an
-- author + relative-time line, a blank separator, then the body; the
-- edit/delete hint stays at the bottom (the float keeps it in the
-- border footer). The excerpt is captured at add time into
-- `meta.excerpt` so the card quotes the ORIGINAL text even after the
-- code changes; records that predate capture fall back to the current
-- buffer line at the anchored range.
describe("pjollrig comment card", function()
  before_each(setup_env)
  after_each(teardown_env)

  local function popup_footer(winid)
    local footer = vim.api.nvim_win_get_config(winid).footer
    if type(footer) == "string" then
      return footer
    end
    if type(footer) == "table" then
      local parts = {}
      for _, item in ipairs(footer) do
        if type(item) == "string" then
          table.insert(parts, item)
        elseif type(item) == "table" and type(item[1]) == "string" then
          table.insert(parts, item[1])
        end
      end
      return table.concat(parts, "")
    end
    return ""
  end

  local function popup_lines(text)
    local winid = floating_windows_containing(text)[1]
    assert.is_truthy(winid)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false), winid
  end

  it("formats relative time against a fixed clock", function()
    local rt = require("pjollrig.ui.color").relative_time
    local now = os.time({ year = 2026, month = 8, day = 25, hour = 12, min = 0, sec = 0 })
    assert.are.equal("just now", rt(now, now))
    assert.are.equal("just now", rt(now - 59, now))
    assert.are.equal("1m ago", rt(now - 60, now))
    assert.are.equal("59m ago", rt(now - 3599, now))
    assert.are.equal("1h ago", rt(now - 90 * 60, now))
    assert.are.equal("23h ago", rt(now - 86400 + 1, now))
    assert.are.equal("1d ago", rt(now - 86400, now))
    assert.are.equal("3d ago", rt(now - 3 * 86400, now))
    assert.are.equal("30d ago", rt(now - 30 * 86400, now))
    -- Past 30 days the label falls back to the old footer's absolute date.
    local old = now - 31 * 86400
    assert.are.equal(os.date("%b %d %H:%M", old), rt(old, now))
    -- A future timestamp (clock skew) clamps to "just now".
    assert.are.equal("just now", rt(now + 120, now))
  end)

  it("renders quote, author/time, blank, body — hint stays in the footer", function()
    require("pjollrig").add({
      body = "card body",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("card body", 1))

    local lines, winid = popup_lines("card body")
    assert.are.equal(4, #lines)
    assert.are.equal('▍ "local value = 1"', lines[1])
    assert.is_truthy(lines[2]:match("^%S.* · just now$"))
    assert.is_nil(lines[2]:find("▍", 1, true))
    assert.are.equal("", lines[3])
    assert.are.equal("card body", lines[4])
    -- The stack position stays visible in the box title; the hint keeps
    -- the border footer to itself (no date prefix anymore).
    assert.is_truthy(popup_title(winid):find("1/1", 1, true))
    assert.are.equal("edit gca | delete gcd", popup_footer(winid))
    -- The window is exactly as tall as the card content.
    assert.are.equal(4, tonumber(vim.api.nvim_win_get_config(winid).height))
  end)

  it("captures the excerpt at add time and quotes it after the line changes", function()
    local pjollrig = require("pjollrig")
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()

    pjollrig.add({
      body = "excerpt note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = pjollrig.list()
    assert.are.equal("local value = 1", records[1].meta.excerpt)

    -- The anchored line changes: the card keeps quoting the ORIGINAL
    -- text (the excerpt cites what was commented on).
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local value = 999" })
    render.update_viewport_popups(bufnr, records, records)
    assert.is_true(wait_for_popup_count("excerpt note", 1))
    local lines = popup_lines("excerpt note")
    assert.are.equal('▍ "local value = 1"', lines[1])
  end)

  it("marks a multi-line range excerpt with a continuation ellipsis", function()
    require("pjollrig").add({
      body = "span note",
      range = { start = { 0, 0 }, end_ = { 1, 0 } },
    })
    local records = require("pjollrig").list()
    assert.are.equal("local value = 1…", records[1].meta.excerpt)
  end)

  it("quotes the live buffer line for records without a stored excerpt", function()
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    local record = {
      id = "pre-excerpt-1",
      uri = require("pjollrig.uri").for_bufnr(bufnr),
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
      body = "legacy note",
      author = "octocat",
      created_at = os.time(),
      updated_at = os.time(),
      resolved = false,
      meta = {},
    }
    render.reconcile(bufnr, { record }, { record })
    render.update_viewport_popups(bufnr, { record }, { record })
    assert.is_true(wait_for_popup_count("legacy note", 1))

    local lines = popup_lines("legacy note")
    assert.are.equal('▍ "value = value + 1"', lines[1])
    assert.is_truthy(lines[2]:find("octocat · just now", 1, true))
  end)

  it("skips the quote when neither excerpt nor buffer text is available", function()
    H.edit_project_file(ctx, "src/blank.lua", { "", "return true" })
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    local record = {
      id = "no-quote-1",
      uri = require("pjollrig.uri").for_bufnr(bufnr),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "quoteless note",
      author = "octocat",
      created_at = os.time(),
      updated_at = os.time(),
      resolved = false,
      meta = {},
    }
    render.reconcile(bufnr, { record }, { record })
    render.update_viewport_popups(bufnr, { record }, { record })
    assert.is_true(wait_for_popup_count("quoteless note", 1))

    local lines = popup_lines("quoteless note")
    assert.are.equal(3, #lines)
    assert.is_truthy(lines[1]:find("octocat · just now", 1, true))
    assert.are.equal("", lines[2])
    assert.are.equal("quoteless note", lines[3])
    assert.is_nil(table.concat(lines, "\n"):find("▍", 1, true))
  end)

  it("caps the quote at two display lines with a trailing ellipsis", function()
    local long_line = ("local phrase = phrase .. ' word' "):rep(12):gsub("%s+$", "")
    H.edit_project_file(ctx, "src/longline.lua", { long_line, "return phrase" })
    require("pjollrig").add({
      body = "cap note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("cap note", 1))

    local lines = popup_lines("cap note")
    -- Two quote lines, then author, blank, body.
    assert.are.equal(5, #lines)
    assert.is_truthy(lines[1]:find("▍ ", 1, true) == 1)
    assert.is_truthy(lines[2]:find("▍ ", 1, true) == 1)
    assert.are.equal('…"', lines[2]:sub(-#'…"'))
    assert.is_nil(lines[3]:find("▍", 1, true))
  end)
end)

-- Origin badges on the card's author line: `<badge> author · time`.
-- github-imported records (`meta.github`) badge in every icon mode;
-- local records badge only in glyph mode — the ASCII local fallback is
-- a plain bullet that would prefix EVERY local card with noise while
-- distinguishing nothing (local is the unmarked default), so the
-- icons-off card look stays as before. The badge is purely ORIGIN,
-- never state: resolution stays on the listing surfaces (quickfix
-- `[x]`, picker `✓` prefix, review panel `✓` on GitHub-resolved
-- threads) and is not re-marked in the card.
describe("pjollrig card origin badges", function()
  before_each(setup_env)

  after_each(function()
    package.preload["mini.icons"] = nil
    package.loaded["mini.icons"] = nil
    pcall(function()
      require("pjollrig.ui.icons")._reset()
    end)
    teardown_env()
  end)

  local function popup_lines(text)
    local winid = floating_windows_containing(text)[1]
    assert.is_truthy(winid)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false), winid
  end

  ---Force glyph mode without the real plugins: stub a provider module
  ---via package.preload (the icons_spec pattern) and re-probe.
  local function enable_glyph_mode()
    package.preload["mini.icons"] = function()
      return {
        get = function()
          return "X", "MiniIconsAzure", false
        end,
      }
    end
    require("pjollrig.config").get().ui.icons = "auto"
    require("pjollrig.ui.icons")._reset()
  end

  local function make_record(over)
    over = over or {}
    local bufnr = vim.api.nvim_get_current_buf()
    return {
      id = over.id or "badge-rec-1",
      uri = require("pjollrig.uri").for_bufnr(bufnr),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = over.body or "badge body",
      author = over.author or "octocat",
      created_at = os.time(),
      updated_at = os.time(),
      resolved = over.resolved or false,
      meta = over.meta or {},
    }
  end

  ---Render `record` through the normal float pipeline and return its
  ---card lines + popup winid.
  local function card_lines(record)
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    render.reconcile(bufnr, { record }, { record })
    render.update_viewport_popups(bufnr, { record }, { record })
    assert.is_true(wait_for_popup_count(record.body, 1))
    return popup_lines(record.body)
  end

  it("prefixes the github author line with [gh] in ASCII mode", function()
    require("pjollrig.config").get().ui.icons = false
    local lines = card_lines(make_record({ meta = { github = { id = 7, imported = true } } }))
    assert.are.equal("[gh] octocat · just now", lines[2])
  end)

  it("keeps the local author line bare in ASCII mode", function()
    require("pjollrig.config").get().ui.icons = false
    local lines = card_lines(make_record({}))
    assert.are.equal("octocat · just now", lines[2])
  end)

  it("badges both origins in glyph mode", function()
    enable_glyph_mode()
    local gh_lines = card_lines(make_record({
      id = "badge-gh",
      body = "glyph github body",
      meta = { github = { id = 7, imported = true } },
    }))
    assert.are.equal("\u{F09B} octocat · just now", gh_lines[2])

    local local_lines = card_lines(make_record({ id = "badge-local", body = "glyph local body" }))
    assert.are.equal("\u{F0B79} octocat · just now", local_lines[2])
  end)

  it("counts the badge into the card width", function()
    require("pjollrig.config").get().ui.icons = false
    -- The author line is the card's widest line (hint is 21 cells,
    -- quote 19), so the popup width must equal it INCLUDING the badge.
    local author = "review-bot-nine"
    local lines, winid = card_lines(make_record({
      body = "w",
      author = author,
      meta = { github = { id = 7, imported = true } },
    }))
    local expected = "[gh] " .. author .. " · just now"
    -- Untruncated: the width math budgeted for the badge.
    assert.are.equal(expected, lines[2])
    assert.are.equal(vim.fn.strdisplaywidth(expected), tonumber(vim.api.nvim_win_get_config(winid).width))
  end)

  it("keeps the origin badge on resolved records — resolution is not a card badge", function()
    require("pjollrig.config").get().ui.icons = false
    local gh_lines = card_lines(make_record({
      id = "badge-resolved-gh",
      body = "resolved github body",
      resolved = true,
      meta = { github = { id = 7, imported = true, resolved = true } },
    }))
    assert.are.equal("[gh] octocat · just now", gh_lines[2])
    assert.is_nil(table.concat(gh_lines, "\n"):find("✓", 1, true))

    local local_lines = card_lines(make_record({
      id = "badge-resolved-local",
      body = "resolved local body",
      resolved = true,
    }))
    assert.are.equal("octocat · just now", local_lines[2])
    assert.is_nil(table.concat(local_lines, "\n"):find("✓", 1, true))
  end)
end)

-- Card palette: every color DERIVED from the active colorscheme — the
-- surface is Normal bg nudged 6% toward Normal fg, the border recedes
-- 45% toward the bg, the quote bar takes the DiagnosticSignInfo accent,
-- the author is bold Normal fg, badges take Special / teal-chain fgs —
-- recomputed on ColorScheme. Tests stub the scheme's SOURCE groups,
-- recompute, and assert the computed groups equal the formulas' output
-- (never hardcoded theme hex). Stubbed groups are snapshotted and
-- restored after each test so palette changes don't leak across specs.
describe("pjollrig card palette", function()
  local STUB_GROUPS =
    { "Normal", "NormalFloat", "FloatBorder", "Comment", "DiagnosticSignInfo", "Special", "@string", "Identifier" }
  local saved_hls

  before_each(function()
    setup_env()
    saved_hls = {}
    for _, name in ipairs(STUB_GROUPS) do
      saved_hls[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
    end
  end)

  after_each(function()
    for name, group in pairs(saved_hls) do
      vim.api.nvim_set_hl(0, name, group)
    end
    require("pjollrig.ui.render").refresh_highlights()
    package.preload["mini.icons"] = nil
    package.loaded["mini.icons"] = nil
    pcall(function()
      require("pjollrig.ui.icons")._reset()
    end)
    teardown_env()
  end)

  local function hl(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
  end

  ---Stub a complete colorscheme surface (fields overridable per test)
  ---and recompute the palette from it.
  local function stub_colorscheme(over)
    local colors = vim.tbl_extend("force", {
      normal = { fg = 0xCDD6F4, bg = 0x1E1E2E },
      float_border = { fg = 0x6C7086 },
      comment = { fg = 0x9399B2 },
      sign_info = { fg = 0x89B4FA },
      special = { fg = 0xF5C2E7 },
      ts_string = { fg = 0x94E2D5 },
      identifier = { fg = 0xB4BEFE },
    }, over or {})
    vim.api.nvim_set_hl(0, "Normal", colors.normal)
    vim.api.nvim_set_hl(0, "NormalFloat", {})
    vim.api.nvim_set_hl(0, "FloatBorder", colors.float_border)
    vim.api.nvim_set_hl(0, "Comment", colors.comment)
    vim.api.nvim_set_hl(0, "DiagnosticSignInfo", colors.sign_info)
    vim.api.nvim_set_hl(0, "Special", colors.special)
    vim.api.nvim_set_hl(0, "@string", colors.ts_string)
    vim.api.nvim_set_hl(0, "Identifier", colors.identifier)
    require("pjollrig.ui.render").refresh_highlights()
    return colors
  end

  it("blend mixes per channel: t=0 keeps a, t=1 yields b, 0.5 the midpoint", function()
    local blend = require("pjollrig.ui.color").blend
    assert.are.equal(0x000000, blend(0x000000, 0xFFFFFF, 0.0))
    assert.are.equal(0xFFFFFF, blend(0x000000, 0xFFFFFF, 1.0))
    assert.are.equal(0x808080, blend(0x000000, 0xFFFFFF, 0.5))
    -- Channels mix independently — no cross-channel bleed.
    assert.are.equal(0x800080, blend(0xFF0000, 0x0000FF, 0.5))
    assert.are.equal(0x123456, blend(0x123456, 0x654321, 0.0))
    assert.are.equal(0x654321, blend(0x123456, 0x654321, 1.0))
    -- Rounded, not truncated: 0x10 half-way to 0x11 is 16.5 → 17.
    assert.are.equal(0x111111, blend(0x101010, 0x111111, 0.5))
  end)

  it("derives every card group from the stubbed colorscheme", function()
    local blend = require("pjollrig.ui.color").blend
    stub_colorscheme()
    local surface = blend(0x1E1E2E, 0xCDD6F4, 0.06)

    local card = hl("PjollrigCardBg")
    assert.are.equal(surface, card.bg)
    assert.is_nil(card.fg)

    local border = hl("PjollrigCommentBorder")
    assert.are.equal(blend(0x6C7086, 0x1E1E2E, 0.45), border.fg)
    assert.are.equal(surface, border.bg)

    local bar = hl("PjollrigCommentQuoteBar")
    assert.are.equal(0x89B4FA, bar.fg)
    assert.are.equal(surface, bar.bg)

    local quote = hl("PjollrigCommentQuote")
    assert.are.equal(0x9399B2, quote.fg)
    assert.is_true(quote.italic)
    assert.are.equal(surface, quote.bg)

    local author = hl("PjollrigCommentAuthor")
    assert.are.equal(0xCDD6F4, author.fg)
    assert.is_true(author.bold)
    assert.are.equal(surface, author.bg)

    local meta = hl("PjollrigCommentMeta")
    assert.are.equal(0x9399B2, meta.fg)
    assert.are.equal(surface, meta.bg)

    local github = hl("PjollrigBadgeGithub")
    assert.are.equal(0xF5C2E7, github.fg)
    assert.are.equal(surface, github.bg)

    -- @string wins the local badge's teal chain.
    local local_badge = hl("PjollrigBadgeLocal")
    assert.are.equal(0x94E2D5, local_badge.fg)
    assert.are.equal(surface, local_badge.bg)

    -- Eol badge variants: same fg, no card bg — the collapsed marker
    -- sits on the editor line, not on a card.
    assert.are.equal(0xF5C2E7, hl("PjollrigBadgeGithubEol").fg)
    assert.is_nil(hl("PjollrigBadgeGithubEol").bg)
    assert.are.equal(0x94E2D5, hl("PjollrigBadgeLocalEol").fg)
    assert.is_nil(hl("PjollrigBadgeLocalEol").bg)

    -- The hint is the quietest row: default-linked to the receded border.
    local hint = vim.api.nvim_get_hl(0, { name = "PjollrigCommentHint", link = true })
    assert.are.equal("PjollrigCommentBorder", hint.link)
  end)

  it("falls back through Identifier then DiagnosticSignInfo for the local badge", function()
    stub_colorscheme({ ts_string = {} })
    assert.are.equal(0xB4BEFE, hl("PjollrigBadgeLocal").fg)
    stub_colorscheme({ ts_string = {}, identifier = {} })
    assert.are.equal(0x89B4FA, hl("PjollrigBadgeLocal").fg)
  end)

  it("skips the surface tint on a transparent theme, keeping every fg", function()
    stub_colorscheme({ normal = { fg = 0xCDD6F4 } })
    for _, name in ipairs({
      "PjollrigCardBg",
      "PjollrigCommentBorder",
      "PjollrigCommentMeta",
      "PjollrigCommentQuote",
      "PjollrigCommentQuoteBar",
      "PjollrigCommentAuthor",
      "PjollrigBadgeGithub",
      "PjollrigBadgeLocal",
    }) do
      assert.is_nil(hl(name).bg)
    end
    -- The border has no bg to recede toward: plain border fg.
    assert.are.equal(0x6C7086, hl("PjollrigCommentBorder").fg)
    -- Every other fg still applies.
    assert.are.equal(0x89B4FA, hl("PjollrigCommentQuoteBar").fg)
    assert.are.equal(0xCDD6F4, hl("PjollrigCommentAuthor").fg)
    assert.is_true(hl("PjollrigCommentAuthor").bold)

    -- And rendering still works: a card comes up without erroring.
    require("pjollrig").add({
      body = "transparent card",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("transparent card", 1))
  end)

  it("recomputes the palette when ColorScheme fires", function()
    local blend = require("pjollrig.ui.color").blend
    stub_colorscheme()
    assert.are.equal(0x89B4FA, hl("PjollrigCommentQuoteBar").fg)

    -- Change the source colors WITHOUT calling refresh directly — the
    -- setup() ColorScheme autocmd must recompute the groups.
    vim.api.nvim_set_hl(0, "DiagnosticSignInfo", { fg = 0x00FF00 })
    vim.api.nvim_set_hl(0, "Normal", { fg = 0x111111, bg = 0xEEEEEE })
    vim.api.nvim_exec_autocmds("ColorScheme", {})

    assert.are.equal(0x00FF00, hl("PjollrigCommentQuoteBar").fg)
    assert.are.equal(blend(0xEEEEEE, 0x111111, 0.06), hl("PjollrigCardBg").bg)
    assert.are.equal(0x111111, hl("PjollrigCommentAuthor").fg)
  end)

  it("splits the popup card into quote-bar, badge, author, and meta hl regions", function()
    require("pjollrig.config").get().ui.icons = false
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    local record = {
      id = "palette-gh-1",
      uri = require("pjollrig.uri").for_bufnr(bufnr),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "palette body",
      author = "octocat",
      created_at = os.time(),
      updated_at = os.time(),
      resolved = false,
      meta = { github = { id = 7, imported = true } },
    }
    render.reconcile(bufnr, { record }, { record })
    render.update_viewport_popups(bufnr, { record }, { record })
    assert.is_true(wait_for_popup_count("palette body", 1))

    local winid = floating_windows_containing("palette body")[1]
    local popup_buf = vim.api.nvim_win_get_buf(winid)
    local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
    assert.are.equal('▍ "local value = 1"', lines[1])
    assert.are.equal("[gh] octocat · just now", lines[2])

    -- Collect the card marks: regions[row][group] = { start_col, end_col }.
    local marks = vim.api.nvim_buf_get_extmarks(popup_buf, -1, 0, -1, { details = true })
    local regions = {}
    for _, mark in ipairs(marks) do
      local row, col, details = mark[2], mark[3], mark[4] or {}
      if details.hl_group then
        regions[row] = regions[row] or {}
        regions[row][details.hl_group] = { col, details.end_col }
      end
    end

    -- Quote row: the `▍ ` bar and the quote text are separate regions.
    assert.are.same({ 0, #"▍ " }, regions[0]["PjollrigCommentQuoteBar"])
    assert.are.same({ #"▍ ", #lines[1] }, regions[0]["PjollrigCommentQuote"])

    -- Author row: badge → bold author name → dim time tail, adjacent.
    assert.are.same({ 0, #"[gh] " }, regions[1]["PjollrigBadgeGithub"])
    assert.are.same({ #"[gh] ", #"[gh] octocat" }, regions[1]["PjollrigCommentAuthor"])
    assert.are.same({ #"[gh] octocat", #lines[2] }, regions[1]["PjollrigCommentMeta"])

    -- Body rows carry no card mark: the popup window's card surface
    -- (winhighlight NormalFloat → PjollrigCardBg) paints them.
    assert.is_nil(regions[3])
  end)

  it("maps the local badge chunk in glyph mode", function()
    package.preload["mini.icons"] = function()
      return {
        get = function()
          return "X", "MiniIconsAzure", false
        end,
      }
    end
    require("pjollrig.config").get().ui.icons = "auto"
    require("pjollrig.ui.icons")._reset()

    require("pjollrig").add({
      body = "glyph local palette",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("glyph local palette", 1))

    local winid = floating_windows_containing("glyph local palette")[1]
    local popup_buf = vim.api.nvim_win_get_buf(winid)
    local found
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(popup_buf, -1, 0, -1, { details = true })) do
      local details = mark[4] or {}
      if details.hl_group == "PjollrigBadgeLocal" then
        found = mark
      end
    end
    assert.is_truthy(found)
    -- The badge leads the author line.
    assert.are.equal(0, found[3])
  end)
end)
