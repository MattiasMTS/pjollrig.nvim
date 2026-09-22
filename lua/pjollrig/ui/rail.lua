-- pjollrig.nvim: comments rail — the "eol" display mode's cursor
-- expansion rendered into a real side window (`ui.eol_expand = "rail"`).
--
-- The float expansion opens popups that hover over the buffer (with
-- occlusion-aware placement to dodge code); the rail is a real
-- top-level split on the far right, so covering code is structurally
-- impossible. `ui/render.lua`'s viewport pass dispatches here instead
-- of the float path when the live display mode is "eol" and
-- `config.get().ui.eol_expand == "rail"`; the "float"/"inline"/"hidden"
-- display modes never touch this module.
--
-- Lifecycle:
--   * open  — first cursor-enter onto a commented line (`M.render`).
--             Created via `nvim_open_win(split = "right", win = -1)`
--             (the `:vertical botright split` shape) with
--             `enter = false`, so focus stays in the code window.
--   * reuse — subsequent renders reuse the window + scratch buffer;
--             moving to a different commented line re-renders in place.
--   * clear — cursor on an uncommented line empties the cards but keeps
--             the window (`M.clear_for` — calm, no layout flicker).
--   * close — the display mode leaves "eol" (render calls `M.close`),
--             the attached buffer's records disappear (`M.close_for`
--             from the dispatch), the attached code window closes or
--             stops showing the buffer, the buffer unloads/wipes (the
--             lifecycle augroup below), or `M.close()` is called
--             directly. Idempotent; the dedicated augroup is torn down
--             with the window, so no autocmd outlives the rail.
--
-- Buffer lifecycle: scratch (`nofile`), `bufhidden = wipe`. The rail
-- buffer is pure derived render state, rebuilt from records whenever
-- their state changes (a same-state guard in `M.render` skips the
-- rebuild for no-op cursor events), so wiping on close is free and
-- guarantees no stale
-- `pjollrig://rail` buffers accumulate across open/close cycles —
-- matching `float.create_scratch_buf`'s choice for popup buffers.
--
-- Card content is NOT built here: `render.rail_card_rows` returns the
-- same bordered `[text, hl]` chunk rows the inline virt_lines box
-- renders (shared `build_popup_content` card, wrap = true, inline
-- border chars, kind→highlight mapping), and this module only
-- materializes those chunks into buffer lines + ranged highlight
-- extmarks. The card layout is defined exactly once, in render.lua.

local M = {}

-- Buffer name + filetype so tests (and user autocmds/statusline
-- integrations) can identify the rail window.
local RAIL_BUFNAME = "pjollrig://rail"
local RAIL_FILETYPE = "pjollrig-rail"

-- Namespace for the card highlight extmarks inside the rail buffer.
local ns = vim.api.nvim_create_namespace("pjollrig.rail")

---@class pjollrig.ui.rail.State
---@field winid integer Rail window
---@field bufnr integer Rail scratch buffer
---@field augroup integer? Lifecycle augroup (torn down on close)
---@field source_win integer? Code window the rail is attached to
---@field source_buf integer? Code buffer whose records the rail renders
---@field cleared boolean True while the rail buffer is known empty
---@field last_render { key: string, padding: integer, stack_height: integer }? Same-state guard for `M.render`

---@type pjollrig.ui.rail.State?
local state = nil

---Rail width: 30% of the screen, clamped to [30, 46] cells — wide
---enough for a readable card, never more than a third of the display.
---@return integer
local function rail_width()
  return math.min(46, math.max(30, math.floor(vim.o.columns * 0.3)))
end

---Close the rail window and tear down all module state, including the
---lifecycle augroup. Idempotent — safe when the rail never opened,
---already closed, or when called (deferred) from the rail's own
---WinClosed autocmd (the window is invalid by then, so only the
---state/augroup cleanup runs).
function M.close()
  local closing = state
  state = nil
  if not closing then
    return
  end
  if closing.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, closing.augroup)
  end
  if closing.winid and vim.api.nvim_win_is_valid(closing.winid) then
    pcall(vim.api.nvim_win_close, closing.winid, true)
  end
  -- `bufhidden = wipe` wipes the buffer with its window; a buffer that
  -- never reached a window (open failure) still needs explicit deletion.
  if closing.bufnr and vim.api.nvim_buf_is_valid(closing.bufnr) then
    pcall(vim.api.nvim_buf_delete, closing.bufnr, { force = true })
  end
end

---Close the rail iff it is attached to `bufnr` — used by the render
---dispatch when the buffer's records disappeared or it lost its
---window. A rail owned by another buffer is left alone (background
---repaints sweep every loaded buffer).
---@param bufnr integer
function M.close_for(bufnr)
  if state and state.source_buf == bufnr then
    M.close()
  end
