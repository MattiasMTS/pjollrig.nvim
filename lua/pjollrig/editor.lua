-- Floating markdown editor. `:w` saves (and stays open), <S-CR> saves and closes, insert <CR> is a newline.
local M = {}
local api = vim.api

---@param body string initial text
---@param on_save fun(body: string) called on every save with a non-empty body
function M.open(body, on_save, title)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "acwrite", "wipe", false
  api.nvim_buf_set_name(buf, ("pjollrig-comment://%d"):format(buf))
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
  vim.bo[buf].filetype, vim.bo[buf].modified = "markdown", false
  local width = math.max(20, math.min(80, vim.o.columns - 4))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 8,
    border = "rounded",
    style = "minimal",
    title = " " .. (title or "comment") .. " ",
    footer = " :w save · shift+enter submit ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  local function save()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):gsub("%s+$", "")
    vim.bo[buf].modified = false
    if text ~= "" then
      on_save(text)
    end
  end
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save })
  local function submit()
    vim.cmd("stopinsert")
    save()
    pcall(api.nvim_win_close, win, true)
  end
  vim.keymap.set({ "n", "i" }, "<S-CR>", submit, { buffer = buf })
  vim.keymap.set("n", "q", function()
    pcall(api.nvim_win_close, win, true) -- discard unsaved text
  end, { buffer = buf })
  if body == "" then
    vim.cmd("startinsert")
  end
  return buf, win
end

return M
