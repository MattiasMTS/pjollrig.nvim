local H = require("helpers")

local ctx

local function setup_env(opts)
  ctx = H.setup(vim.tbl_deep_extend("force", { ui = { eol_expand = "rail" } }, opts or {}))
  H.edit_project_file(ctx, "src/rail.lua", {
    "local value = 1",
    "value = value + 1",
    "local sum = value + 2",
    "local more = sum + 3",
    "return more",
  })
end

local function teardown_env()
  -- Drain scheduled callbacks queued by the test (editor close/focus
  -- restore, viewport refreshes) while its windows still exist, so
  -- nothing leaks into the next test's event loop.
  vim.wait(30, function()
    return false
  end, 10)
  pcall(function()
    require("pjollrig.ui.rail").close()
  end)
  pcall(function()
    require("pjollrig.review").stop()
  end)
  H.teardown(ctx)
  ctx = nil
end

---The rail window in the current tab, identified by its dedicated
---filetype. Nil when no rail is open.
local function find_rail_win()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "pjollrig-rail" then
        return winid
      end
    end
  end
  return nil
end

---Pump the event loop until the rail window appears (the CursorMoved →
---viewport refresh that opens it is scheduled).
local function wait_for_rail()
  vim.wait(1000, function()
    return find_rail_win() ~= nil
  end, 10)
  return find_rail_win()
end

local function rail_lines(rail_win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(rail_win), 0, -1, false)
end

---Highlight groups applied per rail-buffer row (any namespace):
---`{ [row0] = { [hl_group] = true } }`.
local function rail_hl_rows(rail_win)
  local bufnr = vim.api.nvim_win_get_buf(rail_win)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
  local by_row = {}
  for _, mark in ipairs(marks) do
    local row, details = mark[2], mark[4] or {}
    if details.hl_group then
      by_row[row] = by_row[row] or {}
      by_row[row][tostring(details.hl_group)] = true
    end
  end
  return by_row
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