end

---Clear the rendered cards iff the rail is open and attached to
---`bufnr`, keeping the window itself: the cursor moved to an
---uncommented line, and clearing without closing avoids layout
---flicker. Never opens the rail.
---@param bufnr integer
function M.clear_for(bufnr)
  if not state or state.source_buf ~= bufnr then
    return
  end
  -- Already empty: every cursor move across uncommented lines dispatches
  -- another clear — rewriting an empty buffer each time is pure churn.
  if state.cleared then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
  vim.bo[state.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  state.cleared = true
  state.last_render = nil
end

---Deferred attachment check shared by every lifecycle autocmd: close
---the rail when its own window is gone or the attached code window no
---longer shows the attached buffer. Validating live state (instead of
---closing unconditionally) keeps a re-attached rail alive when the
---trigger raced a source change.
local function validate_attachment()
  if not state then
    return
  end
  local rail_ok = state.winid and vim.api.nvim_win_is_valid(state.winid)
  local source_ok = state.source_win
    and vim.api.nvim_win_is_valid(state.source_win)
    and state.source_buf
    and vim.api.nvim_buf_is_valid(state.source_buf)
    and vim.api.nvim_win_get_buf(state.source_win) == state.source_buf
  if not rail_ok or not source_ok then
    M.close()
  end
end

---(Re)arm the lifecycle augroup for the current attachment. Every
---trigger defers into `validate_attachment` (the closing window is
---still in the layout inside a WinClosed callback): the rail's own
---window closing, the attached code window closing, the attached
---buffer leaving its window, and the attached buffer unloading/wiping.
---One dedicated augroup, cleared on every re-arm and deleted on close.
local function arm_lifecycle_autocmds()
  if not state then
    return
  end
  local group = vim.api.nvim_create_augroup("PjollrigRail", { clear = true })
  state.augroup = group

  local function deferred_validate()
    vim.schedule(validate_attachment)
  end

  local patterns = { tostring(state.winid) }
  if state.source_win then
    table.insert(patterns, tostring(state.source_win))
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = patterns,
    callback = deferred_validate,
  })
  if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout", "BufWinLeave" }, {
      group = group,
      buffer = state.source_buf,
      callback = deferred_validate,
    })
  end
end

---Ensure the rail window + scratch buffer exist and are attached to
---`source_win`/`source_buf`, re-arming the lifecycle augroup when the
---attachment changes. Never steals focus (`enter = false`). Returns
---false when the window could not be created.
---@param source_win integer
---@param source_buf integer
---@return boolean
local function ensure_open(source_win, source_buf)
  if state and (not vim.api.nvim_win_is_valid(state.winid) or not vim.api.nvim_buf_is_valid(state.bufnr)) then
    M.close()
  end
  if not state then
    -- A stale buffer holding the rail's name (e.g. left from an aborted
    -- open) would make `nvim_buf_set_name` fail with E95 — drop it.
    local stale = vim.fn.bufnr(RAIL_BUFNAME)
    if stale ~= -1 then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    pcall(vim.api.nvim_buf_set_name, bufnr, RAIL_BUFNAME)
    vim.bo[bufnr].filetype = RAIL_FILETYPE

    -- `split = "right"` + `win = -1` opens a full-height top-level
    -- split on the far right — the `:vertical botright split` shape —
    -- so the rail sits right of a review diffsplit pair too.
    local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
      split = "right",
      win = -1,
      width = rail_width(),
    })
    if not ok or not winid or not vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      return false
    end

    -- Chrome-free, fixed-width card column (mirrors
    -- `float.set_float_win_options` for popup windows): the rail is a
    -- read-only render surface, not an editing window.
    vim.wo[winid].winfixwidth = true
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].cursorline = false
    vim.wo[winid].wrap = false
    vim.wo[winid].list = false
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].spell = false

    -- A fresh scratch buffer is empty, so it starts "cleared".
    state = { winid = winid, bufnr = bufnr, cleared = true }
  end
  if state.source_win ~= source_win or state.source_buf ~= source_buf then
    state.source_win = source_win
    state.source_buf = source_buf
    state.last_render = nil
    arm_lifecycle_autocmds()
  end
  return true
end

