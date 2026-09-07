local H = require("helpers")

local ctx
local saved_path

local function panel()
  return require("pjollrig.review.panel")
end

local function checks()
  return require("pjollrig.review.tabs.checks")
end

---Fake `gh` on PATH: logs every invocation's argv to calls.log and cats
---a controllable output.json (or fails when the `fail` marker exists).
---The checks tab trusts parseable stdout over the exit code — `gh pr
---checks` exits non-zero for failing checks — so the fake always exits 0
---unless failing outright.
local function fake_gh(output)
  local home = ctx.artifact_root .. "/gh-checks"
  local bin = home .. "/bin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ output or "[]" }, home .. "/output.json")
  vim.fn.writefile({}, home .. "/calls.log")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'echo "$@" >> "$dir/calls.log"',
    'if [ -f "$dir/slow" ]; then sleep 1; fi',
    'if [ -f "$dir/fail" ]; then echo "gh: kaboom" >&2; exit 1; fi',
    'cat "$dir/output.json"',
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  vim.env.PATH = bin .. ":" .. saved_path
  return {
    set_output = function(json)
      vim.fn.writefile({ json }, home .. "/output.json")
    end,
    set_fail = function()
      vim.fn.writefile({ "" }, home .. "/fail")
    end,
    set_slow = function()
      vim.fn.writefile({ "" }, home .. "/slow")
    end,
    calls = function()
      return vim.fn.readfile(home .. "/calls.log")
    end,
  }
end

local function make_pairs(n, root)
  root = root or ctx.root
  local files = {}
  for i = 1, n do
    local left = ctx.artifact_root .. ("/left/f%d.lua"):format(i)
    local right = root .. ("/f%d.lua"):format(i)
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ ("return %d -- old"):format(i) }, left)
    vim.fn.writefile({ ("return %d -- new"):format(i) }, right)
    files[i] = { left = left, right = right, status = "M", path = ("f%d.lua"):format(i) }
  end
  return files
end

---Start a review session; `opts.pr` sets ctx.pr, `opts.root`
---relocates the worktree files (branch-upstream tests).
local function start_review(opts)
  opts = opts or {}
  assert.is_true(require("pjollrig.review").start({
    files = make_pairs(1, opts.root),
    label = "checks",
    ctx = opts.pr and { pr = opts.pr } or nil,
  }))
end

local function panel_lines()
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function winbar()
  return vim.wo[assert(panel().winid(), "panel window not open")].winbar
end

---Press `lhs` in the panel window on `row` THROUGH buffer-local maps.
local function press_in_panel(row, lhs)
  local winid = assert(panel().winid(), "panel window not open")
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "x", false)
end

---Enter the checks tab (files -> comments -> checks) and wait for the
---async fetch to replace the loading row (which may carry a spinner
---frame prefix while the ticker runs).
local function enter_checks_tab()
  press_in_panel(1, "L")
  press_in_panel(1, "L")
  vim.wait(2000, function()
    return not panel_lines()[1]:find("fetching checks", 1, true)
  end, 10)
end

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---Is `glyph` a spinner frame (or the static ● fallback)? All candidates
---are 3-byte UTF-8, so rows can be split as text:sub(1, 3).
local function is_running_glyph(glyph)
  if glyph == "\u{25CF}" then
    return true
  end
  for _, frame in ipairs(SPINNER_FRAMES) do
    if frame == glyph then
      return true
    end
  end
  return false
end

---Content extmarks on `row` (0-indexed) using highlight group `hl`.
local function span_marks(row, hl)
  local ns = vim.api.nvim_create_namespace("pjollrig.review.panel")
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    if mark[2] == row and mark[4].hl_group == hl then
      table.insert(found, mark)
    end
  end
  return found
end

---A git repo whose current branch (main) has an upstream, without any
---network: a self-pointing remote plus a remote-tracking ref.
local function repo_with_upstream()
  local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
  git("remote", "add", "origin", ".")
  git("update-ref", "refs/remotes/origin/main", vim.trim(git("rev-parse", "HEAD").stdout))
  git("branch", "-q", "--set-upstream-to=origin/main", "main")
  return root, git
end

