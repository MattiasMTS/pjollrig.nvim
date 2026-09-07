-- pjollrig.nvim: inline (unified) diff rendering for review sessions.
--
-- Why not a synthetic `git diff` buffer
-- -------------------------------------
-- Every comment pjollrig stores is keyed by the *worktree* file URI and
-- carries a range in *worktree line coordinates* (see `adapter.identify`
-- and `sinks/helpers.line_span`). A classic unified-diff buffer is a
-- separate document whose line numbers do not match the file, so it
-- would need a diff↔file mapping at four seams (add, render, position
-- sync, jump) and one missed seam silently persists a comment against
-- the wrong line.
--
-- So unified mode paints the diff ONTO the real worktree buffer instead:
--
--   * lines the change ADDED get `line_hl_group = PjollrigDiffAdd`
--   * lines the change REMOVED are drawn as `virt_lines` (virtual text,
--     not buffer text) anchored where they used to sit
--   * unchanged regions fold away, leaving hunks + context on screen
--
-- The buffer is still the file. Comment anchoring, extmark drift,
-- `line_span`, GitHub's `side = "RIGHT"` — all of it keeps working with
-- zero translation. The one thing this view cannot do is put the cursor
-- on a removed line, so removed lines are not commentable; that matches
-- split mode, where the baseline side is `is_writable = false`.

local M = {}

---Namespace for inline diff decorations. Separate from `anchor.ns` so
---clearing the diff paint never touches comment anchors.
M.ns = vim.api.nvim_create_namespace("pjollrig_review_inline")

---@class pjollrig.review.InlineHunk
---@field old_start integer 1-indexed first baseline line removed (0 for a pure insert)
---@field old_count integer Baseline lines removed by this hunk
---@field new_start integer 1-indexed first worktree line added (anchor line for a pure delete)
---@field new_count integer Worktree lines added by this hunk
---@field removed string[] The baseline lines this hunk removed

---@class pjollrig.review.InlineState
---@field hunks pjollrig.review.InlineHunk[]
---@field keep table<integer, boolean> 1-indexed rows kept out of folds
---@field windows table<integer, table> Saved window options, keyed by winid

---@type table<integer, pjollrig.review.InlineState>
local state = {}

---Buffer-local BufWipeout autocmds that reap a buffer's state entry the
---moment the buffer dies mid-session; clear_all at session end used to
---be the only reaper, pinning dead buffers' hunk tables until then.
local wipe_group = vim.api.nvim_create_augroup("PjollrigReviewInlineWipe", { clear = true })

---Drop the fold-callback globals once nothing is painted anymore.
---'foldexpr' runs per line on every fold recompute, so it references an
---eagerly-resolved global (armed in fold_windows) instead of paying a
---v:lua require() round-trip per line; window options are restored by
---clear() before this runs, so no window still points at the globals.
local function maybe_clear_fold_globals()
  if next(state) == nil then
    _G.__pjollrig_inline_foldexpr = nil
    _G.__pjollrig_inline_foldtext = nil
  end
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

