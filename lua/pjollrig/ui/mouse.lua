-- Mouse comments reuse add(); this module owns only hit-testing and gestures.
local M = {}
local ns = vim.api.nvim_create_namespace("pjollrig.mouse")
local button, button_buf, hover, click
local installed = {}
local previous_mousemove
local keys =
  { "<MouseMove>", "<LeftMouse>", "<LeftDrag>", "<LeftRelease>", "<2-LeftMouse>", "<2-LeftDrag>", "<2-LeftRelease>" }

local function hide_button()
  local win = button
  button, hover = nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

function M.clear()
  hide_button()
  click = nil
end

-- getmousepos() supplies buffer coordinates, including in the gutter. Verify
-- the screen row too: virtual lines, diff filler and wrapped continuations do
-- not represent a new source line and must never silently pick a neighbour.
local function target(code)
  local pos = vim.fn.getmousepos()
  local win = pos.winid
  if win == 0 or not vim.api.nvim_win_is_valid(win) or pos.line < 1 then
    return
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].rightleft then
    return
  end
  if vim.fn.getcmdwintype() ~= "" or require("pjollrig.ui.editor").is_active() then
    return
  end
  -- Mappings resolve in the current buffer, even for inactive-window clicks.
  for _, key in ipairs(keys) do
    if vim.fn.maparg(key, "n", false, true).callback ~= installed[key] then
      return
    end
  end
  local buf = vim.api.nvim_win_get_buf(win)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.tbl_contains(keys, map.lhs) then
      return
    end
  end
  local all = package.loaded["pjollrig.review.all"]
  local combined = all and all.is_active(buf)
  if combined then
    if not all.commentable_line(buf, pos.line) then
      return
    end
  elseif vim.bo[buf].filetype:match("^pjollrig%-") then
    return
  elseif not hover or hover.win ~= win or hover.buf ~= buf then
    -- Identity is stable while hovering this window; avoid filesystem walks
    -- on every pixel of mouse movement. add() validates again on submission.
    local identity = require("pjollrig.adapter").identify(buf)
    if not identity or not identity.is_writable then
      return
    end
  end
  local screen = vim.fn.screenpos(win, pos.line, 1)
  if screen.row ~= pos.screenrow or screen.row == 0 then
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  -- Double-clicking code needs no gutter or spare statuscolumn cell.
  if code then
    if pos.wincol > info.textoff then
      return { win = win, buf = buf, line = pos.line }
    end
    return
  end
  -- Use the separating blank just before code. The combined review has its
  -- own text prefix, so its first cell is usable even with no native gutter.
  local col = info.wincol + info.textoff - (combined and 0 or 1)
  if (not combined and info.textoff == 0) or col < info.wincol then
    return
  end
  -- Never cover a custom statuscolumn glyph, fold control or sign.
  local on_button = hover and hover.win == win and hover.row == screen.row and hover.col == col
  if not on_button and vim.fn.screenstring(screen.row, col) ~= " " then
    return
  end
  return { win = win, buf = buf, line = pos.line, row = screen.row, col = col, hit = pos.screencol == col }
end

local function show_button(t)
  if not button_buf or not vim.api.nvim_buf_is_valid(button_buf) then
    button_buf = require("pjollrig.ui.float").create_scratch_buf({ filetype = "pjollrig-mouse" })
    vim.api.nvim_buf_set_lines(button_buf, 0, -1, false, { "+" })
  end
  button = require("pjollrig.ui.float").open_or_reconfigure(button, button_buf, false, {
    relative = "editor",
    row = t.row - 1,
    col = t.col - 1,
    width = 1,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    mouse = false,
    noautocmd = true,
    zindex = 210,
  })
  if button then
    vim.wo[button].winhighlight = "NormalFloat:DiagnosticSignInfo"
    hover = t
  end
end

function M.handle(key)
  local double = key == "2-LeftMouse"
  key = key:gsub("^2%-", "")
  if key == "LeftDrag" then
    -- Consume owned drags until release, but never select or add a comment.
    if click then
      click.cancelled = true
    end
    return
  end
  local t = target(double or (click and click.double))
  if key == "MouseMove" then
    if not click then
      if t then
        show_button(t)
      else
        hide_button()
      end
    end
  elseif key == "LeftMouse" then
    M.clear()
    if t and (t.hit or double) then
      click =
        { win = t.win, buf = t.buf, line = t.line, tick = vim.api.nvim_buf_get_changedtick(t.buf), double = double }
    end
  elseif key == "LeftRelease" and click then
    local started = click
    M.clear()
    if
      not started.cancelled
      and t
      and t.win == started.win
      and t.buf == started.buf
      and t.line == started.line
      and (started.double or t.hit)
      and vim.api.nvim_buf_get_changedtick(t.buf) == started.tick
    then
      vim.api.nvim_set_current_win(started.win)
      vim.api.nvim_win_set_cursor(started.win, { t.line, 0 })
      require("pjollrig").add({ range = { t.line, t.line } })
    end
  end
end

-- Expr mappings pass unrelated clicks/drags straight to Neovim. UI changes
-- run via <Cmd>, outside expr-map textlock; no feedkeys or remapping loops.
local function mapping(key)
  local command = "<Cmd>lua require('pjollrig.ui.mouse').handle('" .. key:sub(2, -2) .. "')<CR>"
  if key == "<MouseMove>" or (click and key ~= "<LeftMouse>") then
    return command
  end
  local double = key == "<2-LeftMouse>"
  if key == "<LeftMouse>" or double then
    local t = target(double)
    if t and (t.hit or double) then
      return command
    end
  end
  return key
end

function M.setup()
  M.clear()
  -- Delete only mappings still owned by us; never erase later user changes.
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if installed[map.lhs] and map.callback == installed[map.lhs] then
      vim.keymap.del("n", map.lhs)
    end
  end
  installed = {}
  if previous_mousemove ~= nil then
    if vim.o.mousemoveevent then
      vim.o.mousemoveevent = previous_mousemove
    end
    previous_mousemove = nil
  end
  vim.on_key(nil, ns)
  local group = vim.api.nvim_create_augroup("PjollrigMouse", { clear = true })
  local ui = require("pjollrig.config").get().ui
  if ui.enable_mouse then
    vim.o.mouse = "a"
  end
  if not ui.mouse_comments then
    return
  end
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if vim.tbl_contains(keys, map.lhs) then
      vim.notify("pjollrig: mouse comments disabled: existing " .. map.lhs .. " mapping", vim.log.levels.WARN)
      return
    end
  end
  previous_mousemove = vim.o.mousemoveevent
  vim.o.mousemoveevent = true
  for _, key in ipairs(keys) do
    local callback = function()
      return mapping(key)
    end
    installed[key] = callback
    vim.keymap.set("n", key, callback, { expr = true, silent = true, desc = "Pjollrig mouse comments" })
  end
  vim.api.nvim_create_autocmd(
    { "BufLeave", "WinLeave", "WinScrolled", "WinResized", "TextChanged", "ModeChanged", "FocusLost" },
    {
      group = group,
      callback = M.clear,
    }
  )
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if (hover and hover.win == win) or (click and click.win == win) then
        M.clear()
      end
    end,
  })
  vim.on_key(function(key)
    if key == "\27" then
      vim.schedule(M.clear)
    end
  end, ns)
end

return M
