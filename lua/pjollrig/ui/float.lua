-- pjollrig.nvim: shared floating-window helpers.
--
-- Both the comment editor (`ui/editor.lua`) and the comment popup
-- renderer (`ui/render.lua`) share these primitives so title/footer and
-- winhighlight handling live in one place.

local M = {}

---@param border any
---@return boolean
local function border_is_none(border)
  if border == nil then
    return false
  end

  if type(border) == "string" then
    return border == "" or border:lower() == "none"
  end

  if type(border) == "table" and type(border.style) == "string" then
    return border.style:lower() == "none"
  end

  return false
end

---Create a scratch buffer suitable for a floating window.
---@param opts? { filetype?: string }
---@return integer bufnr
function M.create_scratch_buf(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end
  return bufnr
end

---Apply shared float window options (winhighlight, no wrap/cursorline/number).
---@param winid integer
---@param winhighlight string
function M.set_float_win_options(winid, winhighlight)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].winhighlight = winhighlight
end

---@param value number
---@param min integer
---@param max integer
---@return integer
local function clamp(value, min, max)
  return math.max(min, math.min(max, value))
end

---Convert pjollrig's fractional float transparency to Neovim winblend.
---
---Config is a float from 0.0 to 1.0, where 0.0 is opaque and 1.0 is
---fully transparent.
---@param opacity any
---@return integer winblend
function M.opacity_to_winblend(opacity)
  local value = tonumber(opacity)
  if not value or value ~= value then
    return 0
  end
  value = clamp(value, 0, 1)
  return math.floor((value * 100) + 0.5)
end

---Apply float transparency in the plugin config format.
---@param winid integer
---@param opacity any
function M.set_float_transparency(winid, opacity)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.wo[winid].winblend = M.opacity_to_winblend(opacity)
end

---Attach title/footer to a win_config table. Does nothing for the
---"none" border. Both fields exist on every supported Neovim (floor is
---0.12; title/footer landed long before) — no version checks.
---@param win_config table
---@param border any
---@param title string?
---@param title_pos string?
---@param footer string?
---@param footer_pos string?
function M.apply_title_footer(win_config, border, title, title_pos, footer, footer_pos)
  if border_is_none(border) then
    return
  end
  if title then
    win_config.title = title
    win_config.title_pos = title_pos or "left"
  end
  if footer then
    win_config.footer = footer
    win_config.footer_pos = footer_pos or "left"
  end
end

---Open a new floating window or reconfigure an existing one. Both the
---reconfigure and the fresh open are wrapped in pcall: a bad win_config
---(e.g. an anchor window that vanished between layout and open) must not
---unwind the caller's render closure. Returns nil on failure so callers
---can leave a consistent handle instead of propagating the throw. The
---second return distinguishes a freshly opened window (`true`) from a
---reconfigured one (`false`) so callers can skip re-applying one-time
---window state (tags, window-local options) on reuse.
---@param existing_winid integer?
---@param bufnr integer
---@param enter boolean
---@param win_config table
---@return integer? winid, boolean created
function M.open_or_reconfigure(existing_winid, bufnr, enter, win_config)
  if existing_winid and vim.api.nvim_win_is_valid(existing_winid) then
    local ok = pcall(vim.api.nvim_win_set_config, existing_winid, win_config)
    if ok then
      return existing_winid, false
    end
    return nil, false
  end
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, enter, win_config)
  if ok then
    return winid, true
  end
  return nil, false
end

return M
