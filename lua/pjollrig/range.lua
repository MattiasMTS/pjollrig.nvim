-- pjollrig.nvim: record range accessors + canonical list ordering.
--
-- Shared by the review panel (`review/panel.lua`), the picker, and the
-- public `list()` sorter (`init.lua`), which previously carried
-- byte-identical copies of these helpers. Records store their range
-- 0-indexed under `record.range.start` / `record.range.end_`; these
-- accessors return the 1-indexed values listing surfaces want, falling
-- back to `1` (start) / `nil` (end) when the range is absent.
--
-- NOTE: `ui/render.lua` keeps its OWN `record_start_line` /
-- `record_end_line` (stronger `type(...)=="number"` guards) and its own
-- layout/counter comparators; those are intentionally not consolidated
-- here because their fallbacks differ.

local M = {}

---1-indexed start line of `record`, or 1 when the range is missing.
---@param record table
---@return integer
function M.start_line(record)
  if record and record.range and record.range.start then
    return (record.range.start[1] or 0) + 1
  end
  return 1
end

---1-indexed end line of `record`, or nil when the range (or a numeric
---end row) is missing.
---@param record table
---@return integer?
function M.end_line(record)
  if record and record.range and record.range.end_ then
    local row = record.range.end_[1]
    if type(row) == "number" then
      return row + 1
    end
  end
  return nil
end

---Canonical list comparator: order by uri → start line → id so every
---surface that lists records (panel, picker, completion) sees the
---same order.
---@param a table
---@param b table
---@return boolean
function M.compare(a, b)
  local ap = tostring(a.uri or "")
  local bp = tostring(b.uri or "")
  if ap ~= bp then
    return ap < bp
  end
  local al = M.start_line(a)
  local bl = M.start_line(b)
  if al ~= bl then
    return al < bl
  end
  return tostring(a.id or "") < tostring(b.id or "")
end

return M