---Move the cursor and deliver the CursorMoved event the plugin's
---viewport autocmd listens for (same contract as display_spec).
local function move_cursor(bufnr, line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
end

---Count leading blank lines (the rail's alignment padding).
local function leading_blanks(lines)
  local count = 0
  for _, line in ipairs(lines) do
    if line ~= "" then
      break
    end
    count = count + 1
  end
  return count
end

describe("pjollrig rail expansion", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("opens the rail on cursor-enter without stealing focus", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "rail note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    -- Off the commented line: no rail yet (it only opens on cursor-enter).
    assert.is_nil(find_rail_win())

    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    -- Focus stays in the code window.
    assert.are.equal(code_win, vim.api.nvim_get_current_win())

    -- Real window (not a float), identifiable buffer.
    local cfg = vim.api.nvim_win_get_config(rail_win)
    assert.is_true(cfg.relative == nil or cfg.relative == "")
    local rail_buf = vim.api.nvim_win_get_buf(rail_win)
    assert.are.equal("pjollrig-rail", vim.bo[rail_buf].filetype)
    assert.is_truthy(vim.api.nvim_buf_get_name(rail_buf):find("pjollrig://rail", 1, true))

    -- Scratch buffer, not modifiable; chrome-free fixed-width window.
    assert.are.equal("nofile", vim.bo[rail_buf].buftype)
    assert.is_false(vim.bo[rail_buf].modifiable)
    assert.is_true(vim.wo[rail_win].winfixwidth)
    assert.is_false(vim.wo[rail_win].number)
    assert.is_false(vim.wo[rail_win].relativenumber)
    assert.are.equal("no", vim.wo[rail_win].signcolumn)
    assert.is_false(vim.wo[rail_win].cursorline)

    -- Width formula: min(46, max(30, floor(columns * 0.3))).
    local expected_width = math.min(46, math.max(30, math.floor(vim.o.columns * 0.3)))
    assert.are.equal(expected_width, vim.api.nvim_win_get_width(rail_win))

    -- No float popup expands in rail mode.
    assert.are.equal(0, #floating_windows_containing("rail note"))

    -- The collapsed eol marker still renders (rail replaces only the
    -- expansion, not the marker).
    local ns = require("pjollrig.anchor").ns
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { 0, 0 }, { 0, -1 }, { details = true })
    local has_eol = false
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if details.virt_text and details.virt_text_pos == "eol" then
        has_eol = true
      end
    end
    assert.is_true(has_eol)
  end)

  it("renders the shared card stack with highlight extmarks", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "rail body first\nrail body second",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()
    local short = tostring(records[1].id):sub(1, 6)

    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    local lines = rail_lines(rail_win)
    local joined = table.concat(lines, "\n")

    -- Card order: title border → quote → author → blank → body → hint →
    -- bottom border (the same build_popup_content card the float popup
    -- and inline box render).
    local title_at = joined:find("c" .. short .. " 1/1", 1, true)
    local quote_at = joined:find('▍ "local value = 1"', 1, true)
    local author_at = joined:find("· just now", 1, true)
    local body_at = joined:find("rail body first", 1, true)
    local body2_at = joined:find("rail body second", 1, true)
    local hint_at = joined:find("edit gca | delete gcd", 1, true)
    assert.is_truthy(title_at)
    assert.is_truthy(quote_at)
    assert.is_truthy(author_at)
    assert.is_truthy(body_at)
    assert.is_truthy(body2_at)
    assert.is_truthy(hint_at)
    assert.is_true(title_at < quote_at)
    assert.is_true(quote_at < author_at)
    assert.is_true(author_at < body_at)
    assert.is_true(body_at < body2_at)
    assert.is_true(body2_at < hint_at)
    -- Boxed with the inline border chars.
    assert.is_truthy(joined:find("┌", 1, true))
    assert.is_truthy(joined:find("└", 1, true))
    assert.is_truthy(joined:find("│", 1, true))

    -- Card highlights land as extmarks on the right rows — including
    -- the per-chunk split: the quote row carries BOTH the accent bar
    -- group and the dim quote-text group, the author row both the bold
    -- author group and the dim time-tail group, and the hint row the
    -- quietest border-gray hint group (the same mapping the inline box
    -- uses — the rail materializes append_inline_box's chunks).
    local hl = rail_hl_rows(rail_win)
    local function row_of(needle)
      for index, line in ipairs(lines) do
        if line:find(needle, 1, true) then
          return index - 1
        end
      end
      return nil
    end
    assert.is_truthy(hl[row_of('▍ "local value = 1"')]["PjollrigCommentQuoteBar"])
    assert.is_truthy(hl[row_of('▍ "local value = 1"')]["PjollrigInlineQuote"])
    assert.is_truthy(hl[row_of("· just now")]["PjollrigCommentAuthor"])
    assert.is_truthy(hl[row_of("· just now")]["PjollrigInlineMeta"])
    assert.is_truthy(hl[row_of("rail body first")]["PjollrigInlineBody"])
    assert.is_truthy(hl[row_of("edit gca | delete gcd")]["PjollrigCommentHint"])
    assert.is_truthy(hl[row_of("┌")]["PjollrigInlineBorder"])
  end)

  it("aligns the first card to the anchor line's screen row", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 1)
    require("pjollrig").add({
      body = "align me",
      range = { start = { 3, 0 }, end_ = { 3, 0 } },
    })

    move_cursor(bufnr, 4)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    -- The first card's top row sits at ~the anchor line's screen row:
    -- padding = anchor's absolute screen row - the rail's first text row.
    local anchor_row = vim.fn.screenpos(code_win, 4, 1).row
    local rail_top = vim.api.nvim_win_get_position(rail_win)[1] + 1
    local expected = math.max(0, anchor_row - rail_top)
    local blanks = leading_blanks(rail_lines(rail_win))
    assert.is_true(
      math.abs(blanks - expected) <= 1,
      ("padding %d not within 1 of expected %d"):format(blanks, expected)
    )
  end)

  it("stacks two same-line records as two boxes in order", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "stack alpha",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    require("pjollrig").add({
      body = "stack beta",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    move_cursor(bufnr, 2)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    local joined = table.concat(rail_lines(rail_win), "\n")
    local alpha_at = joined:find("stack alpha", 1, true)
    local beta_at = joined:find("stack beta", 1, true)
    assert.is_truthy(alpha_at)
    assert.is_truthy(beta_at)
    assert.is_true(alpha_at < beta_at)
    -- Two boxes: two top borders, two bottom borders.
    local _, tops = joined:gsub("┌", "")
    local _, bottoms = joined:gsub("└", "")
    assert.are.equal(2, tops)
    assert.are.equal(2, bottoms)
    -- No float popups for the stack either.
    assert.are.equal(0, #floating_windows_containing("stack alpha"))
  end)

  it("re-renders when moving between commented lines", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "first note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "fourth note",
      range = { start = { 3, 0 }, end_ = { 3, 0 } },
    })

    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)
    assert.is_true(vim.wait(1000, function()
      return table.concat(rail_lines(rail_win), "\n"):find("first note", 1, true) ~= nil
    end, 10))

    move_cursor(bufnr, 4)
    assert.is_true(vim.wait(1000, function()
      local joined = table.concat(rail_lines(rail_win), "\n")
      return joined:find("fourth note", 1, true) ~= nil and joined:find("first note", 1, true) == nil
    end, 10))
    -- Same window reused — no second rail, no flicker-close.
    assert.are.equal(rail_win, find_rail_win())
  end)

  it("clears the cards on an uncommented line but keeps the rail open", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "calm note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    move_cursor(bufnr, 5)
    assert.is_true(vim.wait(1000, function()
      local lines = rail_lines(rail_win)
      return #lines == 1 and lines[1] == ""
    end, 10))
    -- The window itself stays open (calm — no layout flicker).
    assert.is_true(vim.api.nvim_win_is_valid(rail_win))
    assert.are.equal(rail_win, find_rail_win())

    -- Back onto the commented line: the same window re-renders.
    move_cursor(bufnr, 1)
    assert.is_true(vim.wait(1000, function()
      return table.concat(rail_lines(rail_win), "\n"):find("calm note", 1, true) ~= nil
    end, 10))
  end)

  it("skips the buffer rebuild when nothing changed", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "steady note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)
    assert.is_true(vim.wait(1000, function()
      return table.concat(rail_lines(rail_win), "\n"):find("steady note", 1, true) ~= nil
    end, 10))

    -- Drain any renders still queued from the moves above.
    vim.wait(50, function()
      return false
    end, 10)
    local rail_buf = vim.api.nvim_win_get_buf(rail_win)
    local tick = vim.api.nvim_buf_get_changedtick(rail_buf)

    -- Same-line and column-only cursor movement re-fires the dispatch
    -- with identical state: the rail must not rewrite its buffer.
    move_cursor(bufnr, 1)
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
    move_cursor(bufnr, 1)
    vim.wait(100, function()
      return false
    end, 10)
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(rail_buf))
  end)

  it("re-renders when a covering record's content changes", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "original body",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)
    vim.wait(50, function()
      return false
    end, 10)

    -- Drive the render seam directly (the same call render.lua's
    -- dispatch makes) so the guard is exercised deterministically.
    local rail = require("pjollrig.ui.rail")
    local record = require("pjollrig").list()[1]
    local opts = {
      bufnr = bufnr,
      winid = code_win,
      anchor_line = 1,
      entries = { { record = record, index = 1, total = 1 } },
    }
    rail.render(opts)
    local rail_buf = vim.api.nvim_win_get_buf(rail_win)
    local tick = vim.api.nvim_buf_get_changedtick(rail_buf)
    rail.render(opts)
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(rail_buf))

    -- A body edit must re-render even when `updated_at` did not move
    -- (os.time() has 1-second granularity — an edit right after the
    -- last render lands in the same second).
    record.body = "edited body"
    rail.render(opts)
    assert.is_true(vim.api.nvim_buf_get_changedtick(rail_buf) > tick)
    assert.is_truthy(table.concat(rail_lines(rail_win), "\n"):find("edited body", 1, true))
  end)

  it("re-renders when the rail width changes", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "resize note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)
    vim.wait(50, function()
      return false
    end, 10)

    local rail = require("pjollrig.ui.rail")
    local record = require("pjollrig").list()[1]
    local opts = {
      bufnr = bufnr,
      winid = code_win,
      anchor_line = 1,
      entries = { { record = record, index = 1, total = 1 } },
    }
    rail.render(opts)
    local rail_buf = vim.api.nvim_win_get_buf(rail_win)
    local tick = vim.api.nvim_buf_get_changedtick(rail_buf)

    vim.api.nvim_win_set_width(rail_win, vim.api.nvim_win_get_width(rail_win) - 5)
    rail.render(opts)
    assert.is_true(vim.api.nvim_buf_get_changedtick(rail_buf) > tick)
  end)

  it("realigns instead of skipping when the code window scrolls", function()
    local lines = {}
    for index = 1, 60 do
      lines[index] = ("local x%d = %d"):format(index, index)
    end
    H.edit_project_file(ctx, "src/tall.lua", lines)
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 30)
    require("pjollrig").add({
      body = "scroll note",
      range = { start = { 29, 0 }, end_ = { 29, 0 } },
    })
    move_cursor(bufnr, 30)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)
    assert.is_true(vim.wait(1000, function()
      return table.concat(rail_lines(rail_win), "\n"):find("scroll note", 1, true) ~= nil
    end, 10))
    local before = leading_blanks(rail_lines(rail_win))
    assert.is_true(before > 0)

    -- Scroll the anchor to the top of the code window: same records,
    -- same anchor line, but the alignment padding must shrink — the
    -- guard may not skip this render.
    vim.api.nvim_win_call(code_win, function()
      vim.cmd("normal! zt")
    end)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
    assert.is_true(vim.wait(1000, function()
      return leading_blanks(rail_lines(rail_win)) < before
    end, 10))
  end)

  it("repeated clears keep the rail buffer untouched", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "clear once",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    move_cursor(bufnr, 5)
    assert.is_true(vim.wait(1000, function()
      local lines = rail_lines(rail_win)
      return #lines == 1 and lines[1] == ""
    end, 10))
    vim.wait(50, function()
      return false
    end, 10)
    local rail_buf = vim.api.nvim_win_get_buf(rail_win)
    local tick = vim.api.nvim_buf_get_changedtick(rail_buf)

    -- Every further move across uncommented lines dispatches another
    -- clear: an already-empty rail must not be rewritten each time.
    move_cursor(bufnr, 4)
    move_cursor(bufnr, 5)
    move_cursor(bufnr, 4)
    vim.wait(100, function()
      return false
    end, 10)
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(rail_buf))
  end)

  it("closes the rail when the display mode leaves eol", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "mode switch note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    assert.is_truthy(wait_for_rail())

    require("pjollrig.ui.render").set_display_mode("float")
    assert.is_true(vim.wait(1000, function()
      return find_rail_win() == nil
    end, 10))
    assert.is_false(require("pjollrig.ui.rail").is_open())
  end)

  it("closes the rail when the buffer's records disappear", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "goes away",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    assert.is_truthy(wait_for_rail())

    local records = require("pjollrig").list()
    require("pjollrig").delete(records[1].id)
    assert.is_true(vim.wait(1000, function()
      return find_rail_win() == nil
    end, 10))
  end)

  it("closes the rail when the code window closes", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "window bound",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    assert.is_truthy(wait_for_rail())

    -- Split so the code window is not the last non-rail window, then
    -- close it: the rail must follow.
    vim.cmd("botright new")
    vim.api.nvim_win_close(code_win, true)
    assert.is_true(vim.wait(1000, function()
      return find_rail_win() == nil
    end, 10))
  end)

  it("close() is idempotent and leaves no autocmds", function()
    local rail = require("pjollrig.ui.rail")
    -- Closing a never-opened rail is a no-op.
    rail.close()
    rail.close()

    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "close me",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    assert.is_truthy(wait_for_rail())

    rail.close()
    assert.is_nil(find_rail_win())
    assert.is_false(rail.is_open())
    -- The dedicated augroup is torn down with the window.
    assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = "PjollrigRail" }))
    -- Second close: still a no-op.
    rail.close()
    assert.is_nil(find_rail_win())
  end)

  it("keeps the rail intact while the comment editor is up", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local code_win = vim.api.nvim_get_current_win()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "edit without closing",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    -- Open the comment editor: focus moves into a pjollrig float. The
    -- editor focus exception must leave the rail open with its card.
    local records = require("pjollrig").list()
    require("pjollrig").edit(records[1].id)
    assert.is_true(vim.wait(1000, function()
      return require("pjollrig.ui.editor").is_active()
    end, 10))

    vim.wait(50, function()
      return false
    end, 10)
    assert.is_true(vim.api.nvim_win_is_valid(rail_win))
    assert.is_truthy(table.concat(rail_lines(rail_win), "\n"):find("edit without closing", 1, true))

    require("pjollrig.ui.editor").close_active()
    -- Wait for the editor's SCHEDULED close/focus-restore to finish (it
    -- returns focus to the code window), not just the is_active flip —
    -- otherwise the queued restore leaks into the next test.
    assert.is_true(vim.wait(1000, function()
      return not require("pjollrig.ui.editor").is_active() and vim.api.nvim_get_current_win() == code_win
    end, 10))
    assert.is_true(vim.api.nvim_win_is_valid(rail_win))
  end)
