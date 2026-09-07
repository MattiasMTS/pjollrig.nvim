-- pjollrig.nvim: vim.ui.select picker for the edit / delete / resolve
-- commands.
--
-- The picker renders records in the same order as `:PjollrigList` (see
-- `init.list`, which sorts by path → start line → id). Each command's
-- completion returns raw positional numbers `"1"`..`"N"`; the picker is
-- the surface where those numbers get a human face.
--
-- Items are paired `{ record = r, display = "..." }` tables so the
-- `format_item` callback is a trivial field lookup instead of doing an
-- identity-map dance, and the action callback reaches the record id via
-- `chosen.record.id`.

local M = {}

local range = require("pjollrig.range")

local BODY_MAX = 50
local LOCATION_MAX = 28
local ELLIPSIS = "…"
local COLUMN_SEPARATOR = " │ "
local RESOLVED_PREFIX = "[✓] "

---Strip control characters and collapse whitespace so a single body line
---is safe to render in `vim.ui.select` (which forbids newlines).
---@param s string
---@return string
local function sanitize(s)
  if not s or s == "" then
    return ""
  end
  -- Tabs → spaces, then drop remaining C0 control bytes. Keep it ASCII-
  -- safe; Neovim's select backends handle UTF-8 transparently.
  s = s:gsub("\t", " ")
  s = s:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  return s
end

---Return the first non-empty line of `body`.
---@param body string|nil
---@return string
local function first_nonempty_line(body)
  if not body or body == "" then
    return ""
  end
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" then
      return trimmed
    end
  end
  return ""
end

---Compute the display width of a string in cells via
---`vim.fn.strdisplaywidth`, so multibyte/wide glyphs count their real
---cell width when aligning the picker columns.
---@param s string
---@return integer
local function width(s)
  return vim.fn.strdisplaywidth(s)
end

---Right-truncate `s` to `max` display cells, appending an ellipsis when
---the input exceeds the budget. No-op when already short enough.
---@param s string
---@param max integer
---@return string
local function truncate_right(s, max)
  if width(s) <= max then
    return s
  end
  if max <= 1 then
    return s:sub(1, max)
  end
  -- Greedy shrink: keep popping bytes until width fits with an ellipsis.
  local budget = max - width(ELLIPSIS)
  while width(s) > budget and #s > 0 do
    s = s:sub(1, -2)
  end
  return s .. ELLIPSIS
end

---Left-truncate `s` to `max` display cells, prepending an ellipsis when
---the input exceeds the budget. Used for paths so the filename stays
---visible.
---@param s string
---@param max integer
---@return string
local function truncate_left(s, max)
  if width(s) <= max then
    return s
  end
  if max <= 1 then
    return s:sub(-max)
  end
  local budget = max - width(ELLIPSIS)
  while width(s) > budget and #s > 0 do
    s = s:sub(2)
  end
  return ELLIPSIS .. s
end

---Pad `s` on the right with spaces up to `w` display cells.
---@param s string
---@param w integer
---@return string
local function rpad(s, w)
  local delta = w - width(s)
  if delta <= 0 then
    return s
  end
  return s .. string.rep(" ", delta)
end

---Pad `s` on the left with spaces up to `w` display cells.
---@param s string
---@param w integer
---@return string
local function lpad(s, w)
  local delta = w - width(s)
  if delta <= 0 then
    return s
  end
  return string.rep(" ", delta) .. s
end

---Resolve a record's URI to a display-ready path. Prefers the
---project-relative form when `project_root` is set and the URI maps
---to a real filesystem path; falls back to the absolute path or the
---raw URI string for non-file schemes (session-scope `term://` etc.).
---@param record table
---@return string
local function display_path(record)
  local uri_mod = require("pjollrig.uri")
  local abs = uri_mod.to_path(record.uri)
  if abs and record.project_root and record.project_root ~= "" then
    local rel
    if vim.fs.relpath then
      rel = vim.fs.relpath(record.project_root, abs)
    end
    if rel and rel ~= "" then
      return rel
    end
  end
  return abs or tostring(record.uri or "")
end

---Build the `<path>:<line>` or `<path>:<start>-<end>` string for a
---record, applying the left-truncation budget so the column stays
---aligned.
---@param record table
---@return string
local function location_for(record)
  local path = display_path(record)
  -- Reuse the shared 1-indexed range accessors so the picker's line
  -- numbers stay in lockstep with the review panel. `start_line`
  -- falls back to 1 when the range is missing; `end_line` is nil unless
  -- there's a numeric end row.
  local sl = range.start_line(record)
  local el_row = range.end_line(record)
  local line
  if el_row and el_row > sl then
    line = string.format("%d-%d", sl, el_row)
  else
    line = tostring(sl)
  end
  local suffix = ":" .. line
  local path_budget = LOCATION_MAX - width(suffix)
  if path_budget < 1 then
    path_budget = 1
  end
  return truncate_left(path, path_budget) .. suffix
end

---Build the body column for a record, prefixing resolved entries with
---`[✓] ` so they're visibly done.
---@param record table
---@return string
local function body_for(record)
  local text = sanitize(first_nonempty_line(record.body))
  if record.resolved then
    text = RESOLVED_PREFIX .. text
  end
  return truncate_right(text, BODY_MAX)
end

---Format `records` into display strings, parallel-indexed to `records`.
---`M.pick` zips them into `{ record, display }` tables.
---@param records table[]
---@return string[]
local function format_items(records)
  local out = {}
  local count = #records
  local idx_width = #tostring(math.max(count, 1))
  for i, r in ipairs(records) do
    local idx = lpad(tostring(i), idx_width)
    local loc = rpad(location_for(r), LOCATION_MAX)
    local body = body_for(r)
    out[i] = idx .. COLUMN_SEPARATOR .. loc .. COLUMN_SEPARATOR .. body
  end
  return out
end

---Open `vim.ui.select` for `records` and invoke
---`require("pjollrig")[action](chosen.id)` on the picked record. No-op
---with an INFO notification when there are no records.
---@param action "edit"|"delete"|"resolve"
---@param records table[]
function M.pick(action, records)
  if not records or #records == 0 then
    vim.notify("pjollrig: no comments", vim.log.levels.INFO)
    return
  end
  local formatted = format_items(records)
  local items = {}
  for i, r in ipairs(records) do
    items[i] = { record = r, display = formatted[i] }
  end
  vim.ui.select(items, {
    prompt = ("Pjollrig: %s comment"):format(action),
    format_item = function(item)
      return item.display
    end,
  }, function(chosen)
    if not chosen then
      return
    end
    require("pjollrig")[action](chosen.record.id, {
      scope = chosen.record.scope,
      project_root = chosen.record.project_root,
    })
  end)
end

return M
