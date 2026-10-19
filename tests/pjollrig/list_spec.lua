local H = require("helpers")
local P = require("pjollrig")
local S = require("pjollrig.store")
local api = vim.api

local select, notify = vim.ui.select, vim.notify

local function press(keys)
  api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function texts() -- rows of the list shown in (or owned by) the current window
  return vim.tbl_map(function(it)
    return it.text
  end, vim.fn.getloclist(0))
end

describe("list actions", function()
  local root, src, notes
  local function rec(body) -- store record by body
    for _, r in pairs(S.load(root)) do
      if r.body == body then
        return r
      end
    end
  end
  local function open(all) -- the list opens below the file and the cursor moves into it
    vim.cmd("Pjollrig list" .. (all and " all" or ""))
    assert.are.same({ "loclist", src }, { vim.fn.win_gettype(), vim.fn.getloclist(0, { filewinid = 0 }).filewinid })
  end

  before_each(function()
    H.reset()
    P._undo = {}
    root = H.repo({ ["a.lua"] = { "one", "two", "three", "four" } })
    vim.cmd.cd(root)
    vim.cmd.edit("a.lua")
    src = api.nvim_get_current_win()
    for l = 1, 4 do
      api.nvim_win_set_cursor(0, { l, 0 })
      P.add({ body = "c" .. l })
    end
    vim.ui.select = function()
      error("list actions act on rows, never pick")
    end
    notes = {}
    vim.notify = function(m)
      notes[#notes + 1] = m
    end
  end)
  after_each(function()
    vim.ui.select, vim.notify = select, notify
  end)

  it("r resolves the row under the cursor; the list redraws in place and the file repaints", function()
    open()
    assert.are.same({ "c1", "c2", "c3", "c4" }, texts())
    local lists = vim.fn.getloclist(0, { nr = "$" }).nr
    api.nvim_win_set_cursor(0, { 2, 0 })
    press("r")
    assert.is_true(rec("c2").resolved)
    assert.are.same({ "c1", "c3", "c4" }, texts())
    assert.are.same({ "loclist", 2 }, { vim.fn.win_gettype(), api.nvim_win_get_cursor(0)[1] })
    assert.are.equal(3, #H.marks(api.nvim_win_get_buf(src)))
    assert.are.equal(lists, vim.fn.getloclist(0, { nr = "$" }).nr) -- rebuilt in place: no new list (:lolder)
  end)

  it("{count}dd deletes rows; u undoes one change at a time", function()
    open()
    api.nvim_win_set_cursor(0, { 2, 0 })
    press("2dd")
    assert.are.same({ "c1", "c4" }, texts())
    assert.are.same({ true, true }, { rec("c2").deleted, rec("c3").deleted })
    press("r")
    assert.are.same({ "c1" }, texts())
    press("u")
    assert.are.same({ "c1", "c4" }, texts())
    press("u")
    assert.are.same({ "c1", "c2", "c3", "c4" }, texts())
    assert.are.same({ false, false }, { rec("c2").deleted, rec("c3").deleted })
    press("u")
    assert.are.same({ "pjollrig: nothing to undo" }, notes)
  end)

  it("visual r resolves every row unless all are resolved, then un-resolves them (list all)", function()
    S.patch(root, { { rec("c2").id, { resolved = true } } })
    open(true)
    assert.are.same({ "c1", "[resolved] c2", "c3", "c4" }, texts())
    press("ggVjr")
    assert.are.same({ "[resolved] c1", "[resolved] c2", "c3", "c4" }, texts())
    press("ggVjr")
    assert.are.same({ "c1", "c2", "c3", "c4" }, texts())
    press("GVkd")
    assert.are.same({ "c1", "c2" }, texts())
  end)

  it(":Pjollrig resolve and ce act on the row, not a pick", function()
    open()
    api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("Pjollrig resolve")
    assert.are.same({ "c1", "c2", "c4" }, texts())
    press("ce") -- the cursor stayed on row 3: c4
    api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
    press("<S-CR>")
    assert.are.same({ "loclist", { "c1", "c2", "edited" } }, { vim.fn.win_gettype(), texts() })
    assert.are.equal("edited", rec("edited").body)
  end)

  it("rows find their comment by id, so a stale list hits the right one; GitHub rows are read-only", function()
    package.loaded["pjollrig.github"] = {
      paint = function() end,
      items = function()
        return { { text = "[gh @alice] hi" } }
      end,
    }
    open()
    S.patch(root, { { rec("c1").id, { deleted = true } } }) -- another nvim; this list is now stale
    api.nvim_win_set_cursor(0, { 2, 0 })
    press("r")
    assert.are.same({ true, nil }, { rec("c2").resolved, rec("c3").resolved })
    assert.are.same({ "c3", "c4", "[gh @alice] hi" }, texts())
    api.nvim_win_set_cursor(0, { 3, 0 })
    press("r")
    press("dd")
    assert.are.same({ "c3", "c4", "[gh @alice] hi" }, texts())
    assert.are.same({ "pjollrig: no comment on this row", "pjollrig: no comment on this row" }, notes)
  end)

  it("an open list follows changes made elsewhere: resolve in the file, send", function()
    open()
    api.nvim_set_current_win(src) -- the cursor is on line 4 (the last add)
    vim.cmd("Pjollrig resolve")
    assert.are.same({ "c1", "c2", "c3" }, texts())
    local sinks = require("pjollrig.sinks")
    sinks.sinks.test = function(_, _, cb)
      cb(true)
    end
    sinks.send("test")
    sinks.sinks.test = nil
    assert.are.same({}, texts())
  end)
end)
