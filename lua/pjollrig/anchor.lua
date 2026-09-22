-- pjollrig.nvim: buffer anchoring via extmarks.
--
-- Strategy
-- --------
-- Each comment is pinned to a buffer range with an extmark (created by
-- `lua/pjollrig/ui/render.lua`). We rely on Neovim's `invalidate = true`
-- option so that the extmark is flagged as invalid when its anchor lines
-- are deleted, allowing us to surface "orphaned" comments without losing
-- them. `undo_restore = false` keeps invalidation stable across undo.
--
-- The extmark anchors the comment and tints the line number via
-- `PjollrigLineNr` (default-linked to `DiagnosticSignInfo`). All other
-- visuals (popups, borders, hints) live in `lua/pjollrig/ui/render.lua`.
--
-- The namespace is shared across all pjollrig extmarks in a buffer so
-- we can list/clear them in bulk.

local M = {}

---Neovim namespace used for all pjollrig extmarks.
M.ns = vim.api.nvim_create_namespace("pjollrig")

---Resolve an anchor back to a live range.
---@param bufnr integer
---@param mark_id integer
---@return {range: {start: integer[], end_: integer[]}, invalid: boolean}|nil
function M.resolve(bufnr, mark_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark_id, { details = true })
  if not pos or #pos == 0 then
    return nil
  end
  local row, col, details = pos[1], pos[2], pos[3] or {}
  return {
    range = {
      start = { row, col },
      end_ = { details.end_row or row, details.end_col or col },
    },
    invalid = details.invalid == true,
  }
end

return M
