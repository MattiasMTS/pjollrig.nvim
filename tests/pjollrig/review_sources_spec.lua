local H = require("helpers")
local ctx

describe("pjollrig review sources", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("resolves a bare invocation to HEAD-vs-worktree", function()
    local S = require("pjollrig.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    local job = assert(S.resolve({}, { cwd = root, stage_dir = ctx.artifact_root .. "/s1" }))
    assert.are.equal("HEAD", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal(root .. "/a.lua", job.files[1].right)
  end)

  it("resolves a branch name via merge-base (only your changes)", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")
    git("checkout", "-q", "main")
    vim.fn.writefile({ "-- main moved" }, root .. "/main-only.lua")
    git("add", "main-only.lua")
    git("commit", "-qm", "main work")
    git("checkout", "-q", "feature")
    local job = assert(S.resolve({ "main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s2" }))
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
  end)

  it("resolves two directories without git", function()
    local S = require("pjollrig.review.sources")
    local left, right = ctx.artifact_root .. "/L", ctx.artifact_root .. "/R"
    vim.fn.mkdir(left .. "/sub", "p")
    vim.fn.mkdir(right .. "/sub", "p")
    vim.fn.writefile({ "old" }, left .. "/sub/m.txt")
    vim.fn.writefile({ "new" }, right .. "/sub/m.txt")
    vim.fn.writefile({ "same" }, left .. "/same.txt")
    vim.fn.writefile({ "same" }, right .. "/same.txt")
    vim.fn.writefile({ "gone" }, left .. "/gone.txt")
    vim.fn.writefile({ "added" }, right .. "/added.txt")
    local job = assert(S.resolve({ left, right }, {}))
    local by_path = {}
    for _, pair in ipairs(job.files) do
      by_path[pair.path] = pair.status
    end
    assert.are.equal("M", by_path["sub/m.txt"])
    assert.are.equal("D", by_path["gone.txt"])
    assert.are.equal("A", by_path["added.txt"])
    assert.is_nil(by_path["same.txt"])
    for _, dir in ipairs(job.stage_dirs or {}) do
      vim.fn.delete(dir, "rf")
    end
  end)

  it("dirs resolver never walks or diffs .git subtrees", function()
    local S = require("pjollrig.review.sources")
    local left, right = ctx.artifact_root .. "/GL", ctx.artifact_root .. "/GR"
    for _, dir in ipairs({ left, right }) do
      vim.fn.mkdir(dir .. "/.git/objects", "p")
      vim.fn.mkdir(dir .. "/sub/.git", "p")
    end
    vim.fn.writefile({ "ref: refs/heads/a" }, left .. "/.git/HEAD")
    vim.fn.writefile({ "ref: refs/heads/b" }, right .. "/.git/HEAD")
    vim.fn.writefile({ "L" }, left .. "/.git/objects/pack")
    vim.fn.writefile({ "RR" }, right .. "/.git/objects/pack")
    vim.fn.writefile({ "left only" }, left .. "/sub/.git/config")
    vim.fn.writefile({ "old" }, left .. "/sub/code.lua")
    vim.fn.writefile({ "new!" }, right .. "/sub/code.lua")
    local job = assert(S.resolve({ left, right }, {}))
    assert.are.equal(1, #job.files)
    assert.are.equal("sub/code.lua", job.files[1].path)
  end)

  it("dirs resolver stages every right-only file under one owned dir", function()
    local S = require("pjollrig.review.sources")
    local left, right = ctx.artifact_root .. "/SL", ctx.artifact_root .. "/SR"
    vim.fn.mkdir(left, "p")
    vim.fn.mkdir(right .. "/sub", "p")
    vim.fn.writefile({ "one" }, right .. "/one.lua")
    vim.fn.writefile({ "two" }, right .. "/sub/two.lua")
    local job = assert(S.resolve({ left, right }, {}))
    assert.are.equal(2, #job.files)
    assert.are.equal("table", type(job.stage_dirs))
    assert.are.equal(1, #job.stage_dirs)
    local dir = job.stage_dirs[1]
    assert.are.equal(1, vim.fn.isdirectory(dir))
    for _, pair in ipairs(job.files) do
      assert.are.equal("A", pair.status)
      assert.are.equal(dir, pair.left:sub(1, #dir))
    end
    vim.fn.delete(dir, "rf")
  end)

  it("dirs resolver reports no stage dirs when nothing needed staging", function()
    local S = require("pjollrig.review.sources")
    local left, right = ctx.artifact_root .. "/NL", ctx.artifact_root .. "/NR"
    vim.fn.mkdir(left, "p")
    vim.fn.mkdir(right, "p")
    vim.fn.writefile({ "old" }, left .. "/m.txt")
    vim.fn.writefile({ "new" }, right .. "/m.txt")
    local job = assert(S.resolve({ left, right }, {}))
    assert.are.equal(1, #job.files)
    assert.is_nil(job.stage_dirs)
  end)

  it("git resolver owns its stage dir only when it created it", function()
    local S = require("pjollrig.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    local provided = assert(S.resolve({}, { cwd = root, stage_dir = ctx.artifact_root .. "/prov" }))
    assert.is_nil(provided.stage_dirs)
    local owned = assert(S.resolve({}, { cwd = root }))
    assert.are.equal("table", type(owned.stage_dirs))
    assert.are.equal(1, #owned.stage_dirs)
    assert.are.equal(1, vim.fn.isdirectory(owned.stage_dirs[1]))
    assert.are.equal(1, owned.files[1].left:find(owned.stage_dirs[1], 1, true))
    vim.fn.delete(owned.stage_dirs[1], "rf")
  end)

  it("resolves a remote-tracking ref via merge-base", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    git("update-ref", "refs/remotes/origin/main", vim.trim(git("rev-parse", "HEAD").stdout))
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")
    local job = assert(S.resolve({ "origin/main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s4" }))
    assert.are.equal("origin/main", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
  end)

  it("errors outside a git repo for ref arguments", function()
    local job, err = require("pjollrig.review.sources").resolve({ "main" }, { cwd = ctx.artifact_root })
    assert.is_nil(job)
    assert.is_truthy(err)
  end)

  it("does not reserve pr or chat as builtin resolver keywords", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    git("branch", "pr")
    git("branch", "chat")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    for _, ref in ipairs({ "pr", "chat" }) do
      local job = assert(S.resolve({ ref }, { cwd = root, stage_dir = ctx.artifact_root .. "/" .. ref }))
      assert.are.equal(ref, job.label)
      assert.are.equal(1, #job.files)
      local unsupported, err = S.resolve({ ref, "1" }, { cwd = root })
      assert.is_nil(unsupported)
      assert.is_truthy(err:find("cannot resolve", 1, true))
    end
  end)
end)

describe("pjollrig review source registration", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("register() validates the resolver shape", function()
    local S = require("pjollrig.review.sources")
    local ok, err = pcall(S.register, { match = function() end, resolve = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("name", 1, true))
    ok, err = pcall(S.register, { name = "x", match = "not a function", resolve = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("match", 1, true))
    ok, err = pcall(S.register, { name = "x", match = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("resolve", 1, true))
    assert.is_false(pcall(S.register, nil))
  end)

  it("pjollrig.register_review_source registers a resolver that shadows builtins", function()
    local marker = "hub-spec-" .. tostring(math.random(1e6))
    require("pjollrig").register_review_source({
      name = "hub-spec",
      match = function(fargs)
        return fargs[1] == marker
      end,
      resolve = function()
        return { files = { { left = "/l", right = "/r", status = "M", path = "r" } }, label = "hub-spec" }
      end,
    })
    local job = assert(require("pjollrig.review.sources").resolve({ marker }, {}))
    assert.are.equal("hub-spec", job.label)
  end)
end)
