local H = require("helpers")

local ctx

local function setup_env(opts)
  ctx = H.setup(opts)
  H.edit_project_file(ctx, "src/float.lua", {
    "local value = 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

local function floating_windows_containing(text)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      if cfg.relative and cfg.relative ~= "" then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local lines = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if lines:find(text, 1, true) then
          table.insert(wins, winid)
        end
      end
    end
  end
  return wins
end

local function wait_for_popup(text)
  local wins = {}
  local ok = vim.wait(1000, function()
    wins = floating_windows_containing(text)
    return #wins == 1
  end, 10)
  assert.is_true(ok)
  return wins[1]
end

local function float_footer(winid)
  local footer = vim.api.nvim_win_get_config(winid).footer
  if type(footer) == "string" then
    return footer
  end
  if type(footer) == "table" then
    local parts = {}
    for _, item in ipairs(footer) do
      if type(item) == "string" then
        table.insert(parts, item)
      elseif type(item) == "table" and type(item[1]) == "string" then
        table.insert(parts, item[1])
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

describe("pjollrig float transparency", function()
  before_each(function()
    setup_env({
      ui = {
        opacity = 0.5,
      },
    })
  end)
  after_each(teardown_env)

  it("converts fractional opacity to Neovim winblend", function()
    local float = require("pjollrig.ui.float")

    assert.are.equal(0, float.opacity_to_winblend(0))
    assert.are.equal(25, float.opacity_to_winblend(0.25))
    assert.are.equal(50, float.opacity_to_winblend(0.5))
    assert.are.equal(99, float.opacity_to_winblend(0.99))
    assert.are.equal(100, float.opacity_to_winblend(1))

    assert.are.equal(100, float.opacity_to_winblend(50))
    assert.are.equal(100, float.opacity_to_winblend(150))
    assert.are.equal(0, float.opacity_to_winblend(-10))
  end)

  it("rejects opacity values outside the fractional range", function()
    local ok, err = pcall(require("pjollrig.config").setup, {
      ui = {
        opacity = 1.5,
      },
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("ui.opacity", 1, true))
  end)

  it("applies fractional opacity to the comment editor float", function()
    local editor = require("pjollrig.ui.editor")
    local cfg = require("pjollrig.config").get().ui

    assert.is_true(editor.open({
      title = "Comment",
      cfg = cfg,
    }, function() end))

    assert.is_true(editor.is_active())
    local winid = vim.api.nvim_get_current_win()
    assert.are.equal(50, vim.wo[winid].winblend)
    assert.is_true(vim.wo[winid].wrap)
    assert.is_false(vim.wo[winid].linebreak)
    assert.are.equal("enter newline | normal enter submit | q close", float_footer(winid))

    editor.close_active()
    assert.is_true(vim.wait(1000, function()
      return not editor.is_active()
    end, 10))
  end)

  it("does not hard-wrap inserted editor text from markdown textwidth hooks", function()
    local editor = require("pjollrig.ui.editor")
    local group = vim.api.nvim_create_augroup("PjollrigTestMarkdownTextwidth", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "markdown",
      callback = function(args)
        vim.bo[args.buf].textwidth = 12
        vim.bo[args.buf].formatoptions = vim.bo[args.buf].formatoptions .. "t"
      end,
    })

    assert.is_true(editor.open({
      title = "Comment",
      cfg = require("pjollrig.config").get().ui,
    }, function() end))

    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal(0, vim.bo[bufnr].textwidth)
    assert.are.equal(0, vim.bo[bufnr].wrapmargin)

    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ione two three four five", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return #lines == 1 and lines[1] == "one two three four five"
    end, 10))

    editor.close_active()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    assert.is_true(vim.wait(1000, function()
      return not editor.is_active()
    end, 10))
  end)

  it("renders the editor footer from configured keys", function()
    local editor = require("pjollrig.ui.editor")
    local cfg = vim.tbl_deep_extend("force", vim.deepcopy(require("pjollrig.config").get().ui), {
      editor = {
        submit_keys = { "<C-g>" },
        cancel_keys = { "<Esc>" },
      },
    })

    assert.is_true(editor.open({
      title = "Comment",
      cfg = cfg,
    }, function() end))

    assert.are.equal("ctrl+g submit | esc close", float_footer(vim.api.nvim_get_current_win()))

    editor.close_active()
    assert.is_true(vim.wait(1000, function()
      return not editor.is_active()
    end, 10))
  end)

  it("applies fractional opacity to rendered comment popups", function()
    require("pjollrig").add({
      body = "transparent popup",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local winid = wait_for_popup("transparent popup")
    assert.are.equal(50, vim.wo[winid].winblend)
  end)

  it("uses the derived card surface for border and title cells", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xeeeeee, bg = 0x111111 })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xdddddd, bg = 0x222222 })
    vim.api.nvim_set_hl(0, "FloatBorder", { fg = 0xaaaaaa, bg = 0x333333 })
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x999999 })

    local render = require("pjollrig.ui.render")
    render.refresh_highlights()

    local border_hl = vim.api.nvim_get_hl(0, { name = "PjollrigCommentBorder", link = false })
    local meta_hl = vim.api.nvim_get_hl(0, { name = "PjollrigCommentMeta", link = false })

    -- Card surface: Normal bg nudged 6% toward Normal fg; the border fg
    -- recedes 45% toward the bg (render_spec's palette suite covers the
    -- full derivation).
    local blend = require("pjollrig.ui.color").blend
    local surface = blend(0x111111, 0xeeeeee, 0.06)
    assert.are.equal(surface, border_hl.bg)
    assert.are.equal(surface, meta_hl.bg)
    assert.are.equal(blend(0xaaaaaa, 0x111111, 0.45), border_hl.fg)
    assert.are.equal(0x999999, meta_hl.fg)
  end)
end)
