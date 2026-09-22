-- A shared floating list for Pjollrig's selection prompts.
local M = {}
local float = require("pjollrig.ui.float")

local function single_line(text)
  return tostring(text):gsub("%c", " ")
end

---Select an item, closing the float before invoking the callback.
---@param items any[]
---@param opts {prompt?: string, format_item?: fun(item: any): string}
---@param on_choice fun(item: any|nil, index: integer|nil)
function M.select(items, opts, on_choice)
  if #items == 0 then
    on_choice(nil, nil)
    return
  end
  opts = opts or {}
  local title = " " .. single_line(opts.prompt or "Select") .. " "
  local footer = " j/k ↑/↓ move · Enter select · Esc cancel "
  local lines = {}
  local width = math.max(vim.fn.strdisplaywidth(title), vim.fn.strdisplaywidth(footer))
  for i, item in ipairs(items) do
    lines[i] = "  " .. single_line(opts.format_item and opts.format_item(item) or item) .. "  "
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  width = math.max(1, math.min(width, 100, vim.o.columns - 4))
  local height = math.max(1, math.min(#items, 12, vim.o.lines - vim.o.cmdheight - 4))
  local origin = vim.api.nvim_get_current_win()
  local bufnr = float.create_scratch_buf({ filetype = "pjollrig-picker" })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local winid = float.open_or_reconfigure(nil, bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = footer,
    footer_pos = "left",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
  })
  if not winid then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    on_choice(nil, nil)
    return
  end
  float.set_float_win_options(winid, "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel")
  float.set_float_transparency(winid, require("pjollrig.config").get().ui.opacity)
  vim.wo[winid].cursorline = true
  vim.wo[winid].cursorlineopt = "both"
  vim.wo[winid].scrolloff = 3
  vim.cmd.stopinsert()

  local done = false
  local function finish(index)
    if done then
      return
    end
    done = true
    -- Defer cleanup so window/buffer autocmds can also cancel safely.
    vim.schedule(function()
      local focused = vim.api.nvim_get_current_win() == winid
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      if focused and vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
      end
      on_choice(items[index], index)
    end)
  end
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  local function map(keys, callback)
    vim.keymap.set("n", keys, callback, { buffer = bufnr, silent = true, nowait = true })
  end
  local function move(delta)
    local row = vim.api.nvim_win_get_cursor(winid)[1]
    vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(#items, row + delta)), 0 })
  end
  for _, key in ipairs({ "j", "<Down>", "<C-n>" }) do
    map(key, function()
      move(1)
    end)
  end
  for _, key in ipairs({ "k", "<Up>", "<C-p>" }) do
    map(key, function()
      move(-1)
    end)
  end
  map("<CR>", function()
    finish(vim.api.nvim_win_get_cursor(winid)[1])
  end)
  for _, key in ipairs({ "<Esc>", "q", "<C-c>" }) do
    map(key, function()
      finish(nil)
    end)
  end
end

return M
