local picker = require("pjollrig.ui.select")

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "mx", false)
end

describe("pjollrig floating picker", function()
  local origin, calls, choice, index
  before_each(function()
    origin = vim.api.nvim_get_current_win()
    calls, choice, index = 0, nil, nil
  end)
  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.wait(20, function()
      return false
    end)
  end)

  local function chosen(item, i)
    calls, choice, index = calls + 1, item, i
  end
  local function completed()
    assert.is_true(vim.wait(1000, function()
      return calls == 1
    end))
  end

  it("selects the original item and index after closing and restoring focus", function()
    local items = { { name = "Clipboard" }, { name = "WezTerm pane" } }
    picker.select(items, {
      prompt = "Send to",
      format_item = function(item)
        return item.name
      end,
    }, chosen)
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert.are.equal("editor", vim.api.nvim_win_get_config(win).relative)
    assert.are.equal("pjollrig-picker", vim.bo[buf].filetype)
    assert.is_true(vim.wo[win].cursorline)
    press("j<CR>")
    completed()
    assert.are.equal(items[2], choice)
    assert.are.equal(2, index)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("cancels with Escape exactly once", function()
    picker.select({ "one", "two" }, {}, chosen)
    press("<Esc>")
    completed()
    assert.is_nil(choice)
    assert.is_nil(index)
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("cancels when the window is closed externally", function()
    picker.select({ "one" }, {}, chosen)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    completed()
    assert.is_nil(choice)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("cancels on focus loss without stealing focus back", function()
    vim.cmd.vsplit()
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(origin)
    picker.select({ "one" }, {}, chosen)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(other)
    completed()
    assert.is_nil(choice)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.are.equal(other, vim.api.nvim_get_current_win())
    vim.api.nvim_win_close(other, true)
  end)

  it("opens the next picker from the callback without cancelling it", function()
    picker.select({ "WezTerm" }, {}, function()
      picker.select({ "Agent pane" }, { prompt = "Pane" }, chosen)
    end)
    local first = vim.api.nvim_get_current_win()
    press("<CR>")
    assert.is_true(vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(first) and vim.api.nvim_get_current_win() ~= origin
    end))
    assert.are.equal(0, calls)
    press("<CR>")
    completed()
    assert.are.equal("Agent pane", choice)
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("keeps long lists within the screen and sanitizes multiline labels", function()
    local items = { "first\nsecond\tpart\r" .. string.rep("界", 150) }
    for i = 2, 100 do
      items[i] = "item " .. i
    end
    picker.select(items, { prompt = "Multi\nline" }, chosen)
    local win = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(win)
    assert.is_true(cfg.width <= vim.o.columns - 2)
    assert.is_true(cfg.height <= vim.o.lines - 2)
    assert.are.equal(100, vim.api.nvim_buf_line_count(0))
    assert.is_truthy(vim.api.nvim_get_current_line():find("first second part ", 1, true))
    press("G<CR>")
    completed()
    assert.are.equal("item 100", choice)
    assert.are.equal(100, index)
  end)

  it("cancels an empty list without opening a window", function()
    picker.select({}, {}, chosen)
    assert.are.equal(1, calls)
    assert.is_nil(choice)
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)
end)
