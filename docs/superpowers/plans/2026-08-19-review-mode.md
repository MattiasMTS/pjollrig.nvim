# Manicule Review Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `:ManiculeReview` — a git-aware diff-review mode (baseline vs worktree file pairs) with resolvers (`dirs`, git ref, `pr <n>`), plus a generic JSONL unix-socket sink and a `start_from_job` entrypoint external drivers (pi) can call.

**Architecture:** A `review` core opens left/right file pairs as diffs (builtin `nvim.difftool` when available, `:diffsplit` fallback), tracks a single active session, and on finish dispatches the session's comments to a configured sink. Resolvers turn command arguments into staged file pairs; git plumbing materializes baseline versions into a tmpdir. Everything reuses existing manicule machinery (records, sinks registry, `M.list`).

**Tech Stack:** Lua (Neovim >= 0.10), `vim.system`, `vim.uv` pipes, mini.test harness (`make test`), optional: `nvim.difftool` (0.12+), `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-08-19-pi-integration-design.md`

## Global Constraints

- Neovim floor stays **0.10**. `nvim.difftool` is used only behind a `pcall(vim.cmd.packadd, "nvim.difftool")` check; `:diffsplit` is the guaranteed path.
- **No new hard dependencies.** `gh` is loaded/checked only inside the `pr` resolver. Sockets use `vim.uv` only.
- Manicule never imports pi concepts. The socket sink is generic (`socket`, not `pi`).
- Right side of every pair is the **real worktree file** where it exists; left side is read-only staged content. Manicule must keep refusing comments on the left (reference) side — do not change adapter policy.
- Comments are never lost: `clear_on_success` on the socket sink defaults to `true` but records are deleted only after the consumer acks.
- Test policy: integration-first with the existing `mini.test` harness (`describe`/`it`, `tests/helpers.lua` `H.setup`/`H.teardown`). Real throwaway git repos, fake executables on `PATH` for `gh`. Run with `make test` or `scripts/test tests/manicule/<file>_spec.lua`.
- Commit style: conventional (`feat:`, `test:`, `docs:`), no Co-authored-by lines.

## File Structure

```text
lua/manicule/review.lua           session core: start / open / next / prev /
                                  finish / stop / start_from_job
lua/manicule/review/git.lua       git plumbing: run, root, rev_parse,
                                  merge_base, changed_files, show_file,
                                  stage_baseline
lua/manicule/review/sources.lua   resolver registry: dirs | git ref | pr <n>
lua/manicule/sinks/socket.lua     generic JSONL-over-unix-socket sink
lua/manicule/sinks/init.lua       register socket as builtin integration
plugin/manicule.lua               :ManiculeReview command (+ Next/Prev)
tests/helpers.lua                 H.git_repo helper
tests/manicule/review_git_spec.lua
tests/manicule/review_sources_spec.lua
tests/manicule/socket_sink_spec.lua
tests/integration/review_spec.lua
README.md, ARCHITECTURE.md        docs
```

---

### Task 1: Git plumbing (`review/git.lua`)

**Files:**
- Create: `lua/manicule/review/git.lua`
- Modify: `tests/helpers.lua` (add `H.git_repo`)
- Test: `tests/manicule/review_git_spec.lua`

**Interfaces:**
- Consumes: nothing manicule-specific (`vim.system`, `tests/helpers.lua`).
- Produces (used by Tasks 2, 4, 5):
  - `G.run(argv: string[], opts?: {cwd?: string}) -> {code: integer, stdout: string, stderr: string}`
  - `G.root(dir: string) -> string|nil`
  - `G.rev_parse(root: string, ref: string) -> string|nil, string|nil err`
  - `G.merge_base(root: string, a: string, b: string) -> string|nil, string|nil err`
  - `G.changed_files(root: string, base: string) -> {path: string, status: "M"|"A"|"D"}[]|nil, string|nil err` (includes untracked as `"A"`)
  - `G.show_file(root: string, ref: string, path: string) -> string|nil content`
  - `G.stage_baseline(root: string, base: string, entries: {path,status}[], dir: string) -> {left: string, right: string, status: string, path: string}[]`

- [ ] **Step 1: Add `H.git_repo` to `tests/helpers.lua`**

Append before the final `return H`:

```lua
---Create a real git repository with an initial commit.
---@param ctx table H.setup context
---@param files table<string, string[]>|nil relative path -> lines
---@return string root, fun(...): table git  -- git(...) runs git -C root
function H.git_repo(ctx, files)
  local root = H.project_dir(ctx.artifact_root, "gitrepo")
  vim.fn.delete(root .. "/.git", "rf")
  local function git(...)
    local result = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
    assert(result.code == 0, ("git %s failed: %s"):format(table.concat({ ... }, " "), result.stderr))
    return result
  end
  git("init", "-q", "-b", "main")
  git("config", "user.email", "manicule@test.local")
  git("config", "user.name", "Manicule Test")
  git("config", "commit.gpgsign", "false")
  for path, lines in pairs(files or {}) do
    local abs = root .. "/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
    vim.fn.writefile(lines, abs)
    git("add", path)
  end
  git("commit", "-q", "--allow-empty", "-m", "init")
  return root, git
end
```

- [ ] **Step 2: Write the failing tests**

Create `tests/manicule/review_git_spec.lua`:

```lua
local H = require("helpers")

local ctx

describe("manicule review git plumbing", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("lists modified, added, deleted, and untracked files vs a base", function()
    local G = require("manicule.review.git")
    local root, git = H.git_repo(ctx, {
      ["src/a.lua"] = { "return 1" },
      ["src/gone.lua"] = { "return 0" },
    })
    -- modify a.lua, delete gone.lua, add untracked new.lua
    vim.fn.writefile({ "return 2" }, root .. "/src/a.lua")
    vim.fn.delete(root .. "/src/gone.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/new.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local changed = assert(G.changed_files(root, base))
    local by_path = {}
    for _, entry in ipairs(changed) do
      by_path[entry.path] = entry.status
    end
    assert.equals("M", by_path["src/a.lua"])
    assert.equals("D", by_path["src/gone.lua"])
    assert.equals("A", by_path["src/new.lua"])
  end)

  it("stages baseline file versions into a directory", function()
    local G = require("manicule.review.git")
    local root = H.git_repo(ctx, { ["src/a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/src/a.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/new.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local dir = ctx.artifact_root .. "/staged"
    local files = G.stage_baseline(root, base, {
      { path = "src/a.lua", status = "M" },
      { path = "src/new.lua", status = "A" },
    }, dir)

    assert.equals(2, #files)
    local by_path = {}
    for _, pair in ipairs(files) do
      by_path[pair.path] = pair
    end
    -- Modified: left holds the committed content, right is the worktree file.
    assert.equals("return 1", table.concat(vim.fn.readfile(by_path["src/a.lua"].left), "\n"))
    assert.equals(root .. "/src/a.lua", by_path["src/a.lua"].right)
    -- Added: left is an empty staged file so diff shows all-added.
    assert.equals(0, vim.fn.getfsize(by_path["src/new.lua"].left))
  end)

  it("computes merge-base", function()
    local G = require("manicule.review.git")
    local root, git = H.git_repo(ctx, { ["a.txt"] = { "one" } })
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "two" }, root .. "/a.txt")
    git("commit", "-aqm", "feature change")
    local main = assert(G.rev_parse(root, "main"))
    local mb = assert(G.merge_base(root, "HEAD", "main"))
    assert.equals(main, mb)
  end)
end)
```

- [ ] **Step 3: Run to verify failure**

