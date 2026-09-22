-- Async review start: the begin/attach split behind `:PjollrigReview`.
--
-- review.start_async opens the shell (tab + panel with a resolving
-- placeholder) within the caller's frame and attaches the resolver's
-- job from its callback. These specs drive that lifecycle
-- deterministically through CAPTURED resolver callbacks (a registered
-- resolver whose resolve_async stashes `cb` instead of finishing), so
-- pending/stale/supersede states need no sleeping subprocesses. The
-- registry is process-global with no reset, so each resolver matches
-- only its own unique marker (the review_sources_spec pattern).

local H = require("helpers")

local ctx

local function make_pairs(n)
  local files = {}
  for i = 1, n do
    local left = ctx.artifact_root .. ("/left/f%d.lua"):format(i)
    local right = ctx.root .. ("/f%d.lua"):format(i)
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ ("return %d -- old"):format(i) }, left)
    vim.fn.writefile({ ("return %d -- new"):format(i) }, right)
    files[i] = { left = left, right = right, status = "M", path = ("f%d.lua"):format(i) }
  end
  return files
end

local function panel()
  return require("pjollrig.review.panel")
end

local function panel_lines()
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---Register a capture resolver for `marker`: start_async({marker}) parks
---its resolve callback in the returned list instead of finishing.
local function register_capture(marker)
  local captured = {}
  require("pjollrig.review.sources").register({
    name = "capture-" .. marker,
    match = function(fargs)
      return fargs[1] == marker
    end,
    resolve = function()
      return nil, "sync resolve must not run in async specs"
    end,
    resolve_async = function(_fargs, _opts, cb)
      captured[#captured + 1] = cb
    end,
  })
  return captured
end

local function unique_marker()
  return "async-spec-" .. tostring(math.random(1e9))
end

describe("pjollrig review start_async", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("opens the resolving shell immediately and attaches from the callback", function()
    local R = require("pjollrig.review")
    local marker = unique_marker()
    local captured = register_capture(marker)
    local tabs_before = #vim.api.nvim_list_tabpages()

    R.start_async({ marker })

    -- Shell open within the same frame: session in resolving state, a
    -- fresh tab, the panel showing the spinner placeholder row, ticker
    -- running.
    local state = assert(R.state(), "no session after start_async")
    assert.is_true(state.resolving)
    assert.are.equal(0, #state.files)
    assert.are.equal(tabs_before + 1, #vim.api.nvim_list_tabpages())
    assert.is_true(panel().is_open(), "panel not open while resolving")
    local lines = panel_lines()
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("resolving " .. marker, 1, true), "placeholder row missing: " .. lines[1])
    assert.is_true(panel()._spinner_active(), "spinner ticker not running while resolving")
    -- The Files tab is the busy one; the right side reports resolving.
    local winbar = vim.wo[assert(panel().winid())].winbar
    assert.is_truthy(winbar:find("resolving", 1, true), "busy winbar missing: " .. winbar)

    -- Resolver lands: the job attaches, the first pair opens, the
    -- placeholder is gone.
    assert.are.equal(1, #captured, "resolver callback not captured")
    captured[1]({ files = make_pairs(2), label = "attached" })

    state = assert(R.state())
    assert.is_nil(state.resolving)
    assert.are.equal("attached", state.label)
    assert.are.equal(2, #state.files)
    assert.are.equal(state.files[1].right, vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    lines = panel_lines()
    assert.are.equal(2, #lines)
    assert.is_truthy(lines[1]:find("f1.lua", 1, true))
  end)

  it("stop() during resolve tears the shell down; the stale callback only cleans up", function()
    local R = require("pjollrig.review")
    local marker = unique_marker()
    local captured = register_capture(marker)
    local tabs_before = #vim.api.nvim_list_tabpages()

    R.start_async({ marker })
    assert.is_truthy(R.state())
    assert.is_true(R.stop())

    -- No session, no extra tab, no panel, no ticker.
    assert.is_nil(R.state())
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.is_false(panel().is_open())
    assert.is_false(panel()._spinner_active())

    -- The resolve completes AFTER the stop: its staged output has no
    -- owner anymore, so the stale callback deletes it and attaches
    -- nothing.
    local stage = ctx.artifact_root .. "/stale-stage"
    vim.fn.mkdir(stage, "p")
    captured[1]({ files = make_pairs(1), label = "stale", stage_dirs = { stage } })
    assert.is_nil(R.state(), "stale resolve attached after stop()")
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.are.equal(0, vim.fn.isdirectory(stage), "stale resolve leaked its stage dir")
  end)

  it("a second start_async supersedes: the older resolve cannot attach", function()
    local R = require("pjollrig.review")
    local marker_a = unique_marker()
    local marker_b = unique_marker()
    local captured_a = register_capture(marker_a)
    local captured_b = register_capture(marker_b)

    R.start_async({ marker_a })
    R.start_async({ marker_b }) -- supersedes: stops A's shell, opens B's

    local stage_a = ctx.artifact_root .. "/superseded-stage"
    vim.fn.mkdir(stage_a, "p")
    captured_a[1]({ files = make_pairs(1), label = "job-a", stage_dirs = { stage_a } })

    -- A's late job must not land on B's resolving session.
    local state = assert(R.state())
    assert.is_true(state.resolving, "stale resolve attached to the superseding session")
    assert.are.equal(0, vim.fn.isdirectory(stage_a), "superseded resolve leaked its stage dir")

    captured_b[1]({ files = make_pairs(2), label = "job-b" })
    state = assert(R.state())
    assert.is_nil(state.resolving)
    assert.are.equal("job-b", state.label)
    assert.are.equal(2, #state.files)
  end)

  it("a late resolver error notifies ERROR and closes the shell", function()
    local R = require("pjollrig.review")
    local marker = unique_marker()
    local captured = register_capture(marker)
    local tabs_before = #vim.api.nvim_list_tabpages()

    R.start_async({ marker })
    assert.is_truthy(R.state())

    local err_msg
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        err_msg = tostring(msg)
      end
    end
    captured[1](nil, "pjollrig: boom")
    vim.notify = original_notify

    assert.are.equal("pjollrig: boom", err_msg)
    assert.is_nil(R.state(), "failed resolve left a session behind")
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.is_false(panel().is_open())
  end)

  it("navigation and finish are safe no-ops while resolving", function()
    local R = require("pjollrig.review")
    local marker = unique_marker()
    register_capture(marker)

    R.start_async({ marker })
    R.next()
    R.prev()
    R.open_pair(1)
    local ok, err = R.finish({ sink = "does-not-matter" })
    assert.is_false(ok)
    assert.is_truthy(err:find("no comments", 1, true))
    assert.is_true(R.state().resolving, "no-ops disturbed the resolving session")
  end)
end)

describe("pjollrig sources.resolve_async", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("never fires its callback in the caller's frame and stages a git job", function()
    local S = require("pjollrig.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")

    local fired = false
    local job, err
    S.resolve_async({}, { cwd = root, stage_dir = ctx.artifact_root .. "/as1" }, function(j, e)
      job, err, fired = j, e, true
    end)
    assert.is_false(fired, "resolve_async completed synchronously")
    vim.wait(10000, function()
      return fired
    end, 10)

    assert.is_true(fired, "resolve_async never called back")
    assert.is_nil(err)
    assert.are.equal("HEAD", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal("return 1", table.concat(vim.fn.readfile(job.files[1].left), "\n"))
  end)

  it("delivers failures asynchronously too", function()
    local S = require("pjollrig.review.sources")
    local fired = false
    local job, err
    -- Not a repo, not directories: the git resolver fails.
    S.resolve_async({ "no-such-ref" }, { cwd = ctx.artifact_root }, function(j, e)
      job, err, fired = j, e, true
    end)
    assert.is_false(fired, "failure callback fired synchronously")
    vim.wait(5000, function()
      return fired
    end, 10)
    assert.is_nil(job)
    assert.is_truthy(err)
  end)

  it("runs a sync-only registered resolver in a scheduled step", function()
    local S = require("pjollrig.review.sources")
    local marker = "sync-only-" .. tostring(math.random(1e9))
    S.register({
      name = marker,
      match = function(fargs)
        return fargs[1] == marker
      end,
      resolve = function()
        return { files = { { left = "/l", right = "/r", status = "M", path = "r" } }, label = marker }
      end,
    })
    local fired = false
    local job
    S.resolve_async({ marker }, {}, function(j)
      job, fired = j, true
    end)
    assert.is_false(fired, "sync resolver ran inside the caller's frame")
    vim.wait(1000, function()
      return fired
    end, 5)
    assert.are.equal(marker, job.label)
  end)
end)
