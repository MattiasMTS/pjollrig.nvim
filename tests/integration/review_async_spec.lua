-- :PjollrigReview end-to-end latency: the command returns within a
-- frame while SLOW subprocesses (a sleeping git/gh wrapper on PATH)
-- resolve in the background, and the PR comment import lands AFTER the
-- session is already on screen.

local H = require("helpers")

local ctx

local function panel()
  return require("pjollrig.review.panel")
end

local function panel_lines()
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function wait_attached(timeout)
  local R = require("pjollrig.review")
  vim.wait(timeout or 20000, function()
    local s = R.state()
    return s ~= nil and not s.resolving
  end, 10)
  local s = R.state()
  assert.is_truthy(s, "review session never attached (resolve failed?)")
  assert.is_nil(s.resolving, "review session still resolving")
end

---A `git` wrapper on PATH that sleeps before delegating to the real
---binary — every resolver subprocess costs at least `seconds`.
local function slow_git(seconds)
  local bin = ctx.artifact_root .. "/slowbin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({
    "#!/bin/sh",
    ("sleep %s"):format(seconds),
    ('exec %s "$@"'):format(vim.fn.shellescape(vim.fn.exepath("git"))),
  }, bin .. "/git")
  vim.fn.system({ "chmod", "+x", bin .. "/git" })
  return bin
end

