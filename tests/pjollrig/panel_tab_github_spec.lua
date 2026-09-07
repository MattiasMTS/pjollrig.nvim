local H = require("helpers")

local ctx
local saved_path
local gh

local ns = vim.api.nvim_create_namespace("pjollrig.review.panel")

local function panel()
  return require("pjollrig.review.panel")
end

local function github_tab()
  return require("pjollrig.review.tabs.github")
end

---Fake gh on PATH: answers `pr view <n> --json`, `pr view <n> --web`,
---`repo view`, the GraphQL thread query, and the REST comments endpoint
---(everything the tab and a re-import touch), logging every invocation's
---argv to <home>/argv.log. Drop <home>/no-prview to make the JSON fetch
---fail like a network error.
local function fake_gh(pr_fields)
  local home = ctx.artifact_root .. "/gh-tab"
  local bin = home .. "/bin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({
    vim.json.encode(pr_fields or {
      title = "Fix panel rendering",
      author = { login = "octocat" },
      state = "OPEN",
      reviewDecision = "CHANGES_REQUESTED",
      headRefName = "feature-branch",
      baseRefName = "main",
      url = "https://example.test/pr/42",
    }),
  }, home .. "/pr.json")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'printf "%s\\n" "$*" >> "$dir/argv.log"',
    'if [ "$1 $2" = "pr view" ]; then',
    '  case "$*" in',
    "  *--web*) exit 0;;",
    "  *)",
    '    if [ -f "$dir/no-prview" ]; then echo "gh: pr boom" >&2; exit 1; fi;',
    '    cat "$dir/pr.json";;',
    "  esac;",
    'elif [ "$1 $2" = "repo view" ]; then',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1 $2" = "api graphql" ]; then',
    '  echo \'{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\';',
    'elif [ "$1" = "api" ]; then',
    "  printf '[[]]';",
    "else",
    "  exit 2;",
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return {
    bin = bin,
    home = home,
    log = function()
      local ok, lines = pcall(vim.fn.readfile, home .. "/argv.log")
      return ok and lines or {}
    end,
    set_no_prview = function()
      vim.fn.writefile({ "" }, home .. "/no-prview")
    end,
  }
end

local function log_has(pattern)
  for _, line in ipairs(gh.log()) do
    if line:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function make_pairs(n)
  local files = {}
  for i = 1, n or 1 do
    local left = ctx.artifact_root .. ("/left/f%d.lua"):format(i)
    local right = ctx.root .. ("/f%d.lua"):format(i)
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ "-- one old", "-- two", "-- three", "-- four", "-- five" }, left)
    vim.fn.writefile({ "-- one new", "-- two", "-- three", "-- four", "-- five" }, right)
    files[i] = { left = left, right = right, status = "M", path = ("f%d.lua"):format(i) }
  end
  return files
end