end)

describe("pjollrig rail review coexistence", function()
  before_each(function()
    ctx = H.setup({ ui = { eol_expand = "rail" } })
  end)
  after_each(teardown_env)

  it("opens right of the review diff and leaves the panel intact", function()
    local left = ctx.artifact_root .. "/left/pair.lua"
    local right = ctx.root .. "/pair.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ "return 1 -- old", "-- filler", "return 9" }, left)
    vim.fn.writefile({ "return 1 -- new", "-- filler", "return 9" }, right)
    local R = require("pjollrig.review")
    assert.is_true(R.start({
      files = { { left = left, right = right, status = "M", path = "pair.lua" } },
      label = "rail",
    }))

    -- Comment on the commentable RIGHT (worktree) side: focus its
    -- window explicitly (review.start leaves focus on the first non-qf
    -- window of the tab).
    local right_buf = vim.fn.bufnr(right)
    assert.is_true(right_buf > 0)
    local code_win
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(winid) == right_buf then
        code_win = winid
        break
      end
    end
    assert.is_truthy(code_win)
    vim.api.nvim_set_current_win(code_win)
    local bufnr = right_buf
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "rail in review",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    move_cursor(bufnr, 1)
    local rail_win = wait_for_rail()
    assert.is_truthy(rail_win)

    -- botright: the rail is the rightmost window in the review tab.
    local rail_col = vim.api.nvim_win_get_position(rail_win)[2]
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= rail_win then
        assert.is_true(vim.api.nvim_win_get_position(winid)[2] < rail_col)
      end
    end

    -- The diffsplit pair and the review panel both survive.
    local diff_wins, panel_wins = 0, 0
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(winid)
      if vim.bo[buf].filetype == "pjollrig-panel" then
        panel_wins = panel_wins + 1
      elseif vim.wo[winid].diff then
        diff_wins = diff_wins + 1
      end
    end
    assert.are.equal(2, diff_wins)
    assert.are.equal(1, panel_wins)
    assert.is_truthy(table.concat(rail_lines(rail_win), "\n"):find("rail in review", 1, true))

    -- Stopping the review closes the session tab; the rail dies with
    -- its window and its state resets.
    R.stop()
    assert.is_true(vim.wait(1000, function()
      return find_rail_win() == nil and not require("pjollrig.ui.rail").is_open()
    end, 10))
  end)
end)

