local child = require("mini.test").new_child_neovim()

local function mouse(action, row, col)
  child.api.nvim_input_mouse(action == "move" and "move" or "left", action, "", 0, row - 1, col - 1)
  child.cmd("redraw") -- round trip: process input before assertions/next event
  assert.are.equal("", child.v.errmsg)
end

local function point(line, code)
  return child.lua(
    [[
    local line, code = ...
    local p = vim.fn.screenpos(source_win, line, 1)
    return { p.row, p.col - (code and 0 or 1) }
  ]],
    { line, code or false }
  )
end

local function at(action, line, code)
  mouse(action, unpack(point(line, code)))
end

local function has_button()
  return child.lua_get([[(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "pjollrig-mouse" then return true end
    end
    return false
  end)()]])
end

local function active()
  return child.lua_get([[require("pjollrig.ui.editor").is_active()]])
end

local function no_preview()
  assert.are.same(
    {},
    child.lua_get(
      [[vim.api.nvim_buf_get_extmarks(source_buf, vim.api.nvim_get_namespaces()["pjollrig.mouse"], 0, -1, {})]]
    )
  )
end

local function double_click(row, col)
  mouse("press", row, col)
  mouse("release", row, col)
  assert.is_false(active())
  mouse("press", row, col)
  assert.is_false(active()) -- wait for release so it cannot dismiss the editor
  no_preview()
  mouse("release", row, col)
end

local function submit()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "Mouse feedback" })
  child.type_keys("<Esc>", "<CR>")
  child.lua([[vim.wait(500, function() return not require("pjollrig.ui.editor").is_active() end)]])
  return child.lua_get([[require("pjollrig").list()]])
end