Run: `scripts/test tests/manicule/review_git_spec.lua`
Expected: FAIL — `module 'manicule.review.git' not found`.

- [ ] **Step 4: Implement `lua/manicule/review/git.lua`**

```lua
-- manicule.nvim: git plumbing for review mode.
--
-- Thin, synchronous wrappers around `git` used to resolve baselines and
-- stage baseline file versions for diff pairs. No global state.

local M = {}

---@param argv string[]
---@param opts? {cwd?: string}
---@return {code: integer, stdout: string, stderr: string}
function M.run(argv, opts)
  opts = opts or {}
  local result = vim.system(argv, { text = true, cwd = opts.cwd }):wait()
  return {
    code = result.code or -1,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

local function git(root, ...)
  return M.run({ "git", "-C", root, ... })
end

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

---@param dir string
---@return string|nil
function M.root(dir)
  local result = M.run({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if result.code ~= 0 then
    return nil
  end
  return trim(result.stdout)
end

---@param root string
---@param ref string
---@return string|nil sha, string|nil err
function M.rev_parse(root, ref)
  local result = git(root, "rev-parse", "--verify", ref .. "^{commit}")
  if result.code ~= 0 then
    return nil, ("manicule: cannot resolve ref %q: %s"):format(ref, trim(result.stderr))
  end
  return trim(result.stdout), nil
end

---@param root string
---@param a string
---@param b string
---@return string|nil sha, string|nil err
function M.merge_base(root, a, b)
  local result = git(root, "merge-base", a, b)
  if result.code ~= 0 then
    return nil, ("manicule: merge-base %s %s failed: %s"):format(a, b, trim(result.stderr))
  end
  return trim(result.stdout), nil
end

---Changed files vs `base`, including untracked files as "A".
---@param root string
---@param base string
---@return {path: string, status: "M"|"A"|"D"}[]|nil, string|nil err
function M.changed_files(root, base)
  local result = git(root, "diff", "--name-status", "--no-renames", base)
  if result.code ~= 0 then
    return nil, ("manicule: git diff failed: %s"):format(trim(result.stderr))
  end
  local entries = {}
  local seen = {}
  for line in result.stdout:gmatch("[^\n]+") do
    local status, path = line:match("^(%a)%s+(.+)$")
    if status and path and not seen[path] then
      seen[path] = true
      -- Collapse rare statuses (T, etc.) into "M"; we only branch on A/D.
      if status ~= "A" and status ~= "D" then
        status = "M"
      end
      table.insert(entries, { path = path, status = status })
    end
  end
  local untracked = git(root, "ls-files", "--others", "--exclude-standard")
  if untracked.code == 0 then
    for path in untracked.stdout:gmatch("[^\n]+") do
      if not seen[path] then
        seen[path] = true
        table.insert(entries, { path = path, status = "A" })
      end
    end
  end
  table.sort(entries, function(x, y)
    return x.path < y.path
  end)
  return entries, nil
end

---@param root string
---@param ref string
---@param path string
---@return string|nil content
function M.show_file(root, ref, path)
  local result = git(root, "show", ref .. ":" .. path)
  if result.code ~= 0 then
    return nil
  end
  return result.stdout
end

---Write baseline versions of `entries` under `dir`, mirroring relative
---paths. Returns diff pairs; `right` always names the worktree path even
---when the file was deleted (callers branch on `status == "D"`).
---@param root string
---@param base string
---@param entries {path: string, status: string}[]
---@param dir string
---@return {left: string, right: string, status: string, path: string}[]
function M.stage_baseline(root, base, entries, dir)
  local files = {}
  for _, entry in ipairs(entries) do
    local left = dir .. "/" .. entry.path
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    local content = entry.status ~= "A" and M.show_file(root, base, entry.path) or nil
    local fd = assert(io.open(left, "wb"))
    fd:write(content or "")
    fd:close()
    table.insert(files, {
      left = left,
      right = root .. "/" .. entry.path,
      status = entry.status,
      path = entry.path,
    })
  end
  return files
end

return M
```

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test tests/manicule/review_git_spec.lua`
Expected: PASS (3 tests).

- [ ] **Step 6: Run full suite, then commit**

Run: `make test` — expected all green.

```bash
git add lua/manicule/review/git.lua tests/helpers.lua tests/manicule/review_git_spec.lua
git commit -m "feat(review): git plumbing for baseline staging"
```

---

### Task 2: Review session core (`review.lua`)

**Files:**
- Create: `lua/manicule/review.lua`
- Test: `tests/integration/review_spec.lua`

**Interfaces:**
- Consumes: nothing yet (pairs passed in directly).
- Produces (used by Tasks 3, 6, 7):
  - `R.start(opts: {files: {left,right,status,path}[], label?: string, sink?: string, sink_ctx?: table}) -> boolean ok, string|nil err`
  - `R.state() -> {files, label, sink, sink_ctx, index, tab: integer}|nil`
  - `R.open(index: integer)`
  - `R.next()` / `R.prev()` (wrap around)
  - `R.stop()` — close session tab, clear state, remove autocmds

**Behavior contract:**
- One active session at a time; `start` while active calls `stop()` first.
- Session opens in its **own tab page**. `open(index)`:
  - `status ~= "D"`: edit the **right** (worktree) file, then `vim.cmd("leftabove vertical diffsplit " .. vim.fn.fnameescape(left))`; the left buffer gets `readonly`, `nomodifiable`, `bufhidden=wipe`.
  - `status == "D"`: open the **left** staged file alone (no diff), `readonly` **off** for manicule purposes is NOT needed — buffer stays modifiable=false but comments still attach (manicule session scope allows special buffers). Show a one-line notify: `manicule: <path> was deleted; comments here are file-level notes`.
- Uses `require("difftool")` after `pcall(vim.cmd.packadd, "nvim.difftool")` when available for M/A pairs (`difftool.open(left, right)`); otherwise the diffsplit path above. Both paths must set the same left-buffer options — factor a `protect_left(bufnr)` local.
- Populates a quickfix list titled `manicule-review (<label>)` with one entry per pair pointing at the right path (left path for deletions) so `:copen` gives an overview.

- [ ] **Step 1: Write the failing tests**

Create `tests/integration/review_spec.lua`:

```lua
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

describe("manicule review session", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("opens a diff pair with a protected left buffer", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))

    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert.equals(2, #wins)
    local saw_left, saw_right = false, false
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      assert.is_true(vim.wo[win].diff)
      if name:find("/left/", 1, true) then
        saw_left = true
        assert.is_false(vim.bo[buf].modifiable)
      else
        saw_right = true
        assert.is_true(vim.bo[buf].modifiable)
      end
    end
    assert.is_true(saw_left)
    assert.is_true(saw_right)
  end)

  it("cycles pairs with next/prev and wraps", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "test" }))
    assert.equals(1, R.state().index)
    R.next()
    assert.equals(2, R.state().index)
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("f2.lua", 1, true))
    R.next() -- wraps
    assert.equals(1, R.state().index)
    R.prev() -- wraps back
    assert.equals(2, R.state().index)
  end)

  it("stop() clears state and closes the session tab", function()
    local R = require("manicule.review")
    local tabs_before = #vim.api.nvim_list_tabpages()
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))
    R.stop()
    assert.is_nil(R.state())
    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
  end)

  it("rejects an empty file list", function()
    local R = require("manicule.review")
    local ok, err = R.start({ files = {}, label = "test" })
    assert.is_false(ok)
    assert.is_truthy(err:find("no files", 1, true))
  end)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/integration/review_spec.lua`
Expected: FAIL — `module 'manicule.review' not found`.

- [ ] **Step 3: Implement `lua/manicule/review.lua`**

```lua
-- manicule.nvim: review session core.
--
-- Opens baseline-vs-worktree file pairs as diffs, one active session at
-- a time. The right side is always the real worktree file so comments
-- anchor natively; the left side is a read-only staged baseline copy.
-- Diff rendering prefers the builtin nvim.difftool (0.12+) and falls
-- back to plain :diffsplit.