-- Regression pin: with ui.eol_expand = "float" (the shipped default) the eol
-- expansion behaves exactly as before the rail existed — float popups on
-- the cursor line, no rail window ever.
describe("pjollrig eol float expansion regression", function()
  before_each(function()
    setup_env({ ui = { eol_expand = "float" } })
  end)
  after_each(teardown_env)

  local function wait_for_popup_count(text, expected)
    return vim.wait(1000, function()
      return #floating_windows_containing(text) == expected
    end, 10)
  end

  it("keeps the float expansion byte-identical and never opens a rail", function()
    assert.are.equal("float", require("pjollrig.config").get().ui.eol_expand)
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "expand me now",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    assert.is_true(wait_for_popup_count("expand me now", 0))
    assert.is_nil(find_rail_win())

    -- Cursor onto the comment line: the full float-mode popup opens,
    -- exactly as in display_spec's expansion test.
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("expand me now", 1))
    assert.is_nil(find_rail_win())
    local winid = floating_windows_containing("expand me now")[1]
    local title = vim.api.nvim_win_get_config(winid).title
    if type(title) == "table" then
      local parts = {}
      for _, item in ipairs(title) do
        table.insert(parts, type(item) == "table" and item[1] or item)
      end
      title = table.concat(parts, "")
    end
    assert.is_truthy(tostring(title):find("1/1", 1, true))

    -- Cursor off the line: popup closes; still no rail.
    move_cursor(bufnr, 1)
    assert.is_true(wait_for_popup_count("expand me now", 0))
    assert.is_nil(find_rail_win())
  end)
end)
