local H = require("helpers")

local ctx

local function panel()
  return require("pjollrig.review.panel")
end

local function panel_lines()
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function panel_winbar()
  local winid = assert(panel().winid(), "panel window not open")
  return vim.wo[winid].winbar
end

---Add a comment on `path` at `line` through the real add() path.
local function add_comment(path, body, line)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
  local ui = require("pjollrig.ui")
  local original_prompt = ui.prompt
  ui.prompt = function(_opts, cb)
    cb(body)
  end
  require("pjollrig").add()
  ui.prompt = original_prompt
end

---Press `lhs` in the panel window on `row` THROUGH buffer-local maps.
local function press_in_panel(row, lhs)
  local winid = assert(panel().winid(), "panel window not open")
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "mx", false)
end

---1-indexed panel row whose text contains `text`, or nil.
local function row_matching(text)
  for i, line in ipairs(panel_lines()) do
    if line:find(text, 1, true) then
      return i
    end
  end
  return nil
end

---Two project files with one comment each (a.lua:1, sub/b.lua:2).
local function seed_comments()
  local a = H.edit_project_file(ctx, "src/a.lua", { "local a = 1", "return a" })
  local b = H.edit_project_file(ctx, "sub/b.lua", { "local b = 2", "return b" })
  add_comment(a, "note on a", 1)
  add_comment(b, "note on b", 2)
  return a, b
end