---Default-linked so a colorscheme (or the user) can override them, in
---the same spirit as `PjollrigLineNr` in the renderer. Applied on every
---`M.apply` (idempotent).
local function setup_highlights()
  vim.api.nvim_set_hl(0, "PjollrigDiffAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "PjollrigDiffDelete", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "PjollrigDiffDeleteSign", { link = "PjollrigDiffDelete", default = true })
  vim.api.nvim_set_hl(0, "PjollrigDiffFold", { link = "Folded", default = true })
  -- Intra-line emphasis on modified lines. DiffText is exactly vim's
  -- "changed text inside a changed line" group, so it layers correctly
  -- over both the DiffAdd-tinted worktree line and the DiffDelete-tinted
  -- removed virtual line in stock colorschemes.
  vim.api.nvim_set_hl(0, "PjollrigDiffWordAdded", { link = "DiffText", default = true })
  vim.api.nvim_set_hl(0, "PjollrigDiffWordRemoved", { link = "DiffText", default = true })
end

---Gutter glyph marking a removed line. A literal `-` (git's marker)
---collides with the content whenever the removed line itself starts with
---one — `-- comment` renders as `--- comment` — so use a one-column bar
---instead. One column keeps removed text aligned with the code above it.
local REMOVED_SIGN = "▏"

-- ---------------------------------------------------------------------------
-- Diff computation
-- ---------------------------------------------------------------------------

---@param path string
---@return string[]?, string? err
local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil, ("pjollrig: cannot read baseline %s"):format(path)
  end
  return lines
end

---`vim.diff` gained `linematch` (finer hunks for changed blocks) and the
---histogram algorithm at different times. Ask for the good options and
---fall back to the plain call on any Neovim that rejects them, rather
---than gating on a version number.
---@param a string
---@param b string
---@return integer[][]
local function diff_indices(a, b)
  local opts = { result_type = "indices", algorithm = "histogram", linematch = 60 }
  local ok, result = pcall(vim.diff, a, b, opts)
  if not ok or type(result) ~= "table" then
    ok, result = pcall(vim.diff, a, b, { result_type = "indices" })
  end
  if not ok or type(result) ~= "table" then
    return {}
  end
  return result
end

---Join buffer/file lines into diffable text.
---
---An empty file reads back from `readfile` as `{}` but loads into a
---buffer as `{""}`; both mean "no content". Collapsing them to the empty
---string is what makes an ADDED file (whose staged baseline is empty)
---diff as a clean all-add instead of also reporting a phantom removed
---blank line.
---@param lines string[]
---@return string
local function join_lines(lines)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

---Compute the hunks between a baseline and the current buffer contents.
---@param baseline string[] Baseline file lines
---@param current string[] Worktree buffer lines
---@return pjollrig.review.InlineHunk[]
function M.hunks(baseline, current)
  local a = join_lines(baseline)
  local b = join_lines(current)
  local hunks = {}
  for _, entry in ipairs(diff_indices(a, b)) do
    local old_start, old_count, new_start, new_count = entry[1], entry[2], entry[3], entry[4]
    local removed = {}
    for i = old_start, old_start + old_count - 1 do
      table.insert(removed, baseline[i] or "")
    end
    table.insert(hunks, {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      removed = removed,
    })
  end
  return hunks
end

---Perf guard: the trim below is O(line length) per modified line, which
---is nothing for code but pointless for minified/generated monsters —
---and a word span on a line that long is unreadable anyway. Skip those.
local WORD_DIFF_MAX_BYTES = 500

---The differing middle of a modified line pair, found by trimming the
---common prefix and suffix. That is the "simple" inline mode diff tools
---ship (git delta, vim's own `diffopt+=inline:simple`): a single scan,
---no allocation, and multi-edit lines degrade gracefully to one merged
---span instead of highlight confetti.
---
---Byte columns to match extmarks; a trim can split a multibyte char when
---two chars share lead bytes, which Neovim renders fine (highlights are
---per byte), so it is not worth a UTF-8 boundary walk.
---@param old string
---@param new string
---@return {old_start: integer, old_stop: integer, new_start: integer, new_stop: integer}? span 0-indexed, stop-exclusive
local function word_span(old, new)
  if old == new or #old > WORD_DIFF_MAX_BYTES or #new > WORD_DIFF_MAX_BYTES then
    return nil
  end
  local old_len, new_len = #old, #new
  local shorter = math.min(old_len, new_len)
  local prefix = 0
  while prefix < shorter and old:byte(prefix + 1) == new:byte(prefix + 1) do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < shorter - prefix and old:byte(old_len - suffix) == new:byte(new_len - suffix) do
    suffix = suffix + 1
  end
  return {
    old_start = prefix,
    old_stop = old_len - suffix,
    new_start = prefix,
    new_stop = new_len - suffix,
  }
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

---Where the removed lines of `hunk` belong, as (0-indexed row, above?).
---
---`vim.diff` reports a pure deletion as `new_count == 0` with
---`new_start` naming the worktree line the removal sits AFTER (0 when
---the file lost its first lines). A replacement reports the worktree
---lines that took the removed lines' place, so its baseline text goes
---directly above them.
---@param hunk pjollrig.review.InlineHunk
---@param line_count integer
---@return integer row, boolean above
local function removed_anchor(hunk, line_count)
  local last = math.max(0, line_count - 1)
  if hunk.new_count > 0 then
    return math.min(math.max(0, hunk.new_start - 1), last), true
  end
  if hunk.new_start < 1 then
    return 0, true
  end
  return math.min(hunk.new_start - 1, last), false
end

---@param bufnr integer
---@param hunks pjollrig.review.InlineHunk[]
---@param current string[] Worktree buffer lines, for intra-line spans
local function paint(bufnr, hunks, current)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  for _, hunk in ipairs(hunks) do
    -- Pair line k of the removed range with line k of its replacement
    -- while both exist; only these MODIFIED lines get word-level spans.
    -- Pure additions/deletions stay whole-line.
    local spans = {}
    for k = 1, math.min(hunk.old_count, hunk.new_count) do
      spans[k] = word_span(hunk.removed[k], current[hunk.new_start + k - 1] or "")
    end

    if hunk.new_count > 0 then
      local first = math.max(0, hunk.new_start - 1)
      local last = math.min(hunk.new_start + hunk.new_count - 2, line_count - 1)
      for row = first, last do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
          line_hl_group = "PjollrigDiffAdd",
          -- Below the comment anchors (priority 220) so a commented line
          -- still shows its pjollrig line-number tint.
          priority = 100,
        })
        local span = spans[row - hunk.new_start + 2]
        if span and span.new_stop > span.new_start then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, span.new_start, {
            end_col = span.new_stop,
            hl_group = "PjollrigDiffWordAdded",
            -- Above the line paint, still below the comment anchors.
            priority = 110,
          })
        end
      end
    end

    if #hunk.removed > 0 then
      local virt_lines = {}
      for i, text in ipairs(hunk.removed) do
        local chunks = { { REMOVED_SIGN, "PjollrigDiffDeleteSign" } }
        local span = spans[i]
        if span and span.old_stop > span.old_start then
          if span.old_start > 0 then
            table.insert(chunks, { text:sub(1, span.old_start), "PjollrigDiffDelete" })
          end
          table.insert(chunks, { text:sub(span.old_start + 1, span.old_stop), "PjollrigDiffWordRemoved" })
          if span.old_stop < #text then
            table.insert(chunks, { text:sub(span.old_stop + 1), "PjollrigDiffDelete" })
          end
        else
          table.insert(chunks, { text, "PjollrigDiffDelete" })
        end
        table.insert(virt_lines, chunks)
      end
      local row, above = removed_anchor(hunk, line_count)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
        virt_lines = virt_lines,
        virt_lines_above = above,
        priority = 100,
      })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Folding