local M = {}

---@class manicule.ReviewSession
---@field files {left: string, right: string, status: string, path: string}[]
---@field label string
---@field sink string|nil
---@field sink_ctx table|nil
---@field index integer
---@field tab integer

---@type manicule.ReviewSession|nil
local session = nil

local function difftool_mod()
  if not pcall(vim.cmd.packadd, "nvim.difftool") then
    return nil
  end
  local ok, mod = pcall(require, "difftool")
  return ok and mod or nil
end

local function protect_left(bufnr)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
end

local function close_session_windows()
  -- Reduce the session tab to one window so the next pair starts clean.
  vim.cmd("silent! diffoff!")
  vim.cmd("silent! only")
end

local function set_quickfix(files, label)
  local items = {}
  for _, pair in ipairs(files) do
    table.insert(items, {
      filename = pair.status == "D" and pair.left or pair.right,
      lnum = 1,
      text = ("[%s] %s"):format(pair.status, pair.path),
    })
  end
  vim.fn.setqflist({}, " ", {
    title = ("manicule-review (%s)"):format(label),
    items = items,
  })
end

---@param index integer
function M.open(index)
  if not session then
    return
  end
  if index < 1 then
    index = #session.files
  elseif index > #session.files then
    index = 1
  end
  session.index = index
  local pair = session.files[index]
  vim.api.nvim_set_current_tabpage(session.tab)
  close_session_windows()

  if pair.status == "D" then
    vim.cmd.edit(vim.fn.fnameescape(pair.left))
    protect_left(vim.api.nvim_get_current_buf())
    vim.notify(
      ("manicule: %s was deleted; comments here are file-level notes"):format(pair.path),
      vim.log.levels.INFO
    )
    return
  end

  local difftool = difftool_mod()
  if difftool then
    local ok = pcall(difftool.open, pair.left, pair.right)
    if ok then
      -- Find and protect the left buffer regardless of window layout.
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_get_name(buf) == pair.left then
          protect_left(buf)
        end
      end
      return
    end
  end

  -- Fallback: plain diffsplit. Right first (focused), left split beside it.
  vim.cmd.edit(vim.fn.fnameescape(pair.right))
  vim.cmd("leftabove vertical diffsplit " .. vim.fn.fnameescape(pair.left))
  protect_left(vim.api.nvim_get_current_buf())
  vim.cmd.wincmd("p") -- focus back on the right / worktree side
end

function M.next()
  if session then
    M.open(session.index + 1)
  end
end

function M.prev()
  if session then
    M.open(session.index - 1)
  end
end

---@return manicule.ReviewSession|nil
function M.state()
  return session
end

---Start a review session over explicit file pairs.
---@param opts {files: table[], label?: string, sink?: string, sink_ctx?: table}
---@return boolean ok, string|nil err
function M.start(opts)
  opts = opts or {}
  if type(opts.files) ~= "table" or #opts.files == 0 then
    return false, "manicule: review has no files to show"
  end
  if session then
    M.stop()
  end
  vim.cmd.tabnew()
  session = {
    files = opts.files,
    label = opts.label or "review",
    sink = opts.sink,
    sink_ctx = opts.sink_ctx,
    index = 1,
    tab = vim.api.nvim_get_current_tabpage(),
  }
  set_quickfix(session.files, session.label)
  M.open(1)
  return true
end

