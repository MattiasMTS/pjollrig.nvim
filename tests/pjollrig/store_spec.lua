local H = require("helpers")
local S = require("pjollrig.store")

local function workers(root, roles)
  local go = H.tmp() .. "/go"
  local jobs = {}
  for _, r in ipairs(roles) do
    jobs[#jobs + 1] = H.nvim({ "-l", H.plugin .. "/tests/store_worker.lua", go, root, unpack(r) })
  end
  vim.uv.sleep(300)
  vim.fn.writefile({}, go)
  for _, j in ipairs(jobs) do
    local r = j:wait(30000)
    assert.are.equal(0, r.code, r.stderr)
  end
end

describe("store", function()
  before_each(function()
    H.reset()
  end)

  it("concurrent writers into an absent state dir: no lost events, distinct ids (NF-N3 mkdir, N9 ids)", function()
    local root = "/fake/race-add"
    assert.are.equal(0, vim.fn.isdirectory(vim.fs.dirname(S.path(root))))
    workers(root, { { "add", "100" }, { "add", "100" }, { "add", "100" }, { "add", "100" } })
    local pids, n = {}, 0
    for _, r in pairs(S.load(root)) do
      n, pids[r.pid] = n + 1, true
    end
    assert.are.equal(400, n)
    assert.are.equal(4, vim.tbl_count(pids))
  end)

  it(
    "field patches: stale mover, resolver and editor all survive; torn tail is skipped (C-M1, NF-N1, NF-N3)",
    function()
      local root, seed = "/fake/race-patch", {}
      for i = 1, 50 do
        seed[i] = { "s" .. i, { path = "a.lua", side = "new", lnum = 10, end_lnum = 10, line = "x", body = "orig" } }
      end
      S.patch(root, seed)
      workers(root, { { "stale" }, { "resolve", "50" }, { "edit", "50" }, { "torn" } })
      local recs = S.load(root)
      for i = 1, 50 do
        local r = recs["s" .. i]
        assert.are.same({ true, 11, "moved", "edited" }, { r.resolved, r.lnum, r.line, r.body })
      end
      assert.are.equal("survives", recs["after-torn"].body)
    end
  )

  it("list re-reads the log written by another nvim", function()
    local root = H.repo()
    vim.cmd.cd(root)
    local id = S.id()
    S.patch(root, { { id, { path = "a.lua", side = "new", lnum = 1, end_lnum = 1, line = "one", body = "hi" } } })
    assert.are.equal(1, #require("pjollrig").list())
    local fd = vim.uv.fs_open(S.path(root), "a", 420) -- what another nvim's send-ack appends
    vim.uv.fs_write(fd, "\n" .. vim.json.encode({ id = id, at = 1, set = { resolved = true } }))
    vim.uv.fs_close(fd)
    assert.are.equal(0, #require("pjollrig").list())
    assert.are.equal(1, #require("pjollrig").list({ all = true }))
  end)

  it("in-memory roots never touch disk", function()
    S.patch("buffer:7", { { "m1", { body = "x" } } })
    assert.are.equal("x", S.load("buffer:7").m1.body)
    assert.are.equal(0, vim.fn.isdirectory(vim.fn.stdpath("state") .. "/pjollrig"))
  end)
end)