-- ---------------------------------------------------------------------------

---Rows (1-indexed) that must stay outside a fold: every changed line
---plus `context` lines of surrounding code, and the anchor line of a
---pure deletion so its virtual lines are not hidden inside a fold.
---@param hunks pjollrig.review.InlineHunk[]
---@param line_count integer
---@param context integer
---@return table<integer, boolean>
function M.keep_rows(hunks, line_count, context)
  local keep = {}
  for _, hunk in ipairs(hunks) do
    local first, last
    if hunk.new_count > 0 then
      first = hunk.new_start
      last = hunk.new_start + hunk.new_count - 1
    else
      first = math.max(1, hunk.new_start)
      last = first
    end
    for row = first - context, last + context do
      if row >= 1 and row <= line_count then
        keep[row] = true
      end
    end
  end
  return keep
end

---`foldexpr` for the review window. Level 0 keeps a line visible, level
---1 folds it into the surrounding unchanged block. Reached only through
---the `_G.__pjollrig_inline_foldexpr` global armed in `fold_windows`.
---@param lnum integer
---@return string
local function foldexpr(lnum)
  local entry = state[vim.api.nvim_get_current_buf()]
  if not entry then
    return "0"
  end
  return entry.keep[lnum] and "0" or "1"
end

---Pierre-style fold bar: the count of hidden lines, nothing else.
---Reached only through the `_G.__pjollrig_inline_foldtext` global.
---@return string
local function foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return ("%d unmodified line%s ▸"):format(count, count == 1 and "" or "s")
end

---Window options unified mode owns. Saved before the first change so
---`clear` can put the window back the way it was — the review window
---usually dies with the session tab, but `:PjollrigReviewDiffMode split`
---flips modes in place and must not leave folds behind.
local WINDOW_OPTIONS = { "foldmethod", "foldexpr", "foldtext", "foldenable", "foldlevel", "foldminlines", "fillchars" }

---@param winid integer
---@return table<string, any>
local function save_window_options(winid)
  local saved = {}
  for _, name in ipairs(WINDOW_OPTIONS) do
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = winid })
    if ok then
      saved[name] = value
    end
  end
  return saved
end

---@param winid integer
---@param values table<string, any>
local function set_window_options(winid, values)
  for name, value in pairs(values) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = winid })
  end
end