describe("pjollrig project comments panel", function()
  before_each(function()
    ctx = H.setup()
    vim.cmd("runtime plugin/pjollrig.lua")
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    pcall(function()
      require("pjollrig.review.panel").close()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it(":PjollrigList outside a session opens a Comments-only panel", function()
    seed_comments()
    vim.cmd("PjollrigList")

    local winid = assert(panel().winid(), "panel did not open")
    local bufnr = vim.api.nvim_win_get_buf(winid)
    assert.are.equal("pjollrig-panel", vim.bo[bufnr].filetype)
    -- The panel takes focus (it is the surface the user asked for).
    assert.are.equal(winid, vim.api.nvim_get_current_win())

    -- Single Comments tab, project-labelled; no Files/Tree tabs.
    local winbar = panel_winbar()
    assert.is_truthy(winbar:find("%#PjollrigPanelTabActive#Comments 2", 1, true), winbar)
    assert.is_truthy(winbar:find("\u{00B7} project", 1, true), winbar)
    assert.is_nil(winbar:find("Files", 1, true))
    assert.is_nil(winbar:find("Tree", 1, true))

    -- Rows over multiple files: project-root-relative path:line + body.
    local lines = panel_lines()
    assert.are.equal(2, #lines)
    assert.is_truthy(lines[1]:find("src/a.lua:1", 1, true), lines[1])
    assert.is_truthy(lines[1]:find("note on a", 1, true))
    assert.is_truthy(lines[2]:find("sub/b.lua:2", 1, true), lines[2])
    assert.is_truthy(lines[2]:find("note on b", 1, true))
  end)

  it(":PjollrigList never creates a quickfix list", function()
    seed_comments()
    local before = vim.fn.getqflist({ title = 1 }).title
    vim.cmd("PjollrigList")
    assert.are.equal(before, vim.fn.getqflist({ title = 1 }).title)
    assert.are.equal(0, #vim.fn.getqflist())
  end)

  it("H, L, and t are not mapped in project mode", function()
    seed_comments()
    vim.cmd("PjollrigList")
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(assert(panel().bufnr()), "n")) do
      assert.are_not.equal("H", map.lhs, "H leaked into the project-mode panel")
      assert.are_not.equal("L", map.lhs, "L leaked into the project-mode panel")
      assert.are_not.equal("t", map.lhs, "t leaked into the project-mode panel")
    end
  end)

  it("respects review.panel placement config in project mode", function()
    H.teardown(ctx)
    ctx = H.setup({ review = { panel = { position = "right" } } })
    vim.cmd("runtime plugin/pjollrig.lua")
    seed_comments()

    vim.cmd("PjollrigList")

    local winid = assert(panel().winid())
    local col = vim.api.nvim_win_get_position(winid)[2]
    assert.are.equal(vim.o.columns, col + vim.api.nvim_win_get_width(winid))
    assert.is_true(vim.wo[winid].winfixwidth)
  end)

  it("<CR> jumps to the comment's file and line in the previous window", function()
    local a = seed_comments()
    -- The invoking window shows a.lua; the jump must reuse it.
    vim.cmd.edit(vim.fn.fnameescape(a))
    local invoking_win = vim.api.nvim_get_current_win()

    vim.cmd("PjollrigList")
    press_in_panel(assert(row_matching("sub/b.lua")), "<CR>")

    assert.are.equal(invoking_win, vim.api.nvim_get_current_win())
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(invoking_win))
    assert.is_truthy(name:find("sub/b.lua", 1, true), "expected sub/b.lua, got " .. name)
    assert.are.equal(2, vim.api.nvim_win_get_cursor(invoking_win)[1])
    -- Panel stays open.
    assert.is_truthy(panel().winid(), "jump closed the panel")
  end)

  it("dd deletes the comment and its row disappears on the coalesced refresh", function()
    seed_comments()
    vim.cmd("PjollrigList")
    assert.are.equal(2, #panel_lines())

    press_in_panel(assert(row_matching("note on a")), "dd")

    assert.is_true(
      vim.wait(1000, function()
        return row_matching("note on a") == nil
      end, 10),
      "deleted row did not disappear"
    )
    assert.are.equal(1, #require("pjollrig.store").all(ctx.root))
    assert.is_truthy(row_matching("note on b"))
    assert.is_truthy(panel_winbar():find("Comments 1", 1, true), panel_winbar())
  end)

  it("u restores the last deleted comment's row", function()
    seed_comments()
    vim.cmd("PjollrigList")
    press_in_panel(assert(row_matching("note on a")), "dd")
    assert.is_true(vim.wait(1000, function()
      return row_matching("note on a") == nil
    end, 10))

    press_in_panel(1, "u")

    assert.is_true(
      vim.wait(1000, function()
        return row_matching("note on a") ~= nil
      end, 10),
      "u did not restore the row"
    )
    assert.are.equal(2, #require("pjollrig.store").all(ctx.root))
  end)

  it("coalesces a synchronous event burst into one refresh", function()
    seed_comments()
    vim.cmd("PjollrigList")
    -- Drain callbacks already scheduled by the open.
    vim.wait(50, function()
      return false
    end, 10)

    local pjollrig = require("pjollrig")
    local original_list = pjollrig.list
    local list_calls = 0
    pjollrig.list = function(...)
      list_calls = list_calls + 1
      return original_list(...)
    end
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("User", { pattern = "PjollrigEdited" })
    end
    assert.is_true(vim.wait(1000, function()
      return list_calls > 0
    end, 10))
    vim.wait(50, function()
      return false
    end, 10)
    pjollrig.list = original_list

    assert.are.equal(1, list_calls)
  end)

  it("q closes the panel in a split placement and :PjollrigList reopens it", function()
    seed_comments()
    vim.cmd("PjollrigList")
    assert.is_truthy(panel().winid())

    press_in_panel(1, "q")
    assert.is_nil(panel().winid(), "q did not close the project-mode panel")

    vim.cmd("PjollrigList")
    assert.is_truthy(panel().winid(), "reopen after q failed")
    assert.are.equal(2, #panel_lines())
  end)

  it(":PjollrigList during a review session focuses the panel's Comments tab", function()
    local left = ctx.artifact_root .. "/left/f1.lua"
    local right = ctx.root .. "/f1.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ "return 1 -- old" }, left)
    vim.fn.writefile({ "return 1 -- new" }, right)
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = { { left = left, right = right, status = "M", path = "f1.lua" } }, label = "ls" }))
    add_comment(right, "session note", 1)

    vim.cmd("PjollrigList")

    local winid = assert(panel().winid())
    assert.are.equal(winid, vim.api.nvim_get_current_win(), ":PjollrigList did not focus the panel")
    local winbar = panel_winbar()
    assert.is_truthy(winbar:find("%#PjollrigPanelTabActive#Comments 1", 1, true), winbar)
    -- Still the review panel: the full tab set is present.
    assert.is_truthy(winbar:find("Files 1", 1, true), winbar)
    assert.is_truthy(row_matching("session note"))
  end)
end)