local PR_CHECKS = vim.json.encode({
  {
    name = "build",
    state = "SUCCESS",
    link = "https://example.test/runs/2",
    startedAt = "2024-01-01T00:00:00Z",
    completedAt = "2024-01-01T00:00:18Z",
  },
  {
    name = "lint-test (ubuntu, nightly)",
    state = "FAILURE",
    link = "https://example.test/runs/1",
    startedAt = "2024-01-01T00:00:00Z",
    completedAt = "2024-01-01T00:01:48Z",
  },
  { name = "docs", state = "SKIPPED", link = "https://example.test/runs/4" },
  { name = "deploy", state = "IN_PROGRESS", link = "https://example.test/runs/3" },
})

local ALL_PASS = vim.json.encode({
  {
    name = "build",
    state = "SUCCESS",
    link = "https://example.test/runs/2",
    startedAt = "2024-01-01T00:00:00Z",
    completedAt = "2024-01-01T00:00:18Z",
  },
  {
    name = "lint",
    state = "SUCCESS",
    link = "https://example.test/runs/1",
    startedAt = "2024-01-01T00:00:00Z",
    completedAt = "2024-01-01T00:02:14Z",
  },
})

local FOOTER = "<CR> open in browser \u{00B7} R refresh"

describe("pjollrig checks panel tab", function()
  before_each(function()
    ctx = H.setup()
    saved_path = vim.env.PATH
    -- Flip the loader's once-per-process guard so the panel's own
    -- tabs.setup() on open cannot re-register the builtin tabs and
    -- collide with the explicit registration below (pcall: the sibling
    -- github tab module is not under test here).
    pcall(function()
      require("pjollrig.review.tabs").setup()
    end)
    panel()._reset_tabs()
    checks().setup()
  end)
  after_each(function()
    vim.env.PATH = saved_path
    pcall(function()
      require("pjollrig.review").stop()
    end)
    panel()._reset_tabs()
    H.teardown(ctx)
    ctx = nil
  end)

  describe("availability", function()
    it("offers the tab for a PR session when gh is executable", function()
      fake_gh()
      start_review({ pr = 42 })
      assert.is_truthy(winbar():find("Checks", 1, true), winbar())
    end)

    it("hides the tab when gh is not executable, even for a PR session", function()
      -- The tab resolves gh through `sinks.github.command` (the github
      -- sink's knob); pointing it at a missing file makes gh
      -- deterministically non-executable regardless of the host PATH.
      require("pjollrig.config").get().sinks.github = { command = ctx.artifact_root .. "/no-such-gh" }
      start_review({ pr = 42 })
      assert.is_nil(winbar():find("Checks", 1, true), winbar())
    end)

    it("hides the tab without a PR when the branch has no upstream", function()
      fake_gh()
      start_review() -- ctx.root has a bare .git dir: no repo, no upstream
      assert.is_nil(winbar():find("Checks", 1, true), winbar())
    end)

    it("offers the tab without a PR when the branch has an upstream", function()
      fake_gh()
      local root = repo_with_upstream()
      start_review({ root = root })
      assert.is_truthy(winbar():find("Checks", 1, true), winbar())
    end)
  end)

  describe("fetch and render", function()
    it("renders rows sorted fail > running > pass > skipped with glyph spans", function()
      local gh = fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()

      -- The running row's glyph is a live spinner frame (● fallback),
      -- so it is asserted separately from the static rows.
      local rows = panel_lines()
      assert.are.equal("\u{2717} lint-test (ubuntu, nightly)  1m 48s", rows[1])
      assert.is_true(is_running_glyph(rows[2]:sub(1, 3)), rows[2])
      assert.are.equal(" deploy", rows[2]:sub(4))
      assert.are.equal("\u{2713} build  18s", rows[3])
      assert.are.equal("\u{25CB} docs", rows[4])
      assert.are.equal(FOOTER, rows[5])

      -- One gh call, against the session's PR.
      assert.are.same({ "pr checks 42 --json name,state,link,startedAt,completedAt" }, gh.calls())

      -- Glyph spans: fail/ok/running accent/skipped dim; elapsed dim.
      local lines = panel_lines()
      local fail = span_marks(0, "DiagnosticError")
      assert.are.equal(1, #fail)
      assert.are.equal("\u{2717}", lines[1]:sub(fail[1][3] + 1, fail[1][4].end_col))
      assert.are.equal(1, #span_marks(1, "DiagnosticInfo"))
      assert.are.equal(1, #span_marks(2, "DiagnosticOk"))
      assert.are.equal(1, #span_marks(3, "Comment"))
      local elapsed = span_marks(0, "Comment")
      assert.are.equal(1, #elapsed)
      assert.are.equal("1m 48s", lines[1]:sub(elapsed[1][3] + 1, elapsed[1][4].end_col))
      -- The footer row renders dim.
      assert.are.equal(1, #span_marks(4, "Comment"))
    end)

    it("titles Checks before the fetch, Checks ✗ with a failure, and passed/total otherwise", function()
      fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      -- Checks is the last tab, so a bare pre-fetch title abuts the
      -- winbar's right-align separator.
      assert.is_truthy(winbar():find("Checks%=", 1, true), winbar())

      enter_checks_tab()
      assert.is_truthy(winbar():find("Checks \u{2717}", 1, true), winbar())
    end)

    it("titles passed/total when nothing failed", function()
      fake_gh(ALL_PASS)
      start_review({ pr = 42 })
      enter_checks_tab()
      assert.is_truthy(winbar():find("Checks 2/2", 1, true), winbar())
    end)

    it("renders a dim error row and stays usable when gh fails", function()
      local gh = fake_gh()
      gh.set_fail()
      start_review({ pr = 42 })
      enter_checks_tab()

      assert.are.same({ "gh: kaboom", FOOTER }, panel_lines())
      assert.are.equal(1, #span_marks(0, "Comment"))
      assert.is_truthy(winbar():find("%#PjollrigPanelTabActive#Checks", 1, true), winbar())

      -- Usable: R retries after the failure clears.
      gh.set_output(ALL_PASS)
      vim.fn.delete(ctx.artifact_root .. "/gh-checks/fail")
      press_in_panel(1, "R")
      vim.wait(2000, function()
        return #panel_lines() == 3
      end, 10)
      assert.are.equal("\u{2713} build  18s", panel_lines()[1])
    end)

    it("renders the empty state for a PR with no checks", function()
      fake_gh("[]")
      start_review({ pr = 42 })
      enter_checks_tab()

      assert.are.same({ "no checks found", FOOTER }, panel_lines())
      assert.are.equal(1, #span_marks(0, "Comment"))
      -- No count in the title when there is nothing to count: the bare
      -- label still abuts the right-align separator.
      assert.is_truthy(winbar():find("Checks%=", 1, true), winbar())
    end)

    it("fetches gh run list for the upstream branch on non-PR sessions", function()
      local gh = fake_gh(vim.json.encode({
        {
          name = "nightly",
          status = "in_progress",
          conclusion = "",
          url = "https://example.test/actions/2",
        },
        {
          name = "ci",
          status = "completed",
          conclusion = "failure",
          url = "https://example.test/actions/1",
          startedAt = "2024-01-01T00:00:00Z",
          updatedAt = "2024-01-01T00:00:40Z",
        },
        {
          name = "docs",
          status = "completed",
          conclusion = "success",
          url = "https://example.test/actions/3",
          startedAt = "2024-01-01T00:00:00Z",
          updatedAt = "2024-01-01T00:00:05Z",
        },
        {
          name = "optional",
          status = "completed",
          conclusion = "skipped",
          url = "https://example.test/actions/4",
        },
      }))
      local root = repo_with_upstream()
      start_review({ root = root })
      enter_checks_tab()

      local rows = panel_lines()
      assert.are.equal("\u{2717} ci  40s", rows[1])
      assert.is_true(is_running_glyph(rows[2]:sub(1, 3)), rows[2])
      assert.are.equal(" nightly", rows[2]:sub(4))
      assert.are.equal("\u{2713} docs  5s", rows[3])
      assert.are.equal("\u{25CB} optional", rows[4])
      assert.are.equal(FOOTER, rows[5])
      assert.are.same({
        "run list --branch main --json name,status,conclusion,url,startedAt,updatedAt --limit 30",
      }, gh.calls())
    end)
  end)

  describe("prefetch and live updates", function()
    it("prefetches at session open: gh runs before the tab is entered", function()
      local gh = fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      vim.wait(2000, function()
        return #gh.calls() == 1
      end, 10)
      assert.are.same({ "pr checks 42 --json name,state,link,startedAt,completedAt" }, gh.calls())
      -- The landed fetch decorates the title while Files is still current.
      vim.wait(2000, function()
        return winbar():find("Checks \u{2717}", 1, true) ~= nil
      end, 10)
      assert.is_truthy(winbar():find("Checks \u{2717}", 1, true), winbar())
      assert.is_truthy(winbar():find("%#PjollrigPanelTabActive#Files", 1, true), winbar())
    end)

    it("review.panel.prefetch = false keeps the fetch lazy", function()
      local gh = fake_gh(PR_CHECKS)
      require("pjollrig.config").get().review.panel.prefetch = false
      start_review({ pr = 42 })
      vim.wait(300)
      assert.are.equal(0, #gh.calls(), "prefetch fired despite review.panel.prefetch = false")
      enter_checks_tab()
      assert.are.equal(1, #gh.calls())
    end)

    it("animates running rows: braille frame and a live elapsed counter", function()
      local started = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 5)
      fake_gh(vim.json.encode({
        { name = "deploy", state = "IN_PROGRESS", link = "https://example.test/runs/3", startedAt = started },
      }))
      start_review({ pr = 42 })
      enter_checks_tab()

      local function glyph()
        return panel_lines()[1]:sub(1, 3)
      end
      local function seconds()
        return tonumber(panel_lines()[1]:match("running (%d+)s"))
      end
      local line = panel_lines()[1]
      assert.is_truthy(line:find(" deploy  running ", 1, true), line)
      assert.is_true(is_running_glyph(glyph()), line)
      assert.are_not.equal("\u{25CF}", glyph(), "running glyph is the static fallback, not a frame")

      -- The frame advances across ticks...
      local first_glyph = glyph()
      vim.wait(2000, function()
        return glyph() ~= first_glyph
      end, 10)
      assert.are_not.equal(first_glyph, glyph(), "frame did not advance")

      -- ...and the elapsed counter is recomputed per build, so it ticks.
      local first_seconds = assert(seconds(), panel_lines()[1])
      vim.wait(3000, function()
        return seconds() ~= first_seconds
      end, 50)
      assert.is_true((seconds() or 0) > first_seconds, "elapsed counter froze")
    end)

    it("the loading row carries a spinner frame while fetching", function()
      local gh = fake_gh(ALL_PASS)
      gh.set_slow()
      start_review({ pr = 42 }) -- prefetch kicks off the slow fetch
      press_in_panel(1, "L")
      press_in_panel(1, "L") -- checks current while the fetch is in flight

      local line = panel_lines()[1]
      assert.is_truthy(line:find("fetching checks", 1, true), line)
      assert.is_true(is_running_glyph(line:sub(1, 3)), line)
      -- The ticker animates the loading row too.
      vim.wait(2000, function()
        local now = panel_lines()[1]
        return now ~= line and now:find("fetching checks", 1, true) ~= nil
      end, 10)
      assert.are_not.equal(line, panel_lines()[1], "loading row froze")
    end)

    it("repolls a running check every 30s while the tab is current", function()
      local gh = fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()
      assert.are.equal(1, #gh.calls())

      -- Age the fetch past the repoll threshold; the ticker's next build
      -- notices and quietly refetches (rows stay on screen meanwhile).
      gh.set_output(ALL_PASS)
      local st = checks()._state_for(require("pjollrig.review").state())
      st.fetched_at = os.time() - 30
      vim.wait(2000, function()
        return #gh.calls() == 2
      end, 10)
      assert.are.equal(2, #gh.calls(), "repoll did not refetch")
      vim.wait(2000, function()
        return panel_lines()[1] == "\u{2713} build  18s"
      end, 10)
      assert.are.same({ "\u{2713} build  18s", "\u{2713} lint  2m 14s", FOOTER }, panel_lines())
    end)

    it("does not repoll when nothing is running", function()
      local gh = fake_gh(ALL_PASS)
      start_review({ pr = 42 })
      enter_checks_tab()
      assert.are.equal(1, #gh.calls())

      local st = checks()._state_for(require("pjollrig.review").state())
      st.fetched_at = os.time() - 3600
      -- Force renders: builds must see the stale clock and still not fetch.
      vim.api.nvim_exec_autocmds("User", { pattern = "PjollrigEdited" })
      vim.wait(300)
      assert.are.equal(1, #gh.calls(), "repolled with no running check")
    end)
  end)

  describe("keymaps", function()
    it("<CR> opens the row's url via vim.ui.open; no-op on url-less rows", function()
      fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()

      local opened = {}
      local original_open = vim.ui.open
      vim.ui.open = function(url)
        opened[#opened + 1] = url
      end
      press_in_panel(1, "<CR>") -- fail row
      press_in_panel(3, "<CR>") -- pass row
      press_in_panel(5, "<CR>") -- footer: nothing to open
      vim.ui.open = original_open

      assert.are.same({ "https://example.test/runs/1", "https://example.test/runs/2" }, opened)
    end)

    it("gl opens the row's url like <CR>", function()
      fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()

      local opened = {}
      local original_open = vim.ui.open
      vim.ui.open = function(url)
        opened[#opened + 1] = url
      end
      press_in_panel(2, "gl") -- running row
      vim.ui.open = original_open

      assert.are.same({ "https://example.test/runs/3" }, opened)
    end)

    it("falls back to a notify carrying the url when vim.ui.open errors", function()
      fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()

      local original_open = vim.ui.open
      vim.ui.open = function()
        error("no opener")
      end
      local messages = {}
      local original_notify = vim.notify
      vim.notify = function(msg)
        messages[#messages + 1] = tostring(msg)
      end
      press_in_panel(1, "<CR>")
      vim.notify = original_notify
      vim.ui.open = original_open

      assert.are.equal(1, #messages)
      assert.is_truthy(messages[1]:find("https://example.test/runs/1", 1, true), messages[1])
    end)

    it("R drops the cache and refetches", function()
      local gh = fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()
      assert.are.equal(1, #gh.calls())
      assert.is_truthy(winbar():find("Checks \u{2717}", 1, true), winbar())

      gh.set_output(ALL_PASS)
      press_in_panel(1, "R")
      vim.wait(2000, function()
        return #gh.calls() == 2 and #panel_lines() == 3
      end, 10)

      assert.are.equal(2, #gh.calls())
      assert.are.same({ "\u{2713} build  18s", "\u{2713} lint  2m 14s", FOOTER }, panel_lines())
      assert.is_truthy(winbar():find("Checks 2/2", 1, true), winbar())
    end)

    it("re-entering the tab reuses the cache instead of refetching", function()
      local gh = fake_gh(PR_CHECKS)
      start_review({ pr = 42 })
      enter_checks_tab()
      assert.are.equal(1, #gh.calls())

      press_in_panel(1, "L") -- leave (wraps to files)
      press_in_panel(1, "H") -- straight back to checks
      vim.wait(100)
      assert.are.equal(1, #gh.calls(), "on_show refetched despite the cache")
      assert.are.equal("\u{2717} lint-test (ubuntu, nightly)  1m 48s", panel_lines()[1])
    end)
  end)

  describe("elapsed formatter", function()
    it("formats seconds, minutes, running, and rejects bad input", function()
      local elapsed = checks()._elapsed
      assert.are.equal("18s", elapsed("2024-01-01T00:00:00Z", "2024-01-01T00:00:18Z"))
      assert.are.equal("2m 14s", elapsed("2024-01-01T00:00:00Z", "2024-01-01T00:02:14Z"))
      -- 2024-01-01T00:00:00Z is epoch 1704067200; now injected for
      -- determinism (defaults to os.time()).
      assert.are.equal("running 34s\u{2026}", elapsed("2024-01-01T00:00:00Z", nil, 1704067234))
      assert.are.equal("running 2m 5s\u{2026}", elapsed("2024-01-01T00:00:00Z", nil, 1704067200 + 125))
      -- Clock skew clamps to zero rather than going negative.
      assert.are.equal("0s", elapsed("2024-01-01T00:00:18Z", "2024-01-01T00:00:00Z"))
      assert.is_nil(elapsed(nil, nil))
      assert.is_nil(elapsed("not a timestamp", "2024-01-01T00:00:18Z"))
      -- Go zero-value timestamps (gh emits them for unstarted checks)
      -- count as missing.
      assert.is_nil(elapsed("0001-01-01T00:00:00Z", nil, 1704067234))
    end)
  end)
end)
