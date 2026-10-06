local H = require("helpers")
local P = require("pjollrig")
local api = vim.api

local function review(ref)
  vim.fn.setqflist({}, " ", { title = "none" })
  vim.cmd("Pjollrig review" .. (ref and (" " .. ref) or ""))
  assert(
    vim.wait(10000, function()
      return vim.fn.getqflist({ context = 1 }).context == "pjollrig"
    end, 10),
    "review did not open"
  )
  vim.wait(200, function()
    return #vim.tbl_filter(function(w)
      return vim.wo[w].diff
    end, api.nvim_tabpage_list_wins(0)) == 2
  end, 10)
end

local function settle()
  vim.wait(50)
end

-- the diff pair of the current tab, as "name-tail|first line" for both windows
local function pair()
  local out = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.bo[api.nvim_win_get_buf(w)].buftype ~= "quickfix" then
      local b = api.nvim_win_get_buf(w)
      local name = api.nvim_buf_get_name(b):gsub("^.*[/:]", "")
      out[#out + 1] = ("%s%s|%s"):format(vim.wo[w].diff and "" or "!", name, api.nvim_buf_get_lines(b, 0, 1, false)[1])
    end
  end
  return out
end

describe("review", function()
  local root, base
  before_each(function()
    H.reset()
    root = H.repo({ ["mod.txt"] = { "a", "b", "c" }, ["gone.txt"] = { "bye" }, ["old name.txt"] = { "same" } })
    base = H.git(root, "rev-parse", "HEAD")
    H.write(root .. "/mod.txt", { "a", "B", "c" })
    H.write(root .. "/new.txt", { "fresh" })
    H.git(root, "mv", "old name.txt", "new name.txt")
    vim.fn.delete(root .. "/gone.txt")
    vim.cmd.cd(root)
  end)

  it("bare review lists uncommitted changes incl. untracked; each entry is a native diff pair (C-M6, R3)", function()
    review()
    local q = vim.fn.getqflist()
    local list = vim.tbl_map(function(e)
      return e.text .. " " .. api.nvim_buf_get_name(e.bufnr):gsub("^.*[/:]", "")
    end, q)
    assert.are.same({ "D gone.txt", "M mod.txt", "A new name.txt", "D old name.txt", "? new.txt" }, list)
    assert.are.same({ "gone.txt|bye", "gone.txt|" }, pair()) -- D: empty placeholder on the new side
    vim.cmd("cnext")
    settle()
    assert.are.same({ "mod.txt|a", "mod.txt|a" }, pair())
    local left = api.nvim_win_get_buf(api.nvim_tabpage_list_wins(0)[1])
    assert.are.same({ root = root, path = "mod.txt", side = "old", rev = base }, vim.b[left].pjollrig)
    assert.are.same({ "a", "b", "c" }, api.nvim_buf_get_lines(left, 0, -1, false))
    assert.are.same({ false, "nofile" }, { vim.bo[left].modifiable, vim.bo[left].buftype })
    vim.cmd("clast")
    settle()
    assert.are.same({ "new.txt|", "new.txt|fresh" }, pair())
    vim.cmd("cfirst | cnext")
    settle()
    assert.are.same({ "mod.txt|a", "mod.txt|a" }, pair())
  end)

  it(":cnext from the old pane keeps two panes, old left (RV-m1)", function()
    review()
    vim.cmd("wincmd h | cnext")
    settle()
    assert.are.same({ "mod.txt|a", "mod.txt|a" }, pair())
    vim.cmd("wincmd h | cnext | cnext")
    settle()
    assert.are.same({ "old name.txt|same", "old name.txt|" }, pair())
  end)

  it("old-side comment: pinned to the base, :ll lands in the old pane at its line (C-M3, RV-m1)", function()
    review()
    vim.cmd("cnext")
    settle()
    vim.cmd("wincmd h")
    api.nvim_win_set_cursor(0, { 3, 0 })
    P.add({ body = "old c" })
    local rec = P.list()[1]
    assert.are.same({ "old", base, 3, "c" }, { rec.side, rec.rev, rec.lnum, rec.line })
    vim.cmd("wincmd l")
    local right = api.nvim_get_current_win()
    api.nvim_win_set_cursor(0, { 2, 0 })
    P.add({ body = "new B" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("cfirst")
    settle()
    P.loclist()
    vim.cmd("ll 2")
    settle()
    local win = api.nvim_get_current_win()
    assert.are.equal(api.nvim_tabpage_list_wins(0)[1], win)
    assert.are.same({ "mod.txt|a", "mod.txt|a" }, pair())
    assert.are.equal(3, api.nvim_win_get_cursor(win)[1])
    assert.are.equal(1, #H.marks(api.nvim_win_get_buf(win)))
    vim.cmd("lprev") -- m6: typed in the old pane, lands in the new pane at its line
    settle()
    assert.are.same({ right, 2 }, { api.nvim_get_current_win(), api.nvim_win_get_cursor(0)[1] })
    assert.are.same({ "mod.txt|a", "mod.txt|a" }, pair())
  end)

  it("review <ref> diffs against the merge-base; inherited GIT_INDEX_FILE is ignored", function()
    H.git(root, "stash", "-u")
    H.git(root, "checkout", "-q", "-b", "feat")
    H.write(root .. "/mod.txt", { "feat" })
    H.git(root, "commit", "-qam", "feat")
    H.git(root, "checkout", "-q", "main")
    H.write(root .. "/main-only.txt", { "x" })
    H.git(root, "add", ".")
    H.git(root, "commit", "-qm", "main moves")
    H.git(root, "checkout", "-q", "feat")
    vim.env.GIT_INDEX_FILE = "/nonexistent/index"
    review("main")
    vim.env.GIT_INDEX_FILE = nil
    assert.are.same(
      { "M" },
      vim.tbl_map(function(e)
        return e.text
      end, vim.fn.getqflist())
    )
    assert.are.same({ "mod.txt|a", "mod.txt|feat" }, pair())
  end)

  it("blob:none clone: the local review reads no base blob and never fetches (RV-M2, Q8)", function()
    local o = H.repo({ ["keep.txt"] = { "k" }, ["mod.txt"] = { "a" }, ["gone.txt"] = { "bye bye" } })
    H.write(o .. "/mod.txt", { "b" })
    H.write(o .. "/new.txt", { "bye bye!" }) -- a rename candidate for gone.txt: porcelain diff would read both blobs
    vim.fn.delete(o .. "/gone.txt")
    H.git(o, "add", "-A")
    H.git(o, "commit", "-qm", "two")
    H.git(o, "config", "uploadpack.allowFilter", "true")
    local clone = H.tmp() .. "/c"
    H.git(H.tmp(), "clone", "-q", "--filter=blob:none", "file://" .. o, clone)
    clone = vim.uv.fs_realpath(clone)
    local missing = H.git(clone, "rev-list", "--objects", "--missing=print", "HEAD~1")
    assert(missing:find("?", 1, true), "fixture: HEAD~1 blobs must be missing")
    vim.uv.fs_utime(clone .. "/keep.txt", os.time() + 60, os.time() + 60) -- stat-dirty, content unchanged
    vim.cmd.cd(clone)
    local trace = H.tmp() .. "/trace"
    vim.env.GIT_TRACE = trace
    review("HEAD~1") -- the base's blobs are missing, unlike HEAD's
    vim.env.GIT_TRACE = nil
    assert.are.same(
      { "D gone.txt", "M mod.txt", "A new.txt" },
      vim.tbl_map(function(e)
        return e.text .. " " .. e.module
      end, vim.fn.getqflist())
    )
    assert(not table.concat(vim.fn.readfile(trace), "\n"):find("fetch"), "fetched")
    assert.are.equal(missing, H.git(clone, "rev-list", "--objects", "--missing=print", "HEAD~1"))
  end)

  it("re-reading a pjollrig:// buffer (:e, re-entering the paired file) keeps the old pane (M1)", function()
    review()
    vim.cmd("cnext")
    settle()
    vim.cmd("wincmd h | edit")
    assert.are.same({ "a", "b", "c" }, api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("wincmd l | cc")
    settle()
    assert.are.same({ "mod.txt|a", "mod.txt|a" }, pair())
    local left = api.nvim_win_get_buf(api.nvim_tabpage_list_wins(0)[1])
    assert.are.same({ "a", "b", "c" }, api.nvim_buf_get_lines(left, 0, -1, false))
  end)

  it(":ll lands on its line in an unloaded pjollrig:// buffer (C-M3 lockmarks)", function()
    H.write(root .. "/mod.txt", { "1", "2", "3", "4", "5", "6", "7", "8" })
    H.git(root, "commit", "-qam", "eight")
    local sha = H.git(root, "rev-parse", "HEAD")
    require("pjollrig.store").patch(root, {
      { "x1", { path = "mod.txt", side = "old", rev = sha, lnum = 6, end_lnum = 6, line = "6", body = "hi" } },
    })
    vim.fn.setqflist({}, " ", { title = "none" })
    vim.cmd.edit(root .. "/mod.txt")
    P.loclist()
    vim.cmd("wincmd p | ll 1")
    assert.are.equal(P.name("old", root, sha, "mod.txt"), api.nvim_buf_get_name(0))
    assert.are.equal(6, api.nvim_win_get_cursor(0)[1])
  end)

  it("entering another changed file (:ll, :e) re-pairs it (O1)", function()
    review()
    vim.cmd("cnext") -- mod.txt
    settle()
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/new.txt"))
    settle()
    settle()
    assert.are.same({ "new.txt|", "new.txt|fresh" }, pair())
  end)

  it("parse: 3-field renames, spaces, nested repos skipped, staged deletes once", function()
    local R = require("pjollrig.review")
    local files = R.parse("M\0a b.txt\0R097\0old.lua\0new.lua\0A\0x\0D\0f\0?\0u.txt\0sub/\0f\0")
    assert.are.same({
      { status = "M", path = "a b.txt", old = "a b.txt" },
      { status = "R", path = "new.lua", old = "old.lua" },
      { status = "A", path = "x", old = "x" },
      { status = "D", path = "f", old = "f" }, -- `git rm --cached f`: listed once
      { status = "?", path = "u.txt", old = "u.txt" },
    }, files)
  end)
end)