---Start a review session shaped like `:PjollrigReview pr 42` (files +
---ctx carrying the PR number). Pass `ctx = false` for a plain non-PR
---session.
local function start_pr_review(opts)
  opts = opts or {}
  local review_ctx = { pr = 42 }
  if opts.ctx == false then
    review_ctx = nil
  end
  assert.is_true(require("pjollrig.review").start({
    files = make_pairs(opts.files),
    label = "pr 42",
    ctx = review_ctx,
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

---Cycle L until the PR tab is active (it sits after the builtins).
local function switch_to_pr_tab()
  for _ = 1, 4 do
    press_in_panel(1, "L")
    if winbar():find("%#PjollrigPanelTabActive#PR", 1, true) then
      return
    end
  end
  error("PR tab not reachable via L: " .. winbar())
end

---1-based panel row whose text contains `text` (plain match).
local function find_row(text)
  for idx, line in ipairs(panel_lines()) do
    if line:find(text, 1, true) then
      return idx
    end
  end
  return nil
end

---Content extmarks on `row` (0-indexed) using highlight group `hl`.
local function span_marks(row, hl)
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    if mark[2] == row and mark[4].hl_group == hl then
      table.insert(found, mark)
    end
  end
  return found
end

---Persist a record shaped like review/import.lua writes them:
---project-scoped, anchored to a session worktree file, carrying
---`meta.github = { imported = true, ... }`.
local next_gh_id = 5000
local function add_imported(relpath, line_nr, body, gh_meta)
  local store = require("pjollrig.store")
  next_gh_id = next_gh_id + 1
  local now = os.time()
  local record = {
    id = require("pjollrig.id").new(),
    uri = require("pjollrig.uri").for_path(ctx.root .. "/" .. relpath),
    scope = "project",
    project_root = ctx.root,
    range = { start = { line_nr - 1, 0 }, end_ = { line_nr - 1, 0 } },
    body = body,
    author = "octocat",
    created_at = now,
    updated_at = now,
    resolved = false,
    meta = {
      github = vim.tbl_extend("force", { id = next_gh_id, imported = true, pr = 42 }, gh_meta or {}),
    },
  }
  store.put_record(record)
  assert(store.save(ctx.root))
  return record
end

---Persist a plain local (non-imported) comment on a session file.
local function add_local(relpath, line_nr, body)
  local store = require("pjollrig.store")
  local now = os.time()
  local record = {
    id = require("pjollrig.id").new(),
    uri = require("pjollrig.uri").for_path(ctx.root .. "/" .. relpath),
    scope = "project",
    project_root = ctx.root,
    range = { start = { line_nr - 1, 0 }, end_ = { line_nr - 1, 0 } },
    body = body,
    author = "me@test.local",
    created_at = now,
    updated_at = now,
    resolved = false,
  }
  store.put_record(record)
  assert(store.save(ctx.root))
  return record
end

describe("pjollrig github PR panel tab", function()
  before_each(function()
    ctx = H.setup()
    saved_path = vim.env.PATH
    gh = fake_gh()
    vim.env.PATH = gh.bin .. ":" .. saved_path
    -- Run the builtin loader once (idempotent; sets its done-guard so a
    -- later panel open cannot double-register), then rebuild the
    -- registry from a clean slate with just this tab.
    pcall(require("pjollrig.review.tabs").setup)
    panel()._reset_tabs()
    github_tab()._reset()
    github_tab().setup()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    panel()._reset_tabs()
    github_tab()._reset()
    vim.env.PATH = saved_path
    H.teardown(ctx)
    ctx = nil
  end)

  it("is available for PR sessions and titles the tab with the PR number", function()
    start_pr_review()
    assert.is_truthy(winbar():find("PR #42", 1, true), winbar())
  end)

  it("is absent for sessions without a PR in ctx", function()
    start_pr_review({ ctx = false })
    assert.is_nil(winbar():find("PR #", 1, true), winbar())
  end)

  it("is absent when gh is not executable", function()
    require("pjollrig.config").get().sinks.github = { command = ctx.artifact_root .. "/missing-gh" }
    start_pr_review()
    assert.is_nil(winbar():find("PR #", 1, true), winbar())
  end)

  it("prefetches the PR header at session open, before the tab is entered", function()
    start_pr_review()
    vim.wait(2000, function()
      return log_has("pr view 42 --json")
    end, 10)
    assert.is_true(log_has("pr view 42 --json"), table.concat(gh.log(), "\n"))
    -- The landed fetch decorates the title while Files is still current.
    vim.wait(2000, function()
      return winbar():find("PR #42 ✗", 1, true) ~= nil
    end, 10)
    assert.is_truthy(winbar():find("PR #42 ✗", 1, true), winbar())
    assert.is_truthy(winbar():find("%#PjollrigPanelTabActive#Files", 1, true), winbar())
  end)

  it("review.panel.prefetch = false keeps the header fetch lazy", function()
    require("pjollrig.config").get().review.panel.prefetch = false
    start_pr_review()
    vim.wait(300)
    assert.is_false(log_has("pr view 42 --json"), table.concat(gh.log(), "\n"))
    switch_to_pr_tab()
    vim.wait(2000, function()
      return log_has("pr view 42 --json")
    end, 10)
    assert.is_true(log_has("pr view 42 --json"), table.concat(gh.log(), "\n"))
  end)

  it("fetches PR details on show, renders the header, and caches the result", function()
    start_pr_review()
    switch_to_pr_tab()

    vim.wait(2000, function()
      return find_row("#42 Fix panel rendering") ~= nil
    end, 10)
    assert.is_truthy(find_row("#42 Fix panel rendering"), table.concat(panel_lines(), "\n"))
    assert.is_truthy(
      find_row("octocat · feature-branch → main · OPEN · review: CHANGES_REQUESTED"),
      table.concat(panel_lines(), "\n")
    )
    -- reviewDecision decorates the title once fetched.
    assert.is_truthy(winbar():find("PR #42 ✗", 1, true), winbar())

    -- Leaving and re-entering the tab reuses the cached fetch.
    press_in_panel(1, "L") -- pr wraps to files
    press_in_panel(1, "H") -- files wraps back to pr
    vim.wait(200)
    local fetches = 0
    for _, line in ipairs(gh.log()) do
      if line:find("pr view 42 --json", 1, true) then
        fetches = fetches + 1
      end
    end
    assert.are.equal(1, fetches)
  end)

  it("renders a dim error row when the fetch fails and stays usable", function()
    gh.set_no_prview()
    start_pr_review()
    switch_to_pr_tab()

    vim.wait(2000, function()
      return find_row("gh pr view failed: gh: pr boom") ~= nil
    end, 10)
    local row = assert(find_row("gh pr view failed: gh: pr boom"), table.concat(panel_lines(), "\n"))
    assert.is_true(#span_marks(row - 1, "Comment") >= 1, "error row not dimmed")
    -- The tab stays usable: title, sections, and actions all render.
    assert.is_truthy(winbar():find("PR #42", 1, true), winbar())
    assert.is_truthy(find_row("Threads"))
    assert.is_truthy(find_row("Pending"))
  end)

  it("derives the threads section from imported records, open before resolved", function()
    add_imported("f1.lua", 2, "already handled", { resolved = true })
    add_imported("f1.lua", 4, "needs work\nmore detail", {})
    add_imported("f1.lua", 3, "older open", {})
    add_local("f1.lua", 1, "just a local note")
    start_pr_review()
    switch_to_pr_tab()

    local open3 = assert(find_row("● f1.lua:3  older open"), table.concat(panel_lines(), "\n"))
    local open4 = assert(find_row("● f1.lua:4  needs work…"), table.concat(panel_lines(), "\n"))
    local resolved2 = assert(find_row("✓ f1.lua:2  already handled"), table.concat(panel_lines(), "\n"))
    assert.is_true(open3 < open4, "open threads out of order")
    assert.is_true(open4 < resolved2, "resolved thread not listed after open ones")
    assert.is_true(#span_marks(resolved2 - 1, "Comment") >= 1, "resolved thread not dimmed")

    -- The local comment is pending, not a thread.
    assert.is_nil(find_row("● f1.lua:1"))
    assert.is_truthy(find_row("1 unsent comment · verdict: comment"), table.concat(panel_lines(), "\n"))
    assert.is_truthy(find_row("[S] send review · [R] re-import threads · [O] open in browser"))
  end)

  it("<CR> on a thread row jumps to the file and line", function()
    add_imported("f2.lua", 3, "look here", {})
    start_pr_review({ files = 2 })
    switch_to_pr_tab()

    local row = assert(find_row("● f2.lua:3"), table.concat(panel_lines(), "\n"))
    press_in_panel(row, "<CR>")
    assert.are.equal(ctx.root .. "/f2.lua", vim.api.nvim_buf_get_name(0))
    assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("S sends the pending review through the github sink with the session PR", function()
    local calls = H.register_fake_sink("github", { accepts_verdict = true })
    add_local("f1.lua", 1, "local note")
    add_imported("f1.lua", 2, "imported note", {})
    start_pr_review()
    switch_to_pr_tab()

    press_in_panel(1, "S")
    vim.wait(2000, function()
      return #calls > 0
    end, 10)
    assert.are.equal(1, #calls)
    assert.are.equal(1, #calls[1].comments, "imported records must not be echoed back")
    assert.are.equal("local note", calls[1].comments[1].body)
    assert.are.equal(42, calls[1].ctx.pr)
  end)

  it("R re-runs the PR comment import", function()
    start_pr_review()
    switch_to_pr_tab()

    press_in_panel(1, "R")
    vim.wait(2000, function()
      return log_has("api repos/acme/widgets/pulls/42/comments")
    end, 10)
    assert.is_true(log_has("repo view --json nameWithOwner"), table.concat(gh.log(), "\n"))
    assert.is_true(log_has("api repos/acme/widgets/pulls/42/comments --paginate --slurp"), table.concat(gh.log(), "\n"))
  end)

  it("O opens the PR in the browser via gh", function()
    start_pr_review()
    switch_to_pr_tab()

    press_in_panel(1, "O")
    vim.wait(2000, function()
      return log_has("pr view 42 --web")
    end, 10)
    assert.is_true(log_has("pr view 42 --web"), table.concat(gh.log(), "\n"))
  end)
end)
