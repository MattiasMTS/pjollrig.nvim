local H = require("helpers")

local ctx

---Fake gh on PATH: emits `json` on stdout and drops a unique marker file
---per invocation so tests can count process spawns.
local function fake_gh(dir, json)
  local bin = dir .. "/bin"
  local markers = dir .. "/markers"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(markers, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    ("mktemp %s/marker.XXXXXX >/dev/null"):format(vim.fn.shellescape(markers)),
    ("echo %s"):format(vim.fn.shellescape(json)),
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return bin, markers
end

describe("pjollrig review completion", function()
  local saved_cwd, saved_path

  before_each(function()
    ctx = H.setup()
    saved_cwd = vim.uv.cwd()
    saved_path = vim.env.PATH
    require("pjollrig.review.complete")._reset()
  end)
  after_each(function()
    vim.cmd.cd(saved_cwd)
    vim.env.PATH = saved_path
    require("pjollrig.review.complete")._reset()
    H.teardown(ctx)
    ctx = nil
  end)

  it("first argument offers local branches, remote branches, and pr", function()
    local C = require("pjollrig.review.complete")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    git("branch", "feature")
    git("update-ref", "refs/remotes/origin/main", vim.trim(git("rev-parse", "HEAD").stdout))
    vim.cmd.cd(root)

    local items = C.candidates("", "PjollrigReview ")
    assert.is_true(vim.tbl_contains(items, "main"))
    assert.is_true(vim.tbl_contains(items, "feature"))
    assert.is_true(vim.tbl_contains(items, "origin/main"))
    assert.is_true(vim.tbl_contains(items, "pr"))
  end)

  it("prefix-filters candidates by arglead", function()
    local C = require("pjollrig.review.complete")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    git("update-ref", "refs/remotes/origin/main", vim.trim(git("rev-parse", "HEAD").stdout))
    vim.cmd.cd(root)

    local items = C.candidates("or", "PjollrigReview or")
    assert.are.same({ "origin/main" }, items)
  end)

  it("pr position completes open PR numbers via gh", function()
    local C = require("pjollrig.review.complete")
    local bin = fake_gh(ctx.artifact_root, '[{"number":123,"title":"x"},{"number":45,"title":"y"}]')
    vim.env.PATH = bin .. ":" .. saved_path

    local items = C.candidates("", "PjollrigReview pr ")
    assert.are.same({ "123", "45" }, items)
  end)

  it("pr position returns {} without error when gh is missing", function()
    local C = require("pjollrig.review.complete")
    local emptybin = ctx.artifact_root .. "/emptybin"
    vim.fn.mkdir(emptybin, "p")
    vim.env.PATH = emptybin

    assert.are.same({}, C.candidates("", "PjollrigReview pr "))
  end)

  it("caches gh results so repeated completion does not re-invoke gh", function()
    local C = require("pjollrig.review.complete")
    local bin, markers = fake_gh(ctx.artifact_root, '[{"number":7,"title":"t"}]')
    vim.env.PATH = bin .. ":" .. saved_path

    assert.are.same({ "7" }, C.candidates("", "PjollrigReview pr "))
    assert.are.same({ "7" }, C.candidates("", "PjollrigReview pr "))
    assert.are.equal(1, #vim.fn.readdir(markers))
  end)

  it(":PjollrigReview delegates completion to the module", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.cmd.cd(root)

    local items = vim.fn.getcompletion("PjollrigReview p", "cmdline")
    assert.is_true(vim.tbl_contains(items, "pr"))
  end)
end)
