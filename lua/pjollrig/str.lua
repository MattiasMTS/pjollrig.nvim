-- pjollrig.nvim: small string helpers shared across surfaces.
--
-- Centralises two formatting primitives that were duplicated byte-for-byte
-- in the renderer, the review panel, and the floating editor:
--   * `split_lines` — newline split with an empty-string guard so callers
--     always get at least one line to render.
--   * `truncate` — byte-length-based ellipsis truncation.
--
-- Note: the gmatch / CRLF-aware splitters in `sinks/helpers.lua` and
-- `sinks/cmux.lua` have deliberately different semantics (empty-line and
-- carriage-return handling) and are NOT folded in here.

local M = {}

---Split `text` on newlines, returning at least one (empty) line so the
---caller always has something to render.
---@param text string?
---@return string[]
function M.split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

-- Composed-character cap for `M.excerpt` — an excerpt is a one-line
-- citation, not a transcript, so anything past this is cut.
local EXCERPT_MAX_CHARS = 200

---Excerpt of an anchored range's text, as captured at comment-creation
---time and quoted by the comment card: the range's first line trimmed,
---capped at `EXCERPT_MAX_CHARS` composed characters, with a trailing
---`…` when the text was cut or the range spans more lines. Returns nil
---for a blank first line (no quote at all). Shared by the add-path
---capture (`init.lua`) and the renderer's live-line fallback for
---records that predate capture, so both cite identically.
---@param first_line string?
---@param spans_more boolean? Range covers lines beyond the first
---@return string?
function M.excerpt(first_line, spans_more)
  local text = vim.trim(first_line or "")
  if text == "" then
    return nil
  end
  local cut = false
  if vim.fn.strchars(text, 1) > EXCERPT_MAX_CHARS then
    text = vim.fn.strcharpart(text, 0, EXCERPT_MAX_CHARS, 1)
    cut = true
  end
  if cut or spans_more then
    text = text .. "…"
  end
  return text
end

---Truncate `text` to `max_width` bytes, appending an ellipsis when the
---text is cut. Byte-length based (not display width) to match the
---historical behaviour of the call sites.
---@param text string
---@param max_width integer
---@return string
function M.truncate(text, max_width)
  if #text <= max_width then
    return text
  end
  if max_width <= 3 then
    return text:sub(1, max_width)
  end
  return text:sub(1, max_width - 3) .. "..."
end

return M