function M.stop()
  if not session then
    return
  end
  local tab = session.tab
  session = nil
  if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("silent! diffoff!")
    vim.cmd("tabclose")
  end
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test tests/integration/review_spec.lua`
Expected: PASS (4 tests). Note: headless CI has no `nvim.difftool`? If the running nvim is 0.12+, `difftool.open` may create a different window layout — if the first test fails on window count under difftool, detect it in the test via `pcall(vim.cmd.packadd, "nvim.difftool")` and relax the window-count assertion to `>= 2` in that branch. Keep the left-protection assertion strict in both branches.

- [ ] **Step 5: Run full suite, then commit**

Run: `make test`

```bash
git add lua/manicule/review.lua tests/integration/review_spec.lua
git commit -m "feat(review): session core with diff pairs and navigation"
```

---

### Task 3: `finish()` — collect session comments and dispatch to sink

**Files:**
- Modify: `lua/manicule/review.lua`
- Test: `tests/integration/review_spec.lua` (extend)

**Interfaces:**
- Consumes: `require("manicule").list({_quiet = true})`, `require("manicule.sinks").dispatch(name, comments, ctx, cb)`, Task 2's `session`.
- Produces (used by Tasks 6, 7, and the pi extension):
  - `R.finish(opts?: {sink?: string}) -> nil` — collects the session's comment records, dispatches; on `ok` deletes records if the sink declares `clear_on_success`; fires `User ManiculeSent` (via the existing `M.send` path — see below); no-op with notify when there are no comments.
  - Auto-flush: a `VimLeavePre` autocmd calls `finish()` when a session is active, a sink is configured, and there are unsent comments.

**Design note (reuse over reimplementation):** `require("manicule").send(sink_name, filter, ctx)` already does dispatch + `ManiculeSent` + `clear_on_success` deletion. It lacks a "set of paths" filter. Extend `M.list`'s filter with `uris: table<string, true>` (a set) — a 6-line addition mirroring the existing `uri` branch — then `finish()` becomes a thin wrapper over `M.send`.

- [ ] **Step 1: Write the failing tests** (append to `tests/integration/review_spec.lua`, inside the same `describe`)

```lua
  it("finish() sends only the session's comments to the sink", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    -- A comment on a file OUTSIDE the review session must not be sent.
    local outside = ctx.root .. "/outside.lua"
    vim.fn.writefile({ "return 0" }, outside)

    local sent
    require("manicule").register_sink({
      name = "capture",
      send = function(comments, _, cb)
        sent = comments
        cb(true)
      end,
    })

    assert.is_true(R.start({ files = files, label = "test", sink = "capture" }))

    -- Comment on pair 1's worktree file (the current buffer after start).
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.with_prompt("session comment", function()
      require("manicule").add()
    end)

    -- Comment on the outside file.
    vim.cmd.edit(vim.fn.fnameescape(outside))
    H.with_prompt("outside comment", function()
      require("manicule").add()
    end)

    R.finish()
    vim.wait(200, function()
      return sent ~= nil
    end)
    assert.is_truthy(sent)
    assert.equals(1, #sent)
    assert.equals("session comment", sent[1].body)
  end)

  it("finish() with no comments notifies and does not dispatch", function()
    local R = require("manicule.review")
    local called = false
    require("manicule").register_sink({
      name = "capture",
      send = function(_, _, cb)
        called = true
        cb(true)
      end,
    })
    assert.is_true(R.start({ files = make_pairs(1), label = "test", sink = "capture" }))
    R.finish()
    assert.is_false(called)
  end)
```

`H.with_prompt` — check `tests/helpers.lua` for the existing prompt-faking helper used by `workflow_spec.lua` (the suite already fakes the comment editor; reuse that exact helper name/pattern; if it is named differently, use that name here and in Task 7's test).

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/integration/review_spec.lua`
Expected: FAIL — `finish` is nil / sends nothing.

- [ ] **Step 3: Extend `M.list` filter with a `uris` set** (in `lua/manicule/init.lua`, inside the existing filter `:filter(...)` chain, right after the `filter.uri` branch)

```lua
      if filter.uris and not filter.uris[r.uri] then
        return false
      end
```

And extend the annotation on `M.list`:

```lua
---@param filter {uri?: string, uris?: table<string, true>, path_suffix?: string, unresolved?: boolean, orphaned?: boolean, author?: string, _root?: string}|nil
```

- [ ] **Step 4: Implement `finish` + auto-flush in `lua/manicule/review.lua`**

Add near the bottom, before `return M`:

```lua
---URIs for every commentable buffer in the session (right side; left
---side for deletions), matching how adapter.identify keys records.
local function session_uris()
  local uri_mod = require("manicule.uri")
  local uris = {}
  for _, pair in ipairs(session.files) do
    local path = pair.status == "D" and pair.left or pair.right
    uris["file://" .. path] = true
  end
  return uris
end

---Count the session's pending comments without side effects.
local function pending_comments()
  if not session then
    return {}
  end
  return require("manicule").list({ _quiet = true, uris = session_uris() })
end

---Dispatch the session's comments to the configured sink.
---@param opts? {sink?: string}
function M.finish(opts)
  opts = opts or {}
  if not session then
    vim.notify("manicule: no active review session", vim.log.levels.WARN)
    return
  end
  local sink = opts.sink or session.sink
  if not sink then
    vim.notify("manicule: review session has no sink configured", vim.log.levels.WARN)
    return
  end
  local comments = pending_comments()
  if #comments == 0 then
    vim.notify("manicule: review has no comments to send", vim.log.levels.INFO)
    return
  end
  require("manicule").send(sink, { uris = session_uris() }, session.sink_ctx)
end

local augroup = vim.api.nvim_create_augroup("ManiculeReview", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    if session and session.sink and #pending_comments() > 0 then
      M.finish()
    end
  end,
})
```

Note: `session_uris` builds `file://` URIs directly. Verify against `lua/manicule/uri.lua` how file URIs are encoded (`uri_mod.from_path(path)` or similar exported helper) — if a helper exists, use it instead of string concatenation so symlink canonicalization matches `adapter.identify`. The test in Step 1 catches a mismatch (0 comments sent).

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test tests/integration/review_spec.lua`
Expected: PASS.

- [ ] **Step 6: Run full suite, then commit**

Run: `make test`

```bash
git add lua/manicule/review.lua lua/manicule/init.lua tests/integration/review_spec.lua
git commit -m "feat(review): finish() dispatches session comments to a sink"
```

---

### Task 4: Resolver registry (`review/sources.lua`) — dirs + git ref

**Files:**
- Create: `lua/manicule/review/sources.lua`
- Test: `tests/manicule/review_sources_spec.lua`

**Interfaces:**
- Consumes: Task 1's `G.*` (`root`, `rev_parse`, `merge_base`, `changed_files`, `stage_baseline`).
- Produces (used by Tasks 5, 8):
  - `S.resolve(fargs: string[], opts?: {cwd?: string, stage_dir?: string}) -> {files: table[], label: string}|nil, string|nil err`
  - `S.register(resolver: {name: string, match: fun(fargs): boolean, resolve: fun(fargs, opts): table|nil, string|nil})` — prepends to the registry (user resolvers win).

**Resolution rules:**
- `fargs = {dirL, dirR}` where both are existing directories → walk `dirR` recursively (`vim.fs.find` with a function matcher, `limit = math.huge`), pair against `dirL` by relative path; files only in `dirL` → status `D`, only in `dirR` → `A`, differing content → `M`, identical content → skipped. Label `"dirs"`.
- `fargs = {"pr", n}` → handled by Task 5 (registered later; until then falls through to error).
- `fargs = {ref}` → base = `merge_base(root, "HEAD", ref)`; changed = `changed_files(root, base)`; `stage_baseline` into `opts.stage_dir or vim.fn.tempname()`. Label = ref.
- `fargs = {}` → ref defaults to `"HEAD"` (uncommitted changes; base = `rev_parse(root, "HEAD")`, no merge-base needed).
- Not a git repo and args aren't dirs → error `"manicule: not a git repository and arguments are not directories"`.

- [ ] **Step 1: Write the failing tests**

Create `tests/manicule/review_sources_spec.lua`:

```lua
local H = require("helpers")

local ctx

describe("manicule review sources", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("resolves a bare invocation to HEAD-vs-worktree", function()
    local S = require("manicule.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")

    local job = assert(S.resolve({}, { cwd = root, stage_dir = ctx.artifact_root .. "/s1" }))
    assert.equals("HEAD", job.label)
    assert.equals(1, #job.files)
    assert.equals("a.lua", job.files[1].path)
    assert.equals(root .. "/a.lua", job.files[1].right)
  end)

  it("resolves a branch name via merge-base (only your changes)", function()
    local S = require("manicule.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    -- main moves ahead AFTER we branch; its change must not appear.
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")
    git("checkout", "-q", "main")
    vim.fn.writefile({ "-- main moved" }, root .. "/main-only.lua")
    git("add", "main-only.lua")
    git("commit", "-qm", "main work")
    git("checkout", "-q", "feature")

    local job = assert(S.resolve({ "main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s2" }))
    assert.equals(1, #job.files)
    assert.equals("a.lua", job.files[1].path)
  end)

  it("resolves two directories without git", function()
    local S = require("manicule.review.sources")
    local left = ctx.artifact_root .. "/L"
    local right = ctx.artifact_root .. "/R"
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
    assert.equals("M", by_path["sub/m.txt"])
    assert.equals("D", by_path["gone.txt"])
    assert.equals("A", by_path["added.txt"])
    assert.is_nil(by_path["same.txt"])
  end)

  it("errors outside a git repo for ref arguments", function()
    local S = require("manicule.review.sources")
    local job, err = S.resolve({ "main" }, { cwd = ctx.artifact_root })
    assert.is_nil(job)
    assert.is_truthy(err)
  end)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/manicule/review_sources_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `lua/manicule/review/sources.lua`**

```lua
-- manicule.nvim: review source resolvers.
--
-- Turn `:ManiculeReview` arguments into staged diff pairs. Registry is
-- open: register({name, match, resolve}) prepends, so user resolvers
-- shadow builtins.

local M = {}

local registry = {}

---@param resolver {name: string, match: fun(fargs: string[]): boolean, resolve: fun(fargs: string[], opts: table): table|nil, string|nil}
function M.register(resolver)
  table.insert(registry, 1, resolver)
end

local function is_dir(path)
  return path and vim.fn.isdirectory(path) == 1
end

local function read_all(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

local function list_files(dir)
  local out = {}
  local prefix = dir:gsub("/$", "") .. "/"
  for _, path in
    ipairs(vim.fs.find(function(name)
      return name ~= ".git"
    end, { path = dir, type = "file", limit = math.huge }))
  do
    out[path:sub(#prefix + 1)] = path
  end
  return out
end

-- Builtin: two existing directories.
M.register({
  name = "dirs",
  match = function(fargs)
    return #fargs == 2 and is_dir(fargs[1]) and is_dir(fargs[2])
  end,
  resolve = function(fargs)
    local left_dir, right_dir = fargs[1], fargs[2]
    local lefts = list_files(left_dir)
    local rights = list_files(right_dir)
    local files = {}
    local paths = {}
    for rel in pairs(lefts) do
      paths[rel] = true
    end
    for rel in pairs(rights) do
      paths[rel] = true
    end
    local sorted = vim.tbl_keys(paths)
    table.sort(sorted)
    for _, rel in ipairs(sorted) do
      local left, right = lefts[rel], rights[rel]
      if left and right then
        if read_all(left) ~= read_all(right) then
          table.insert(files, { left = left, right = right, status = "M", path = rel })
        end
      elseif left then
        table.insert(files, { left = left, right = right_dir .. "/" .. rel, status = "D", path = rel })
      else
        -- Right-only: stage an empty left so the diff shows all-added.
        local staged = vim.fn.tempname()
        vim.fn.writefile({}, staged)
        table.insert(files, { left = staged, right = right, status = "A", path = rel })
      end
    end
    return { files = files, label = "dirs" }
  end,
})

-- Builtin: git ref (or bare = HEAD).
M.register({
  name = "git",
  match = function(fargs)
    return #fargs <= 1
  end,
  resolve = function(fargs, opts)
    local G = require("manicule.review.git")
    local cwd = opts.cwd or vim.uv.cwd()
    local root = G.root(cwd)
    if not root then
      return nil, "manicule: not a git repository and arguments are not directories"
    end
    local ref = fargs[1] or "HEAD"
    local base, err
    if ref == "HEAD" then
      base, err = G.rev_parse(root, "HEAD")
    else
      base, err = G.merge_base(root, "HEAD", ref)
    end
    if not base then
      return nil, err
    end
    local changed, cerr = G.changed_files(root, base)
    if not changed then
      return nil, cerr
    end
    if #changed == 0 then
      return nil, ("manicule: no changes vs %s"):format(ref)
    end
    local stage_dir = opts.stage_dir or vim.fn.tempname()
    vim.fn.mkdir(stage_dir, "p")
    return {
      files = G.stage_baseline(root, base, changed, stage_dir),
      label = ref,
    }
  end,
})

---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@return {files: table[], label: string}|nil, string|nil err
function M.resolve(fargs, opts)
  opts = opts or {}
  for _, resolver in ipairs(registry) do
    if resolver.match(fargs) then
      return resolver.resolve(fargs, opts)
    end
  end
  return nil, ("manicule: cannot resolve review arguments: %s"):format(table.concat(fargs, " "))
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test tests/manicule/review_sources_spec.lua`
Expected: PASS (4 tests).

- [ ] **Step 5: Run full suite, then commit**

Run: `make test`

```bash
git add lua/manicule/review/sources.lua tests/manicule/review_sources_spec.lua
git commit -m "feat(review): source resolvers for dirs and git refs"
```

---

### Task 5: `pr <n>` resolver via gh CLI

**Files:**
- Modify: `lua/manicule/review/sources.lua`
- Test: `tests/manicule/review_sources_spec.lua` (extend)

**Interfaces:**
- Consumes: Task 1's `G.*`, Task 4's `M.register`.
- Produces: `:ManiculeReview pr 123` resolution. Uses `gh pr view <n> --json baseRefOid,headRefOid` (octo.nvim pattern: shell out, gh owns auth).

**Behavior:** base = `merge_base(baseRefOid, headRefOid)`. If `rev_parse(root, "HEAD") == headRefOid`, right side is the worktree (normal pairs via `changed_files`+`stage_baseline`). Otherwise both sides are staged from git (`git fetch origin <headRefOid>` first if the oid is unknown locally); pairs come from `git diff --name-status base..headRefOid` and both left/right staged via `show_file` — comments then live on staged right files as session-scope records (documented limitation).

- [ ] **Step 1: Write the failing test** (append to `review_sources_spec.lua`; add a fake `gh` helper at the top of the file)

```lua
local function fake_gh(dir, base_oid, head_oid)
  local bin = dir .. "/bin"
  vim.fn.mkdir(bin, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    ('echo \'{"baseRefOid":"%s","headRefOid":"%s"}\''):format(base_oid, head_oid),
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return bin
end
```

Test:

```lua
  it("resolves pr <n> via gh with head checked out", function()
    local S = require("manicule.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)

    local bin = fake_gh(ctx.artifact_root, base_oid, head_oid)
    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path

    local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s3" })
    vim.env.PATH = saved_path

    assert.is_nil(err)
    assert.equals("pr 42", job.label)
    assert.equals(1, #job.files)
    assert.equals("a.lua", job.files[1].path)
    assert.equals(root .. "/a.lua", job.files[1].right)
  end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/manicule/review_sources_spec.lua`
Expected: FAIL — resolves to the git resolver error or "cannot resolve".

- [ ] **Step 3: Implement the resolver** (append to `sources.lua` after the git builtin, so it is matched FIRST — remember `register` prepends; register order in the file must be: dirs, git, pr → registry order pr, git, dirs. Verify `match` exclusivity: pr's match is `fargs[1] == "pr"`, git's match is `#fargs <= 1`, so order between them doesn't collide; keep dirs registered first in file so it ends up last and only catches real directory pairs.)

```lua
-- Builtin: GitHub PR via gh CLI (auth owned by gh, octo.nvim pattern).
M.register({
  name = "pr",
  match = function(fargs)
    return fargs[1] == "pr" and tonumber(fargs[2]) ~= nil
  end,
  resolve = function(fargs, opts)
    local G = require("manicule.review.git")
    if vim.fn.executable("gh") ~= 1 then
      return nil, "manicule: pr resolver requires the gh CLI (https://cli.github.com)"
    end
    local cwd = opts.cwd or vim.uv.cwd()
    local root = G.root(cwd)
    if not root then
      return nil, "manicule: not a git repository"
    end
    local number = fargs[2]
    local result = G.run({ "gh", "pr", "view", number, "--json", "baseRefOid,headRefOid" }, { cwd = root })
    if result.code ~= 0 then
      return nil, ("manicule: gh pr view failed: %s"):format(vim.trim(result.stderr))
    end
    local ok, meta = pcall(vim.json.decode, result.stdout)
    if not ok or type(meta) ~= "table" or not meta.headRefOid then
      return nil, "manicule: unexpected gh pr view output"
    end
    -- Ensure both oids exist locally before diffing.
    for _, oid in ipairs({ meta.baseRefOid, meta.headRefOid }) do
      if not G.rev_parse(root, oid) then
        local fetch = G.run({ "git", "-C", root, "fetch", "-q", "origin", oid })
        if fetch.code ~= 0 then
          return nil, ("manicule: cannot fetch %s: %s"):format(oid, vim.trim(fetch.stderr))
        end
      end
    end
    local base, err = G.merge_base(root, meta.baseRefOid, meta.headRefOid)
    if not base then
      return nil, err
    end
    local stage_dir = opts.stage_dir or vim.fn.tempname()
    vim.fn.mkdir(stage_dir, "p")
    local head = G.rev_parse(root, "HEAD")
    local label = ("pr %s"):format(number)

    if head == meta.headRefOid then
      -- PR head is checked out: right side = worktree, normal pairs.
      local changed, cerr = G.changed_files(root, base)
      if not changed then
        return nil, cerr
      end
      -- changed_files compares vs worktree; for a clean checkout this
      -- equals base..head. Filter out entries with no content diff is
      -- unnecessary — git already did it.
      if #changed == 0 then
        return nil, ("manicule: no changes in %s"):format(label)
      end
      return { files = G.stage_baseline(root, base, changed, stage_dir), label = label }
    end

    -- Head not checked out: stage BOTH sides (comments land on staged
    -- right files as session-scope records; documented limitation).
    local diff = G.run({ "git", "-C", root, "diff", "--name-status", "--no-renames", base, meta.headRefOid })
    if diff.code ~= 0 then
      return nil, ("manicule: git diff failed: %s"):format(vim.trim(diff.stderr))
    end
    local files = {}
    for line in diff.stdout:gmatch("[^\n]+") do
      local status, path = line:match("^(%a)%s+(.+)$")
      if status and path then
        if status ~= "A" and status ~= "D" then
          status = "M"
        end
        local left = stage_dir .. "/base/" .. path
        local right = stage_dir .. "/head/" .. path
        for side, ref in pairs({ [left] = base, [right] = meta.headRefOid }) do
          vim.fn.mkdir(vim.fn.fnamemodify(side, ":h"), "p")
          local fd = assert(io.open(side, "wb"))
          fd:write(G.show_file(root, ref, path) or "")
          fd:close()
        end
        table.insert(files, { left = left, right = right, status = status, path = path })
      end
    end
    if #files == 0 then
      return nil, ("manicule: no changes in %s"):format(label)
    end
    return { files = files, label = label }
  end,
})
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test tests/manicule/review_sources_spec.lua`
Expected: PASS.

- [ ] **Step 5: Run full suite, then commit**

Run: `make test`

```bash
git add lua/manicule/review/sources.lua tests/manicule/review_sources_spec.lua
git commit -m "feat(review): pr resolver via gh CLI"
```

---

### Task 6: Generic JSONL socket sink (`sinks/socket.lua`)

**Files:**
- Create: `lua/manicule/sinks/socket.lua`
- Modify: `lua/manicule/sinks/init.lua` (builtin registration)
- Test: `tests/manicule/socket_sink_spec.lua`

**Interfaces:**
- Consumes: sink registry contract (`register`, `dispatch` in `sinks/init.lua`).
- Produces: sink spec `name = "socket"`. `ctx` contract: `ctx.socket` (pipe path, required), `ctx.job` (opaque id string, optional), `ctx.label` (optional). Wire protocol, one JSON object per line:
  - nvim → consumer: `{"type":"hello","pid":<pid>,"job":"<id>"}` then `{"type":"submit","label":"<label>","comments":[{"path","lnum","end_lnum","body","side"}]}`
  - consumer → nvim: `{"type":"ack"}`
- On failure to connect/write/ack within `ack_timeout_ms` (default 2000): write the submit payload to `<dirname(ctx.socket)>/submit.json` and report `ok = false` with an error naming that file. `clear_on_success = true` (records deleted only after a real ack).

**Comment serialization:** `path` is project-relative when `record.project_root` is set (reuse `helpers.lua` relpath logic — check `sinks/helpers.lua` for an exported helper; the file has internal `relpath`; export it or replicate the 10 lines), `lnum`/`end_lnum` are 1-based (`record.range.start[1] + 1`), `side = "working"`.

- [ ] **Step 1: Write the failing tests**

Create `tests/manicule/socket_sink_spec.lua`:

```lua
local H = require("helpers")
local uv = vim.uv or vim.loop

local ctx

---Start an in-process JSONL pipe server. Returns { path, messages, close }.
local function pipe_server(reply_ack)
  local path = ctx.artifact_root .. "/srv-" .. tostring(math.random(1e6)) .. ".sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local messages = {}
  server:listen(16, function()
    local client = uv.new_pipe(false)
    server:accept(client)
    local buffer = ""
    client:read_start(function(err, chunk)
      assert(not err, err)
      if not chunk then
        return
      end
      buffer = buffer .. chunk
      while true do
        local line, rest = buffer:match("^(.-)\n(.*)$")
        if not line then
          break
        end
        buffer = rest
        local decoded = vim.json.decode(line)
        table.insert(messages, decoded)
        if decoded.type == "submit" and reply_ack then
          client:write(vim.json.encode({ type = "ack" }) .. "\n")
        end
      end
    end)
  end)
  return {
    path = path,
    messages = messages,
    close = function()
      server:close()
    end,
  }
end

describe("manicule socket sink", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("sends hello + submit as JSONL and succeeds on ack", function()
    local server = pipe_server(true)
    local spec = require("manicule.sinks.socket").setup({})
    local record = {
      body = "needs a guard",
      project_root = ctx.root,
      uri = "file://" .. ctx.root .. "/src/a.lua",
      range = { start = { 4, 0 }, end_ = { 6, 0 } },
    }

    local got_ok, got_err
    spec.send({ record }, { socket = server.path, job = "job-1", label = "since-review" }, function(ok, err)
      got_ok, got_err = ok, err
    end)
    vim.wait(2000, function()
      return got_ok ~= nil
    end)
    server.close()

    assert.is_true(got_ok, got_err)
    assert.equals("hello", server.messages[1].type)
    assert.equals("job-1", server.messages[1].job)
    local submit = server.messages[2]
    assert.equals("submit", submit.type)
    assert.equals("since-review", submit.label)
    assert.equals(1, #submit.comments)
    assert.equals("src/a.lua", submit.comments[1].path)
    assert.equals(5, submit.comments[1].lnum)
    assert.equals(7, submit.comments[1].end_lnum)
    assert.equals("needs a guard", submit.comments[1].body)
  end)

  it("falls back to submit.json when nothing acks", function()
    local sock_dir = ctx.artifact_root .. "/nowhere"
    vim.fn.mkdir(sock_dir, "p")
    local spec = require("manicule.sinks.socket").setup({ ack_timeout_ms = 100 })
    local record = {
      body = "orphaned",
      uri = "file://" .. ctx.root .. "/x.lua",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    }

    local got_ok, got_err
    spec.send({ record }, { socket = sock_dir .. "/missing.sock" }, function(ok, err)
      got_ok, got_err = ok, err
    end)
    vim.wait(2000, function()
      return got_ok ~= nil
    end)

    assert.is_false(got_ok)
    assert.is_truthy(got_err:find("submit.json", 1, true))
    local fallback = vim.json.decode(table.concat(vim.fn.readfile(sock_dir .. "/submit.json"), "\n"))
    assert.equals("submit", fallback.type)
    assert.equals(1, #fallback.comments)
  end)

  it("validate rejects a missing ctx.socket", function()
    local spec = require("manicule.sinks.socket").setup({})
    local ok, err = spec.validate({})
    assert.is_false(ok)
    assert.is_truthy(err)
  end)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/manicule/socket_sink_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `lua/manicule/sinks/socket.lua`**

```lua
-- manicule.nvim: generic JSONL-over-unix-socket sink.
--
-- Sends the comment batch as structured JSON lines to a local pipe
-- (unix socket / named pipe) supplied via ctx.socket. Any consumer can
-- listen — a coding-agent extension, a script, `nc -U`. Manicule does
-- not know or care who is on the other side.
--
-- Protocol (one JSON object per \n-terminated line):
--   -> {"type":"hello","pid":<pid>,"job":"<ctx.job>"}
--   -> {"type":"submit","label":"<ctx.label>","comments":[...]}
--   <- {"type":"ack"}
--
-- If connect/write/ack fails, the submit payload is written to
-- `<dirname(socket)>/submit.json` so comments are never lost.

local M = {}

local uv = vim.uv or vim.loop

local function defaults()
  return {
    ack_timeout_ms = 2000,
    clear_on_success = true,
  }
end

local function to_comment(record)
  local uri_mod = require("manicule.uri")
  local path = uri_mod.to_path(record.uri) or tostring(record.uri or "")
  local root = record.project_root
  if root and path:sub(1, #root + 1) == root .. "/" then
    path = path:sub(#root + 2)
  end
  local start_row = record.range and record.range.start and record.range.start[1] or 0
  local end_row = record.range and record.range.end_ and record.range.end_[1] or start_row
  return {
    path = path,
    lnum = start_row + 1,
    end_lnum = end_row + 1,
    body = record.body or "",
    side = "working",
  }
end

local function payload(comments, ctx)
  return {
    type = "submit",
    label = ctx.label,
    comments = vim.tbl_map(to_comment, comments),
  }
end

local function write_fallback(submit, ctx)
  local dir = vim.fn.fnamemodify(ctx.socket, ":h")
  local file = dir .. "/submit.json"
  local ok = pcall(vim.fn.writefile, { vim.json.encode(submit) }, file)
  return ok and file or nil
end

---@param opts? {ack_timeout_ms?: number, clear_on_success?: boolean}
---@return table sink spec
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults(), opts or {})
  return {
    name = "socket",
    type = "integration",
    label = "socket (JSONL)",
    description = "send structured comments to a local unix socket",
    clear_on_success = opts.clear_on_success ~= false,
    validate = function(ctx)
      if type(ctx.socket) ~= "string" or ctx.socket == "" then
        return false, "manicule: socket sink requires ctx.socket (pipe path)"
      end
      return true
    end,
    send = function(comments, ctx, cb)
      local submit = payload(comments, ctx)
      local pipe = uv.new_pipe(false)
      local finished = false
      local timer = uv.new_timer()

      local function finish(ok, err)
        if finished then
          return
        end
        finished = true
        timer:stop()
        timer:close()
        if not pipe:is_closing() then
          pipe:close()
        end
        if not ok then
          local file = write_fallback(submit, ctx)
          err = tostring(err or "socket send failed")
            .. (file and ("; comments saved to " .. file) or "; fallback write also failed")
        end
        vim.schedule(function()
          cb(ok, ok and nil or err)
        end)
      end

      timer:start(opts.ack_timeout_ms, 0, function()
        finish(false, "manicule: socket sink timed out waiting for ack")
      end)

      pipe:connect(ctx.socket, function(connect_err)
        if connect_err then
          finish(false, "manicule: socket connect failed: " .. tostring(connect_err))
          return
        end
        local buffer = ""
        pipe:read_start(function(read_err, chunk)
          if read_err then
            finish(false, "manicule: socket read failed: " .. tostring(read_err))
            return
          end
          if not chunk then
            finish(false, "manicule: socket closed before ack")
            return
          end
          buffer = buffer .. chunk
          local line = buffer:match("^(.-)\n")
          if line then
            local ok, decoded = pcall(vim.json.decode, line)
            if ok and type(decoded) == "table" and decoded.type == "ack" then
              finish(true)
            else
              finish(false, "manicule: unexpected socket reply: " .. line:sub(1, 120))
            end
          end
        end)
        local hello = vim.json.encode({ type = "hello", pid = uv.os_getpid(), job = ctx.job }) .. "\n"
        local body = vim.json.encode(submit) .. "\n"
        pipe:write(hello .. body, function(write_err)
          if write_err then
            finish(false, "manicule: socket write failed: " .. tostring(write_err))
          end
        end)
      end)
    end,
    health = function()
      return { transport = "unix socket (vim.uv pipe)", protocol = "jsonl-v1" }
    end,
  }
end

return M
```

- [ ] **Step 4: Register as builtin** in `lua/manicule/sinks/init.lua`:

In `builtin_integrations` add:

```lua
  socket = "manicule.sinks.socket",
```

In `builtin_defaults` add:

```lua
  socket = {
    enabled = true,
  },
```

(The socket module has no `is_available`, so it registers unconditionally when enabled; `validate` gates actual use on `ctx.socket`.) Also extend the `manicule.SinksConfig` annotation and validation in `lua/manicule/config.lua`:

```lua
---@field socket boolean|table Enable the bundled socket sink (default true). Accepts `ack_timeout_ms`.
```

and in the `opts.sinks` `vim.validate` block:

```lua
      ["sinks.socket"] = { opts.sinks.socket, { "boolean", "table" }, true },
```

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test tests/manicule/socket_sink_spec.lua` then `make test`
Expected: PASS. (Existing `sinks_spec.lua`/`health_spec.lua` may assert the exact builtin set — update those expectations to include `socket` if they fail.)

- [ ] **Step 6: Commit**

```bash
git add lua/manicule/sinks/socket.lua lua/manicule/sinks/init.lua lua/manicule/config.lua tests/manicule/socket_sink_spec.lua
git commit -m "feat(sinks): generic JSONL unix-socket sink"
```

---

### Task 7: `start_from_job` — external-driver entrypoint

**Files:**
- Modify: `lua/manicule/review.lua`
- Test: `tests/integration/review_spec.lua` (extend)

**Interfaces:**
- Consumes: Task 2's `R.start`, Task 6's socket sink.
- Produces (the pi extension's single entrypoint):
  - `R.start_from_job(path: string) -> boolean ok, string|nil err`

Job JSON schema (spec §Launch lifecycle):

```json
{ "id": "<id>",
  "label": "since-review",
  "return_socket": "/tmp/manicule-pi/<id>/sock",
  "files": [ {"left": "<staged>", "right": "<worktree>", "status": "M", "path": "src/a.lua"} ] }
```

- [ ] **Step 1: Write the failing test** (append to `review_spec.lua`)

```lua
  it("start_from_job wires files, label, and the socket sink", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    local job_path = ctx.artifact_root .. "/job.json"
    vim.fn.writefile({
      vim.json.encode({
        id = "job-7",
        label = "since-review",
        return_socket = ctx.artifact_root .. "/return.sock",
        files = files,
      }),
    }, job_path)

    assert.is_true(R.start_from_job(job_path))
    local state = R.state()
    assert.equals("since-review", state.label)
    assert.equals("socket", state.sink)
    assert.equals(ctx.artifact_root .. "/return.sock", state.sink_ctx.socket)
    assert.equals("job-7", state.sink_ctx.job)
  end)

  it("start_from_job rejects unreadable or invalid job files", function()
    local R = require("manicule.review")
    local ok, err = R.start_from_job(ctx.artifact_root .. "/absent.json")
    assert.is_false(ok)
    assert.is_truthy(err)

    local bad = ctx.artifact_root .. "/bad.json"
    vim.fn.writefile({ "{not json" }, bad)
    local ok2, err2 = R.start_from_job(bad)
    assert.is_false(ok2)
    assert.is_truthy(err2)
  end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/integration/review_spec.lua`
Expected: FAIL — `start_from_job` is nil.

- [ ] **Step 3: Implement** (add to `lua/manicule/review.lua` before `return M`)

```lua
---Start a review from a JSON job file written by an external driver
---(e.g. a coding-agent extension). Errors are returned AND notified so
---headless drivers see them on stderr.
---@param path string
---@return boolean ok, string|nil err
function M.start_from_job(path)
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    local err = ("manicule: cannot read job file %s"):format(path)
    vim.notify(err, vim.log.levels.ERROR)
    return false, err
  end
  local ok_decode, job = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(job) ~= "table" or type(job.files) ~= "table" then
    local err = ("manicule: invalid job file %s"):format(path)
    vim.notify(err, vim.log.levels.ERROR)
    return false, err
  end
  local sink_ctx = nil
  local sink = nil
  if type(job.return_socket) == "string" and job.return_socket ~= "" then
    sink = "socket"
    sink_ctx = { socket = job.return_socket, job = job.id, label = job.label }
  end
  local ok, err = M.start({
    files = job.files,
    label = job.label or "review",
    sink = sink,
    sink_ctx = sink_ctx,
  })
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
  end
  return ok, err
end
```

- [ ] **Step 4: Run to verify pass, full suite, commit**

Run: `scripts/test tests/integration/review_spec.lua` then `make test`

```bash
git add lua/manicule/review.lua tests/integration/review_spec.lua
git commit -m "feat(review): start_from_job entrypoint for external drivers"
```

---

### Task 8: `:ManiculeReview` command + navigation commands

**Files:**
- Modify: `plugin/manicule.lua`
- Test: `tests/integration/review_spec.lua` (extend)

**Interfaces:**
- Consumes: Task 4's `S.resolve`, Task 2/3's `R.start/next/prev/finish/stop`.
- Produces:
  - `:ManiculeReview [args...]` — resolve + start. Errors notify.
  - `:ManiculeReviewNext` / `:ManiculeReviewPrev` / `:ManiculeReviewFinish [sink]` / `:ManiculeReviewStop`
  - `<Plug>(manicule-review-next)` / `<Plug>(manicule-review-prev)`

- [ ] **Step 1: Write the failing test** (append to `review_spec.lua`)

```lua
  it(":ManiculeReview <ref> starts a session via the git resolver", function()
    local root = H.git_repo(ctx, { ["cmd.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/cmd.lua")
    local saved = vim.uv.cwd()
    vim.cmd.cd(root)

    vim.cmd("ManiculeReview HEAD")
    local state = require("manicule.review").state()
    vim.cmd.cd(saved)

    assert.is_truthy(state)
    assert.equals("HEAD", state.label)
    assert.equals(1, #state.files)
    assert.equals("cmd.lua", state.files[1].path)
  end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test tests/integration/review_spec.lua`
Expected: FAIL — `E492: Not an editor command: ManiculeReview` (note: `helpers.H.setup` clears `vim.g.loaded_manicule` and re-runs setup; check how existing command tests source `plugin/manicule.lua` — `workflow_spec.lua` shows the pattern; mirror it, e.g. `vim.cmd.runtime("plugin/manicule.lua")` after setup).

- [ ] **Step 3: Implement** (append to `plugin/manicule.lua`)

```lua
vim.api.nvim_create_user_command("ManiculeReview", function(opts)
  local sources = require("manicule.review.sources")
  local job, err = sources.resolve(opts.fargs, {})
  if not job then
    vim.notify(err or "manicule: cannot resolve review", vim.log.levels.ERROR)
    return
  end
  local ok, start_err = require("manicule.review").start(job)
  if not ok then
    vim.notify(start_err, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  complete = function(_, cmdline)
    -- Complete local branch names for the common `:ManiculeReview <ref>` case.
    if cmdline:match("ManiculeReview%s+%S*$") then
      local result = vim.system({ "git", "branch", "--format=%(refname:short)" }, { text = true }):wait()
      if result.code == 0 then
        return vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true })
      end
    end
    return {}
  end,
})

vim.api.nvim_create_user_command("ManiculeReviewNext", function()
  require("manicule.review").next()
end, {})

vim.api.nvim_create_user_command("ManiculeReviewPrev", function()
  require("manicule.review").prev()
end, {})

vim.api.nvim_create_user_command("ManiculeReviewFinish", function(opts)
  require("manicule.review").finish({ sink = opts.args ~= "" and opts.args or nil })
end, {
  nargs = "?",
  complete = function()
    return require("manicule.sinks").list()
  end,
})

vim.api.nvim_create_user_command("ManiculeReviewStop", function()
  require("manicule.review").stop()
end, {})

vim.keymap.set("n", "<Plug>(manicule-review-next)", function()
  require("manicule.review").next()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-review-prev)", function()
  require("manicule.review").prev()
end, { silent = true })
```

- [ ] **Step 4: Run to verify pass, full suite, commit**

Run: `make test`

```bash
git add plugin/manicule.lua tests/integration/review_spec.lua
git commit -m "feat(review): :ManiculeReview command and navigation"
```

---

### Task 9: Health check + docs

**Files:**
- Modify: `lua/manicule/health.lua` (inspect its existing shape first; add review-mode checks following the file's own pattern)
- Modify: `README.md`, `ARCHITECTURE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing documentation and `:checkhealth manicule` coverage.

- [ ] **Step 1: Health checks** — add to `lua/manicule/health.lua`, following its existing `vim.health.start/ok/warn` pattern:
  - `nvim.difftool`: `ok` when `pcall(vim.cmd.packadd, "nvim.difftool")` succeeds, otherwise `warn("nvim.difftool not available (needs Neovim 0.12+); review mode falls back to :diffsplit")`.
  - `gh`: `ok` when `vim.fn.executable("gh") == 1`, otherwise `info/warn("gh CLI not found; :ManiculeReview pr <n> disabled")`.
  - `git`: `ok` when `vim.fn.executable("git") == 1`, otherwise `warn`.

- [ ] **Step 2: README** — add a `## Review mode` section after `## Quickfix`:

```markdown
## Review mode

`:ManiculeReview` opens a diff-review session: baseline versions on the
left (read-only), your working tree on the right. Comment on the right
side as usual, then send the batch with `:ManiculeReviewFinish [sink]`.

    :ManiculeReview              " uncommitted changes (vs HEAD)
    :ManiculeReview main         " your branch vs merge-base with main
    :ManiculeReview pr 123       " a GitHub PR (requires gh CLI)
    :ManiculeReview <dirA> <dirB>" any two directories
    :ManiculeReviewNext          " next changed file
    :ManiculeReviewPrev          " previous changed file
    :ManiculeReviewStop          " close the session

Diffs render with the builtin `nvim.difftool` on Neovim 0.12+, falling
back to plain `:diffsplit`. The changed-file list is also published as
a quickfix list titled `manicule-review (...)`.

External tools can drive a review session by writing a JSON job file
and calling `require("manicule.review").start_from_job(path)`; comments
return through the bundled `socket` sink as JSONL over a unix socket.
```

- [ ] **Step 3: ARCHITECTURE.md** — extend the Module Map with the four new files and add a short `## Review Mode` section describing: session core (one active session, own tab, right = worktree), resolver registry (dirs/git/pr, `register()` extension point), socket sink protocol (hello/submit/ack JSONL, submit.json fallback), `start_from_job` driver contract. Update the sinks paragraph to mention `socket` as bundled.

- [ ] **Step 4: Run full suite, commit**

Run: `make test`

```bash
git add lua/manicule/health.lua README.md ARCHITECTURE.md
git commit -m "docs(review): review mode docs and health checks"
```

---

## Self-Review Notes

- Spec coverage: review core (T2), resolvers incl. registry openness (T4, T5), socket sink + fallback (T6), `start_from_job` (T7), command surface (T8), difftool-preferred/diffsplit-fallback (T2), VimLeavePre auto-flush (T3), health/docs (T9). Checkpoints/spawn/composer are plan 2 (pi extension) by design.
- Deviations executors may hit (verify, don't guess): exact prompt-faking helper name in `tests/helpers.lua` (T3/T7 tests), URI construction helper in `lua/manicule/uri.lua` (T3 Step 4 note), existing builtin-set assertions in `sinks_spec.lua`/`health_spec.lua` (T6 Step 5), plugin-file sourcing pattern in command tests (T8 Step 2), `difftool.open` window layout on 0.12 (T2 Step 4).
- VimLeavePre + async socket: the sink resolves its callback via `vim.schedule`; during `VimLeavePre` the loop still runs until exit, but if flakiness appears, add `vim.wait(ack_timeout_ms + 100, function() return done end)` in the autocmd wrapping `finish()` — the fallback file guarantees no data loss either way.
