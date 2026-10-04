local H = require("helpers")
local P = require("pjollrig")
local api = vim.api

local function id(buf)
  local a, why = P.identity(buf or 0)
  return a and ("%s %s%s"):format(a.path, a.side, a.rev and (" @" .. a.rev) or "") or ("REJECT " .. why)
end

-- left pane named `name` (a foreign tool's old side) diffed against the real file, like gitsigns/fugitive/diffview
local function left_pane(root, name, diff)
  vim.cmd("tabnew " .. root .. "/a.lua")
  if diff then
    vim.cmd("diffthis")
  end
  vim.cmd("leftabove vsplit | enew")
  api.nvim_buf_set_name(0, name)
  vim.bo.buftype = "nowrite"
  api.nvim_buf_set_lines(0, 0, -1, false, { "old" })
  if diff then
    vim.cmd("diffthis")
  end
end

describe("identity", function()
  local root
  before_each(function()
    H.reset()
    root = H.repo()
  end)

  it("repo file is the new side; plain file and scratch buffers are not lost", function()
    vim.cmd.edit(root .. "/a.lua")
    assert.are.same({ root = root, path = "a.lua", side = "new" }, P.identity(0))
    local plain = H.tmp() .. "/notes.md"
    H.write(plain, { "x" })
    vim.cmd.edit(plain)
    assert.are.equal("notes.md new", id())
    vim.cmd("enew")
    assert.are.equal("buffer:" .. api.nvim_get_current_buf(), P.identity(0).root) -- in memory
  end)

  it("b:pjollrig wins (our pjollrig:// buffers and any plugin that wants exactness)", function()
    vim.cmd("enew")
    vim.b.pjollrig = { root = root, path = "a.lua", side = "old", rev = "abc1234" }
    assert.are.equal("a.lua old @abc1234", id())
  end)

  it("any tool: a non-repo buffer diffed against exactly one repo file is that file's old side (D-M3)", function()
    for _, name in ipairs({
      "gitsigns://" .. root .. "/.git//HEAD~1:a.lua",
      "gitsigns://" .. root .. "/.git//:0:a.lua",
      "fugitive://" .. root .. "/.git//0/a.lua",
      "diffview://" .. root .. "/.git/abc/a.lua",
    }) do
      left_pane(root, name, true)
      assert.are.equal("a.lua old", id(), name)
    end
    left_pane(root, "codediff:///" .. root .. "///HEAD/a.lua", false) -- no 'diff': memory, not misfiled
    assert.are.equal("buffer:", P.identity(0).root:match("^buffer:"))
  end)

  it("git difftool temp files are never filed under the temp path", function()
    local tmp = H.tmp() .. "/git-blob-XyZ/a.lua"
    H.write(tmp, { "one" })
    vim.cmd.edit(tmp)
    assert.are.equal("REJECT git difftool temp file without a repo partner; use :Pjollrig review", id())
    vim.cmd("tabnew " .. root .. "/a.lua | diffthis | leftabove vsplit " .. tmp .. " | diffthis")
    assert.are.equal("a.lua old", id())
  end)

  it("an ordinary split is not a diff partner (RV-M4)", function()
    left_pane(root, "fugitive://" .. root .. "/.git//0/a.lua", false)
    assert.are.equal("buffer:", P.identity(0).root:match("^buffer:"))
  end)

  it("nvim -d: rev-less old-side comments repaint once 'diff' is on (OptionSet/VimEnter)", function()
    local tmp = H.tmp() .. "/a_LOCAL.lua"
    H.write(tmp, { "zero", "one", "two" })
    require("pjollrig.store").patch(root, {
      { "o1", { path = "a.lua", side = "old", lnum = 2, end_lnum = 2, line = "one", body = "old-side note" } },
    })
    local out = H.tmp() .. "/marks"
    local dump = (
      "au VimEnter * lua vim.defer_fn(function() vim.fn.writefile({vim.json.encode("
      .. "vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(%q), vim.api.nvim_create_namespace('pjollrig'), 0, -1, {}))}, %q)"
      .. " vim.cmd('qa!') end, 100)"
    ):format(tmp, out)
    local r = H.nvim({ "--cmd", dump, "-d", tmp, root .. "/a.lua" }):wait(20000)
    assert.are.equal(0, r.code, r.stderr)
    local m = vim.json.decode(vim.fn.readfile(out)[1])
    assert.are.equal(1, #m)
    assert.are.equal(1, m[1][2]) -- row of "one" in the temp (old) file
  end)

  it("a mid-session :diffthis repaints rev-less old-side comments (OptionSet diff)", function()
    local tmp = H.tmp() .. "/a_LOCAL.lua"
    H.write(tmp, { "zero", "one", "two" })
    require("pjollrig.store").patch(root, {
      { "o1", { path = "a.lua", side = "old", lnum = 2, end_lnum = 2, line = "one", body = "old-side note" } },
    })
    vim.cmd("tabnew " .. root .. "/a.lua | leftabove vsplit " .. tmp)
    local lb = api.nvim_get_current_buf()
    assert.are.equal(0, #H.marks(lb))
    vim.cmd("windo diffthis")
    vim.wait(200, function()
      return #H.marks(lb) > 0
    end, 10)
    assert.are.same(
      { 1 },
      vim.tbl_map(function(m)
        return m[2]
      end, H.marks(lb))
    )
  end)

  it("rev-less old-side comments are text-only (old, unpinned) loclist rows (RV-M4)", function()
    require("pjollrig.store").patch(root, {
      { "o1", { path = "a.lua", side = "old", lnum = 2, end_lnum = 2, line = "  two ", body = "note" } },
    })
    vim.cmd.edit(root .. "/a.lua")
    P.loclist()
    local l = vim.fn.getloclist(0)
    assert.are.same({ 1, 0, 0, "a.lua:2 (old, unpinned) two │ note" }, { #l, l[1].bufnr, l[1].valid, l[1].text })
  end)

  it("bare nvim does not load the plugin at startup", function()
    local out = H.tmp() .. "/loaded"
    local probe = "au VimEnter * lua vim.defer_fn(function() vim.fn.writefile({tostring(package.loaded.pjollrig ~= nil)}, %q)"
      .. " vim.cmd('qa!') end, 50)"
    local r = H.nvim({ "--cmd", probe:format(out) }):wait(20000)
    assert.are.equal(0, r.code, r.stderr)
    assert.are.same({ "false" }, vim.fn.readfile(out))
  end)
end)