describe("pjollrig mouse comments", function()
  before_each(function()
    child.start()
    child.api.nvim_ui_attach(100, 30, { rgb = true })
    child.lua(
      [[
      local root = ...
      vim.opt.rtp:prepend(root)
      package.path = root .. "/tests/?.lua;" .. package.path
      H = require("helpers")
      vim.o.mouse = ""
      vim.o.mousetime = 5000 -- allow RPC round trips between real clicks
      ctx = H.setup({ ui = { display_mode = "hidden" } })
      H.edit_project_file(ctx, "mouse.lua", { "first line", "second line", "third line", "fourth line" })
      source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      vim.wo.number = true
      vim.wo.signcolumn = "no"
      vim.wo.foldcolumn = "0"
      vim.cmd("redraw")
      vim.v.errmsg = ""
    ]],
      { vim.uv.cwd() }
    )
  end)

  after_each(function()
    if child.is_running() then
      child.lua([[H.teardown(ctx)]])
      child.stop()
    end
  end)

  it("enables native mouse input by default", function()
    assert.are.equal("a", child.o.mouse)
    assert.is_true(child.lua_get([[require("pjollrig.config").get().ui.enable_mouse]]))
  end)

  it("enables native input even when mouse comments are disabled", function()
    child.o.mouse = ""
    child.lua([[
      local opts = vim.deepcopy(require("pjollrig.config").get())
      opts.ui.mouse_comments = false
      require("pjollrig").setup(opts)
    ]])
    assert.are.equal("a", child.o.mouse)
    assert.are.equal("", child.fn.maparg("<LeftMouse>", "n"))
  end)

  it("enable_mouse=false leaves disabled or custom mouse settings untouched", function()
    for _, setting in ipairs({ "", "nv", "a" }) do
      child.o.mouse = setting
      child.lua(
        [[require("pjollrig").setup({store={dir=ctx.state, poll_interval_ms=0}, sinks={clipboard=false, cmux=false, wezterm=false, github=false, socket=false}, ui={enable_mouse=false}})]]
      )
      assert.are.equal(setting, child.o.mouse)
    end
  end)

  it("rejects non-boolean enable_mouse configuration", function()
    local result = child.lua([[
      local ok, err = pcall(require("pjollrig").setup, {ui={enable_mouse="a"}})
      return {ok=ok, err=tostring(err)}
    ]])
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("ui.enable_mouse", 1, true))
  end)

  it("hover shows + without changing cursor, gutter layout or statuscolumn", function()
    local before =
      child.lua_get([[{vim.api.nvim_win_get_cursor(0), vim.wo.statuscolumn, vim.fn.getwininfo(source_win)[1].textoff}]])
    at("move", 2, true)
    assert.is_true(has_button())
    assert.are.same(
      before,
      child.lua_get([[{vim.api.nvim_win_get_cursor(0), vim.wo.statuscolumn, vim.fn.getwininfo(source_win)[1].textoff}]])
    )
    mouse("move", 30, 1)
    assert.is_false(has_button())
  end)

  it("click opens the existing editor and persists a single-line comment", function()
    at("move", 2, true)
    at("press", 2)
    assert.is_false(active())
    no_preview()
    at("release", 2)
    assert.is_true(active())
    local records = submit()
    assert.are.equal(1, #records)
    assert.are.same({ start = { 1, 0 }, end_ = { 1, 0 } }, records[1].range)
  end)

  it("double-clicking code opens the same editor and saves one line without a gutter", function()
    child.cmd("set nonumber norelativenumber signcolumn=no")
    double_click(unpack(point(2, true)))
    assert.is_true(active())
    assert.are.equal("markdown", child.bo.filetype)
    local records = submit()
    assert.are.equal(1, #records)
    assert.are.same({ start = { 1, 0 }, end_ = { 1, 0 } }, records[1].range)
  end)

  it("double-click release outside the source and Escape cancel", function()
    local p = point(2, true)
    mouse("press", unpack(p))
    mouse("release", unpack(p))
    mouse("press", unpack(p))
    mouse("release", 30, 1)
    assert.is_false(active())
    -- Change position to start a fresh native double-click sequence.
    p = point(3, true)
    mouse("press", unpack(p))
    mouse("release", unpack(p))
    mouse("press", unpack(p))
    child.type_keys("<Esc>")
    mouse("release", unpack(p))
    assert.is_false(active())
  end)

  it("double-clicks cannot turn into a range or use a stale buffer", function()
    local p = point(2, true)
    mouse("press", unpack(p))
    mouse("release", unpack(p))
    mouse("press", unpack(p))
    at("drag", 3, true)
    at("drag", 2, true)
    no_preview()
    at("release", 2, true)
    assert.is_false(active())
    assert.are.equal("n", child.fn.mode())
    p = point(4, true)
    mouse("press", unpack(p))
    mouse("release", unpack(p))
    mouse("press", unpack(p))
    child.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted" })
    mouse("release", unpack(p))
    assert.is_false(active())
  end)

  it("double-clicking virtual rows does not comment on a neighbouring source line", function()
    child.lua(
      [[vim.api.nvim_buf_set_extmark(source_buf, vim.api.nvim_create_namespace("test.virtual"), 0, 0, {virt_lines={{{"removed", "DiffDelete"}}}})]]
    )
    child.cmd("redraw")
    local p = point(1, true)
    double_click(p[1] + 1, p[2] + 2)
    assert.is_false(active())
  end)

  it("respects existing double-click mappings", function()
    child.lua([[vim.keymap.set("n", "<2-LeftMouse>", "<Cmd>let g:double_clicked = 1<CR>", {buffer=0})]])
    double_click(unpack(point(2, true)))
    assert.is_false(active())
    assert.are.equal(1, child.g.double_clicked)
  end)

  it("double-clicking code in an unfocused split comments on that source", function()
    child.cmd("vnew")
    double_click(unpack(point(3, true)))
    assert.is_true(active())
    local records = submit()
    assert.are.equal(1, #records)
    assert.is_truthy(records[1].uri:find("mouse.lua", 1, true))
    assert.are.same({ start = { 2, 0 }, end_ = { 2, 0 } }, records[1].range)
  end)

  it("gutter dragging never highlights or comments, even when returning to the start", function()
    at("press", 4)
    at("drag", 2)
    no_preview()
    at("release", 2)
    assert.is_false(active())
    assert.are.equal("n", child.fn.mode())
    at("press", 2)
    at("drag", 4)
    at("drag", 2)
    no_preview()
    at("release", 2)
    assert.is_false(active())
    -- Horizontal movement is a drag too, even on the same source line.
    local p = point(3)
    mouse("press", unpack(p))
    mouse("drag", p[1], p[2] + 2)
    mouse("drag", unpack(p))
    no_preview()
    mouse("release", unpack(p))
    assert.is_false(active())
    assert.are.equal("n", child.fn.mode())
    assert.are.same({}, child.lua_get([[require("pjollrig").list()]]))
  end)

  it("gutter clicks must release on the original button", function()
    at("press", 2)
    at("release", 3)
    assert.is_false(active())
    at("press", 4)
    at("release", 4, true)
    assert.is_false(active())
  end)

  it("text clicks and drag selection stay native", function()
    at("move", 2, true)
    at("press", 2, true)
    at("drag", 3, true)
    at("release", 3, true)
    assert.is_false(active())
    assert.are.equal("v", child.fn.mode())
    assert.are.equal(3, child.api.nvim_win_get_cursor(0)[1])
  end)

  it("releasing outside the source or pressing Escape cancels", function()
    at("press", 2)
    mouse("release", 30, 1)
    assert.is_false(active())
    at("press", 2)
    child.type_keys("<Esc>")
    at("release", 3)
    assert.is_false(active())
  end)

  it("does not offer comments on virtual rows, end-of-buffer space, or missing gutter", function()
    child.lua(
      [[vim.api.nvim_buf_set_extmark(source_buf, vim.api.nvim_create_namespace("test.virtual"), 0, 0, {virt_lines={{{"removed", "DiffDelete"}}}})]]
    )
    child.cmd("redraw")
    local p = point(1, true)
    mouse("move", p[1] + 1, p[2])
    assert.is_false(has_button())
    mouse("press", p[1] + 1, p[2] - 1)
    mouse("release", p[1] + 1, p[2] - 1)
    assert.is_false(active())
    mouse("move", 20, p[2])
    assert.is_false(has_button())
    child.cmd("set nonumber norelativenumber signcolumn=no")
    at("move", 3, true)
    assert.is_false(has_button())
  end)

  it("clicking an unfocused split uses its buffer rather than the current buffer", function()
    child.cmd("vnew")
    at("move", 3, true)
    at("press", 3)
    at("release", 3)
    assert.is_true(active())
    local records = submit()
    assert.are.equal(1, #records)
    assert.is_truthy(records[1].uri:find("mouse.lua", 1, true))
    assert.are.same({ start = { 2, 0 }, end_ = { 2, 0 } }, records[1].range)
  end)

  it("supports sign-only gutters and leaves custom statuscolumn glyphs alone", function()
    child.cmd("set nonumber signcolumn=yes")
    at("move", 2, true)
    assert.is_true(has_button())
    child.lua([[require("pjollrig.ui.mouse").clear()]])
    child.cmd("set statuscolumn=XX")
    at("move", 3, true)
    assert.is_false(has_button())
  end)

  it("clears stale gestures after edits and window changes", function()
    at("press", 2)
    child.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted" })
    at("release", 3)
    assert.is_false(active())
    at("move", 2, true)
    assert.is_true(has_button())
    child.cmd("vnew")
    assert.is_false(has_button())
  end)

  it("rejects wrapped continuations and resolves folded/scrolled rows", function()
    child.lua([[vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, {string.rep("x", 200)})]])
    child.cmd("set wrap")
    child.cmd("redraw")
    local p = point(1, true)
    mouse("move", p[1] + 1, p[2])
    assert.is_false(has_button())
    child.cmd("set nowrap foldmethod=manual")
    child.cmd("1,2fold")
    at("press", 3)
    at("release", 3)
    assert.is_true(active())
    local records = submit()
    assert.are.same({ start = { 2, 0 }, end_ = { 2, 0 } }, records[1].range)
  end)

  it("all-files review uses its prefix and routes comments to real source lines", function()
    local rows = child.lua([[
      local R = require("pjollrig.review")
      require("pjollrig.config").get().review.file_mode = "all"
      local left = ctx.artifact_root .. "/baseline.lua"
      vim.fn.writefile({"first line", "old line", "third line", "fourth line"}, left)
      assert(R.start({files={{left=left, right=ctx.root .. "/mouse.lua", path="mouse.lua", status="M"}}, label="mouse test"}))
      source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      assert(vim.wait(2000, function() return vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] ~= "Loading all files…" end))
      vim.cmd("redraw")
      local rows = {}
      for i, line in ipairs(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)) do
        if line:find("old line", 1, true) then rows.old = i end
        if line:find("second line", 1, true) then rows.new = i end
        if line:find("third line", 1, true) then rows.last = i end
      end
      return rows
    ]])
    at("move", rows.old, true)
    assert.is_false(has_button())
    at("move", 1, true)
    assert.is_false(has_button())
    at("move", rows.new, true)
    assert.is_true(has_button())
    -- All-files mode's prefix is part of its text, not a native number column.
    at("press", rows.last, true)
    no_preview()
    at("release", rows.last, true)
    assert.is_true(active())
    local records = submit()
    assert.are.equal(1, #records)
    assert.is_truthy(records[1].uri:find("mouse.lua", 1, true))
    assert.are.same({ start = { 2, 0 }, end_ = { 2, 0 } }, records[1].range)
    local p = point(rows.new, true)
    double_click(p[1], p[2] + 16) -- actual code, beyond the built-in prefix
    assert.is_true(active())
    records = submit()
    assert.are.equal(2, #records)
    local single = 0
    for _, record in ipairs(records) do
      if record.range.start[1] == 1 and record.range.end_[1] == 1 then
        single = single + 1
      end
    end
    assert.are.equal(1, single)
    child.lua([[require("pjollrig.review").stop()]])
  end)

  it("current-buffer mappings also suppress buttons on inactive windows", function()
    child.cmd("vnew")
    child.lua([[vim.keymap.set("n", "<LeftMouse>", "<Nop>", {buffer=0})]])
    at("move", 2, true)
    assert.is_false(has_button())
    -- Disabling from here must remove global maps, even though local maps mask them.
    child.lua([[require("pjollrig.config").get().ui.mouse_comments = false; require("pjollrig.ui.mouse").setup()]])
    child.lua([[vim.api.nvim_set_current_win(source_win)]])
    assert.are.equal("", child.fn.maparg("<LeftMouse>", "n"))
  end)

  it("setup is idempotent and opt-out restores mousemoveevent", function()
    child.lua([[require("pjollrig.ui.mouse").setup()]])
    at("move", 2, true)
    assert.is_true(has_button())
    child.lua([[require("pjollrig.config").get().ui.mouse_comments = false; require("pjollrig.ui.mouse").setup()]])
    assert.is_false(has_button())
    assert.is_false(child.o.mousemoveevent)
    assert.are.equal("", child.fn.maparg("<LeftMouse>", "n"))
    assert.are.equal("", child.fn.maparg("<2-LeftMouse>", "n"))
    double_click(unpack(point(2, true)))
    assert.is_false(active())
    assert.are.equal("v", child.fn.mode())
  end)

  it("preserves existing global and buffer-local mouse mappings", function()
    child.lua([[
      require("pjollrig.config").get().ui.mouse_comments = false
      require("pjollrig.ui.mouse").setup()
      vim.keymap.set("n", "<LeftMouse>", "<Nop>")
      require("pjollrig.config").get().ui.mouse_comments = true
      require("pjollrig.ui.mouse").setup()
    ]])
    assert.are.equal("<Nop>", child.fn.maparg("<LeftMouse>", "n"))
    assert.is_false(child.o.mousemoveevent)
    child.lua([[
      vim.keymap.del("n", "<LeftMouse>")
      require("pjollrig.ui.mouse").setup()
      vim.keymap.set("n", "<LeftMouse>", "<Nop>", {buffer=source_buf})
    ]])
    at("move", 2, true)
    assert.is_false(has_button())
  end)
end)