describe(":PjollrigReview async command", function()
  local saved_path
  local saved_cwd

  before_each(function()
    ctx = H.setup()
    saved_path = vim.env.PATH
    saved_cwd = vim.uv.cwd()
    vim.cmd("runtime plugin/pjollrig.lua")
  end)
  after_each(function()
    vim.env.PATH = saved_path
    pcall(vim.cmd.cd, saved_cwd)
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("returns within a frame while a slow git resolves in the background", function()
    local root = H.git_repo(ctx, { ["slow.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/slow.lua")
    -- Wrapper installed AFTER the repo is built (H.git_repo shells out
    -- to the real git via PATH).
    vim.env.PATH = slow_git("0.3") .. ":" .. saved_path
    vim.cmd.cd(root)

    local start = vim.uv.hrtime()
    vim.cmd("PjollrigReview HEAD")
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    -- One blocked git call alone would cost >= 300ms.
    assert.is_true(elapsed_ms < 250, ("command blocked for %.0fms"):format(elapsed_ms))

    -- The shell is already up: resolving session, spinner row, ticker.
    local R = require("pjollrig.review")
    local state = assert(R.state(), "no session right after the command")
    assert.is_true(state.resolving)
    assert.is_true(panel().is_open(), "panel not open while resolving")
    assert.is_truthy(panel_lines()[1]:find("resolving HEAD", 1, true), "placeholder row missing")
    assert.is_true(panel()._spinner_active())

    wait_attached()
    state = assert(R.state())
    assert.are.equal("HEAD", state.label)
    assert.are.equal(1, #state.files)
    assert.are.equal("slow.lua", state.files[1].path)
    -- The first pair is on screen (worktree side focused).
    assert.are.equal(state.files[1].right, vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    assert.is_truthy(panel_lines()[1]:find("slow.lua", 1, true))
  end)

  it("pr flow: the session opens before the comment import lands", function()
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1", "-- two" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "return 2", "-- two" }, root .. "/a.lua")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)

    -- gh whose metadata endpoints answer fast but whose comment/thread
    -- API sleeps: the import MUST NOT hold the session closed.
    local home = ctx.artifact_root .. "/gh-slow"
    local bin = home .. "/bin"
    vim.fn.mkdir(bin, "p")
    vim.fn.writefile({
      vim.json.encode({
        {
          id = 7001,
          path = "a.lua",
          line = 2,
          body = "late comment",
          html_url = "https://example.test/r/7001",
          user = { login = "octocat" },
        },
      }),
    }, home .. "/comments.json")
    vim.fn.writefile({
      vim.json.encode({ data = { repository = { pullRequest = { reviewThreads = { nodes = {} } } } } }),
    }, home .. "/threads.json")
    vim.fn.writefile({
      "#!/bin/sh",
      "dir=" .. vim.fn.shellescape(home),
      'if [ "$1 $2" = "pr view" ]; then',
      ('  echo \'{"baseRefOid":"%s","headRefOid":"%s","title":"Slow import"}\';'):format(base_oid, head_oid),
      'elif [ "$1 $2" = "repo view" ]; then',
      '  echo \'{"nameWithOwner":"acme/widgets"}\';',
      'elif [ "$1 $2" = "api graphql" ]; then',
      "  sleep 0.5;",
      '  cat "$dir/threads.json";',
      'elif [ "$1" = "api" ]; then',
      "  sleep 0.5;",
      "  printf '['; cat \"$dir/comments.json\"; printf ']';",
      "else",
      "  exit 2;",
      "fi",
    }, bin .. "/gh")
    vim.fn.system({ "chmod", "+x", bin .. "/gh" })
    vim.env.PATH = bin .. ":" .. saved_path
    vim.cmd.cd(root)

    vim.cmd("PjollrigReview pr 42")
    wait_attached()

    -- Attached with the pair on screen, import still in flight.
    local R = require("pjollrig.review")
    local state = assert(R.state())
    assert.are.equal("pr 42: Slow import", state.label)
    assert.are.equal(1, #state.files)
    local store = require("pjollrig.store")
    assert.are.equal(0, #store.all(root), "import blocked the session open")

    -- The comments backfill once the sleeping endpoints answer, and the
    -- panel's refresh picks the count up.
    vim.wait(15000, function()
      return #store.all(root) == 1
    end, 20)
    assert.are.equal(1, #store.all(root))
    assert.are.equal("late comment", store.all(root)[1].body)
    vim.wait(2000, function()
      local line = panel_lines()[1] or ""
      return line:find("1 comments", 1, true) ~= nil
    end, 20)
    assert.is_truthy(panel_lines()[1]:find("1 comments", 1, true), "panel never reconciled the imported comment")
  end)

  it("a failing resolve notifies ERROR and closes the shell", function()
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.cmd.cd(root)
    local tabs_before = #vim.api.nvim_list_tabpages()

    local err_msg
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        err_msg = tostring(msg)
      end
    end
    vim.cmd("PjollrigReview no-such-ref-anywhere")
    vim.wait(10000, function()
      return err_msg ~= nil
    end, 10)
    vim.notify = original_notify

    assert.is_truthy(err_msg, "resolve failure never notified")
    assert.is_truthy(err_msg:find("no%-such%-ref%-anywhere") or err_msg:find("merge%-base"), err_msg)
    assert.is_nil(require("pjollrig.review").state(), "failed resolve left a session")
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.is_false(panel().is_open())
  end)

  it(":PjollrigReviewStop during a slow resolve leaves nothing behind", function()
    local root = H.git_repo(ctx, { ["s.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/s.lua")
    vim.env.PATH = slow_git("0.4") .. ":" .. saved_path
    vim.cmd.cd(root)
    local tabs_before = #vim.api.nvim_list_tabpages()

    vim.cmd("PjollrigReview HEAD")
    local R = require("pjollrig.review")
    assert.is_true(assert(R.state()).resolving)
    vim.cmd("PjollrigReviewStop")

    assert.is_nil(R.state())
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.is_false(panel().is_open())
    assert.is_false(panel()._spinner_active())

    -- Let the orphaned resolve land (a handful of 0.4s-delayed git
    -- calls): still no session, no tab — the stale callback only
    -- cleans up after itself.
    vim.wait(4000, function()
      return false
    end, 200)
    assert.is_nil(R.state(), "stale resolve attached after :PjollrigReviewStop")
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
  end)
end)
