-- Floating markdown editor. `:w` saves (and stays open), <S-CR> saves and closes, insert <CR> is a newline.
local M = {}
local api = vim.api

---@param body string initial text
---@param on_save fun(body: string) called on every save with a non-empty body
function M.open(body, on_save, title)
  local from, buf = api.nvim_get_current_win(), api.nvim_create_buf(false, true)
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
  local function close() -- opener first: a float closed from a quickfix/loclist window would skip past it
    if api.nvim_win_is_valid(from) then
      api.nvim_set_current_win(from)
    end
    pcall(api.nvim_win_close, win, true)
  end
  local function submit()
    vim.cmd("stopinsert")
    save()
    close()
  end
  vim.keymap.set({ "n", "i" }, "<S-CR>", submit, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf }) -- discard unsaved text
  if body == "" then
    vim.cmd("startinsert")
  end
  return buf, win
end

return M