---@param bufnr integer
---@param context integer
local function fold_windows(bufnr, context)
  local entry = state[bufnr]
  if not entry then
    return
  end
  -- Arm the eagerly-resolved fold callbacks (see maybe_clear_fold_globals).
  _G.__pjollrig_inline_foldexpr = foldexpr
  _G.__pjollrig_inline_foldtext = foldtext
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      if not entry.windows[winid] then
        entry.windows[winid] = save_window_options(winid)
      end
      set_window_options(winid, {
        foldmethod = "expr",
        foldexpr = "v:lua.__pjollrig_inline_foldexpr(v:lnum)",
        foldtext = "v:lua.__pjollrig_inline_foldtext()",
        foldenable = true,
        foldlevel = 0,
        -- Never collapse a gap smaller than the context we already show;
        -- folding two lines away costs a keystroke and saves nothing.
        foldminlines = math.max(1, context),
        fillchars = "fold: ",
      })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Hunk navigation
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@return integer[] 1-indexed rows, ascending
local function hunk_rows(bufnr)
  local entry = state[bufnr]
  if not entry then
    return {}
  end
  local rows = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, hunk in ipairs(entry.hunks) do
    local row = hunk.new_count > 0 and hunk.new_start or math.max(1, hunk.new_start)
    row = math.max(1, math.min(row, line_count))
    if rows[#rows] ~= row then
      table.insert(rows, row)
    end
  end
  table.sort(rows)
  return rows
end

---@param forward boolean
local function jump_hunk(forward)
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = hunk_rows(bufnr)
  if #rows == 0 then
    vim.notify("pjollrig: no hunks in this file", vim.log.levels.INFO)
    return
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if forward then
    for _, row in ipairs(rows) do
      if row > cur then
        target = row
        break
      end
    end
    target = target or rows[1] -- wrap
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        target = rows[i]
        break
      end
    end
    target = target or rows[#rows] -- wrap
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  -- Opening the fold matters when the wrap lands inside a collapsed
  -- unchanged block (a pure deletion anchored on a context line).
  pcall(vim.cmd, "normal! zv")
end

function M.next_hunk()
  jump_hunk(true)
end

function M.prev_hunk()
  jump_hunk(false)
end

---@param bufnr integer
local function map_hunk_navigation(bufnr)
  vim.keymap.set("n", "]h", M.next_hunk, { buffer = bufnr, desc = "Pjollrig review: next hunk" })
  vim.keymap.set("n", "[h", M.prev_hunk, { buffer = bufnr, desc = "Pjollrig review: previous hunk" })
end

---@param bufnr integer
local function unmap_hunk_navigation(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.keymap.del, "n", "]h", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "[h", { buffer = bufnr })
end

---Remove the inline diff from `bufnr` and restore the windows showing
---it. Reached via `M.clear_all` (session teardown / pair switch), the
---repaint in `M.apply`, and the per-buffer BufWipeout reaper.
---@param bufnr integer
local function clear(bufnr)
  local entry = state[bufnr]
  state[bufnr] = nil
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    maybe_clear_fold_globals()
    return
  end
  pcall(vim.api.nvim_clear_autocmds, { group = wipe_group, buffer = bufnr })
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
  unmap_hunk_navigation(bufnr)
  if entry then
    for winid, saved in pairs(entry.windows) do
      if vim.api.nvim_win_is_valid(winid) then
        set_window_options(winid, saved)
      end
    end
  end
  maybe_clear_fold_globals()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Paint the inline diff of `left_path` (baseline) against `bufnr`
---(worktree) and fold the unchanged regions away.
---@param bufnr integer
---@param left_path string
---@param opts? {fold?: boolean, context?: integer}
---@return boolean ok, string? err
function M.apply(bufnr, left_path, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "pjollrig: invalid buffer for inline diff"
  end
  local baseline, err = read_lines(left_path)
  if not baseline then
    return false, err
  end

  setup_highlights()
  clear(bufnr)

  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = M.hunks(baseline, current)
  local context = opts.context or 3
  state[bufnr] = {
    hunks = hunks,
    keep = M.keep_rows(hunks, #current, context),
    windows = {},
  }

  paint(bufnr, hunks, current)
  map_hunk_navigation(bufnr)
  -- Reap this buffer's entry the moment the buffer dies: the session can
  -- outlive any one buffer (e.g. :bwipeout on a reviewed file), and the
  -- entry would otherwise linger until clear_all at session end.
  vim.api.nvim_clear_autocmds({ group = wipe_group, buffer = bufnr })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = wipe_group,
    buffer = bufnr,
    callback = function()
      clear(bufnr)
    end,
  })
  -- Folding an identical file would hide the whole buffer behind one
  -- fold; leave it open so the user sees the file, not a placeholder.
  if opts.fold ~= false and #hunks > 0 then
    fold_windows(bufnr, context)
  end
  return true
end

---Clear every buffer this module has painted. Called whenever the review
---session moves to another pair or shuts down.
function M.clear_all()
  for bufnr in pairs(state) do
    clear(bufnr)
  end
  state = {}
  maybe_clear_fold_globals()
end

---Is `bufnr` currently showing an inline diff?
---@param bufnr integer
---@return boolean
function M.is_active(bufnr)
  return state[bufnr] ~= nil
end

return M