---Leading blank rows that put the first card's top border at the
---anchor line's screen row. `screenpos` gives the anchor's absolute
---1-based screen row in the code window (0 when scrolled off — no
---padding then); `nvim_win_get_position` gives the rail's 0-based top
---row, so its first text row is `pos + 1`. Clamped so a stack taller
---than the space below simply starts higher (down to the rail's top
---row) instead of spilling past the window bottom.
---@param source_win integer
---@param anchor_line integer 1-indexed buffer line the stack anchors to
---@param stack_height integer Total card rows to place
---@return integer
local function alignment_padding(source_win, anchor_line, stack_height)
  if not state or not vim.api.nvim_win_is_valid(state.winid) then
    return 0
  end
  local anchor_row = 0
  if source_win and vim.api.nvim_win_is_valid(source_win) then
    local pos = vim.fn.screenpos(source_win, anchor_line, 1)
    anchor_row = tonumber(pos and pos.row) or 0
  end
  if anchor_row <= 0 then
    return 0
  end
  local rail_top = vim.api.nvim_win_get_position(state.winid)[1] + 1
  local rail_height = vim.api.nvim_win_get_height(state.winid)
  local padding = anchor_row - rail_top
  return math.max(0, math.min(padding, math.max(0, rail_height - stack_height)))
end

---Render a card stack into the rail, opening (or reusing) the window.
---Each entry's card is built by `render.rail_card_rows` — the SAME
---`build_popup_content` card the float popup and the inline box render,
---word-wrapped and boxed with the inline border chars — and the
---resulting `[text, hl]` chunk rows are materialized here into buffer
---lines plus ranged highlight extmarks. Cards stack in the order given;
---the stack is vertically aligned so the first card's top row sits at
---~the anchor line's screen row (clamped to fit).
---@param opts { bufnr: integer, winid: integer, anchor_line: integer, entries: { record: table, index: integer, total: integer }[] }
function M.render(opts)
  opts = opts or {}
  if not opts.bufnr or not opts.winid then
    return
  end
  if not ensure_open(opts.winid, opts.bufnr) then
    return
  end
  local width = vim.api.nvim_win_get_width(state.winid)
  local anchor_line = opts.anchor_line or 1

  -- Same-state guard: without it every cursor event (column-only moves,
  -- each insert-mode keystroke) rebuilds the cards, rewrites the whole
  -- buffer, and re-adds every extmark. The key covers everything that
  -- changes the rendered bytes — the covering records (id, updated_at,
  -- resolved, body — body directly because `os.time()` seconds make
  -- same-second edits invisible to updated_at), the title counters, the
  -- anchor line, and the rail width. Padding is re-probed each event
  -- (one cheap `screenpos`) so scrolls and layout shifts still
  -- re-align. Deliberately NOT keyed: the relative timestamp ("just
  -- now") and the quoted code line — both refresh on the next state
  -- change, and rebuilding per keystroke to chase them is the exact
  -- churn being removed.
  local key_parts = { tostring(anchor_line), tostring(width) }
  for _, entry in ipairs(opts.entries or {}) do
    local record = entry.record or {}
    key_parts[#key_parts + 1] = table.concat({
      tostring(record.id or ""),
      tostring(record.updated_at or ""),
      record.resolved and "1" or "0",
      tostring(entry.index or 1),
      tostring(entry.total or 1),
      record.body or "",
    }, "\1")
  end
  local key = table.concat(key_parts, "\2")
  local last = state.last_render
  if last and last.key == key and alignment_padding(opts.winid, anchor_line, last.stack_height) == last.padding then
    return
  end

  local render = require("pjollrig.ui.render")

  -- Flatten the stack into one list of chunk rows (each row is one
  -- rendered line as `[text, hl]` chunks, straight from the inline box
  -- renderer).
  local rows = {}
  for _, entry in ipairs(opts.entries or {}) do
    local card = render.rail_card_rows(entry.record, width, entry.index or 1, entry.total or 1, opts.bufnr)
    for _, row in ipairs(card) do
      table.insert(rows, row)
    end
  end

  local padding = alignment_padding(opts.winid, anchor_line, #rows)
  local lines = {}
  for _ = 1, padding do
    table.insert(lines, "")
  end
  ---@type { row: integer, start_col: integer, end_col: integer, hl: string }[]
  local spans = {}
  for _, chunks in ipairs(rows) do
    local parts = {}
    local byte = 0
    local row = #lines -- 0-based row of the line being assembled
    for _, chunk in ipairs(chunks) do
      local text = chunk[1] or ""
      table.insert(parts, text)
      if chunk[2] and #text > 0 then
        table.insert(spans, { row = row, start_col = byte, end_col = byte + #text, hl = chunk[2] })
      end
      byte = byte + #text
    end
    table.insert(lines, table.concat(parts))
  end

  local bufnr = state.bufnr
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, span in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, span.row, span.start_col, {
      end_col = span.end_col,
      hl_group = span.hl,
    })
  end
  state.cleared = false
  state.last_render = { key = key, padding = padding, stack_height = #rows }
end

---True when the rail window is open.
---@return boolean
function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

---The rail window id, or nil when closed. For tests/introspection.
---@return integer?
function M.winid()
  return state and state.winid or nil
end

return M
