local H = require("helpers")
local P = require("pjollrig")
local S = require("pjollrig.store")

local t = os.time() + 10
local function agent_writes(f, lines) -- external edit with a newer mtime, so checktime notices
  vim.fn.writefile(lines, f)
  t = t + 2
  vim.uv.fs_utime(f, t, t)
end

local function mark() -- {row0, dim}
  local m = H.marks()[1]
  return { m[2], vim.trim(m[4].sign_text) == "?" }
end

local function size(root)
  return (vim.uv.fs_stat(S.path(root)) or { size = 0 }).size
end

describe("re-anchor", function()
  local root, f
  before_each(function()
    H.reset()
    root = H.repo()
    f = root .. "/r.lua"
  end)

  it("buffer opened before the first comment follows external edits via checktime and :e! (RV-M1a, C-M2)", function()
    H.write(f, { "x", "end", "y", "end", "z" })
    vim.cmd.edit(f)
    assert.are.equal(0, size(root)) -- no log yet when the buffer was read
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    P.add({ body = "second end" })
    agent_writes(f, { "new", "x", "end", "y", "end", "z" })
    vim.cmd("silent checktime")
    assert.are.same({ 4, false }, mark())
    assert.are.equal(5, P.list()[1].lnum)
    agent_writes(f, { "a", "b", "new", "x", "end", "y", "end", "z" })
    vim.cmd("silent e!")
    assert.are.same({ 6, false }, mark())
    assert.are.equal(7, P.list()[1].lnum)
    local before = size(root)
    agent_writes(f, { "a", "b", "new", "x", "end", "y", "END!", "z" })
    vim.cmd("silent e!")
    assert.are.same({ 6, true }, mark()) -- rewritten line: dimmed, never guessed
    assert.are.equal(before, size(root)) -- and never persisted
  end)

  it(":e! after unsaved inserts restores the stored anchor and persists nothing (RV-M1b)", function()
    H.write(f, { "a", "b", "c", "TARGET", "d", "e", "f" })
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    P.add({ body = "c" })
    local before = size(root)
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved1", "unsaved2" })
    assert.are.same({ 5, false }, mark())
    vim.cmd("silent e!")
    assert.are.same({ 3, false }, mark())
    assert.are.equal(before, size(root))
    assert.are.same({ 4, "TARGET" }, { P.list()[1].lnum, P.list()[1].line })
  end)

  it("unloaded file edited elsewhere: unique text match, else dim; paint never writes (NF-N5, NF-N6)", function()
    H.write(f, { "one", "two", "three" })
    S.patch(root, { { "c1", { path = "r.lua", side = "new", lnum = 2, end_lnum = 2, line = "two", body = "b" } } })
    H.write(f, { "zero", "one", "two", "three" })
    vim.cmd.edit(f)
    assert.are.same({ 2, false }, mark())
    vim.cmd("bwipeout!")
    H.write(f, { "two", "zero", "one", "two" })
    vim.cmd.edit(f)
    assert.are.same({ 1, true }, mark()) -- duplicate text: dimmed at the stored lnum
    local before = size(root)
    for _ = 1, 100 do
      P.paint(vim.api.nvim_get_current_buf())
    end
    assert.are.equal(before, size(root))
  end)

  it(":w persists moved marks; a deleted commented line is not persisted", function()
    H.write(f, { "a", "b", "c" })
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    P.add({ body = "on b" })
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
    vim.cmd("silent write")
    assert.are.same({ 3, "b" }, { P.list()[1].lnum, P.list()[1].line })
    vim.api.nvim_buf_set_lines(0, 2, 3, false, {})
    vim.cmd("silent write")
    assert.are.same({ 3, "b" }, { P.list()[1].lnum, P.list()[1].line })
  end)
end)

describe("where comments are now (list, send)", function()
  local root, f
  local function lnums(t)
    return vim.tbl_map(function(x)
      return x.lnum
    end, t)
  end
  local function texts()
    return vim.tbl_map(function(it)
      return it.text
    end, vim.fn.getloclist(0))
  end
  local function payload()
    return require("pjollrig.sinks").format(P.list())
  end

  before_each(function()
    H.reset()
    root = H.repo()
    vim.cmd.cd(root)
    f = root .. "/r.md"
    H.write(f, { "alpha", "beta", "gamma", "delta" })
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    P.add({ body = "on beta" })
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    P.add({ body = "on delta" })
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("enew")
    vim.cmd.bwipeout(buf) -- closed: from here on its comments are placed in the file on disk
  end)

  it(
    "a closed file edited elsewhere: list rows and the send text use the new line numbers; nothing is written",
    function()
      local before = size(root)
      H.write(f, { "new1", "new2", "alpha", "beta", "gamma", "delta" })
      assert.are.same({ 4, 6 }, lnums(P.list()))
      vim.cmd("Pjollrig list")
      assert.are.same({ 4, 6 }, lnums(vim.fn.getloclist(0)))
      assert.are.same({ "on beta", "on delta" }, texts())
      assert.are.equal("Pjollrig review (2 comments):\n\n## M1 r.md:4\non beta\n\n## M2 r.md:6\non delta", payload())
      assert.are.equal(before, size(root))
    end
  )

  it("a rewritten or deleted line: [?] at its old number, and the send text quotes what was commented", function()
    H.write(f, { "alpha", "beta", "gamma", "delta, reworded" })
    local recs = P.list()
    assert.are.same(
      { { 2, nil }, { 4, true } },
      { { recs[1].lnum, recs[1].orphaned }, { recs[2].lnum, recs[2].orphaned } }
    )
    vim.cmd("Pjollrig list")
    assert.are.same({ "on beta", "[?] on delta" }, texts())
    assert(payload():find("## M2 r.md:4 (line changed)\n> delta\non delta", 1, true), payload())
    H.write(f, { "beta", "x", "beta" }) -- stored row 2 is "x" now and "beta" is ambiguous
    assert.are.same({ true, true }, { P.list()[1].orphaned, P.list()[2].orphaned })
    vim.uv.fs_unlink(f)
    assert.are.same({ { 2, 4 }, { true, true } }, { lnums(P.list()), { P.list()[1].orphaned, P.list()[2].orphaned } })
  end)

  it("an open buffer: the live mark, unsaved edits included; a dimmed mark is orphaned", function()
    H.write(f, { "new", "alpha", "beta", "gamma", "delta, reworded" })
    vim.cmd.edit(f)
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved" })
    local recs = P.list()
    assert.are.same({ 4, 5 }, lnums(recs)) -- beta: placed by text, then pushed by the unsaved line; delta: dimmed
    assert.are.same({ nil, true }, { recs[1].orphaned, recs[2].orphaned })
  end)

  it("stepping into the list rebuilds it, so it shows edits made after it opened", function()
    vim.cmd("Pjollrig list")
    assert.are.same({ 2, 4 }, lnums(vim.fn.getloclist(0)))
    vim.cmd("wincmd p") -- out of the list
    H.write(f, { "new", "alpha", "beta", "gamma", "delta" })
    vim.cmd("wincmd p") -- and back in
    assert.are.same({ "loclist", { 3, 5 } }, { vim.fn.win_gettype(), lnums(vim.fn.getloclist(0)) })
  end)
end)
