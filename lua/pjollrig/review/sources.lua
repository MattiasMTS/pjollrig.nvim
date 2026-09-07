-- pjollrig.nvim: review source resolvers.
--
-- Turn `:PjollrigReview` arguments into staged diff pairs. Registry is
-- open: register({name, match, resolve}) prepends, so user resolvers
-- shadow builtins.
--
-- Two entry points share the registry:
--
--   * `M.resolve_async(fargs, opts, cb)` — the `:PjollrigReview` path.
--     The builtin git/pr resolvers run as spawn+callback continuations
--     (see review/git.lua's `_async` primitives), so the command
--     returns within a frame while rev-parse/merge-base/changed-files/
--     materialize (and, for `pr`, `gh pr view` + any fetch) run in the
--     background. The `chat` resolver (review/chat.lua) schedules its
--     transcript scan and continues through vim.ui.select callbacks.
--     Resolvers without a `resolve_async` (dirs, user registrations)
--     run their sync `resolve` inside one scheduled step: still off
--     the command's own frame, just not incremental.
--
--   * `M.resolve(fargs, opts)` — the synchronous back-compat API
--     (tests, external callers). For builtins it is a thin wrapper
--     driving the async chain with `vim.wait`, and it preserves the
--     historical side effect of importing PR comments before
--     returning; the async path defers that import to review.start_async
--     (post-open) via the job's `github_import` field.

local M = {}

local registry = {}
local uv = vim.uv

---Create a staging directory that does NOT match the nvim runtime staged-path
---pattern (nvim.<user>/<run-id>/<N>/...), so adapter.identify won't refuse
---comments on deleted files whose worktree path no longer exists.
---
---Uses $TMPDIR or /tmp directly, avoiding vim.fn.tempname() which nests under
---nvim.<user>/<run-id>/. The pattern matches any path containing that segment.
local function make_stage_dir()
  local tmpdir = os.getenv("TMPDIR") or "/tmp"
  tmpdir = tmpdir:gsub("/$", "") -- strip trailing slash
  local dir = uv.fs_mkdtemp(tmpdir .. "/pjollrig-review-XXXXXX")
  if not dir or dir == "" or dir == "/" then
    -- fs_mkdtemp failed; fall back to plain tempname and mkdir.
    -- This is a degraded path but won't block the review.
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

---Register a review source resolver. Resolvers are PREPENDED: on
---`:PjollrigReview <args>`, the most recently registered resolver whose
---`match(fargs)` accepts the arguments wins, so a registered resolver
---shadows the builtins (dirs/git/pr) — and later registrations shadow
---earlier ones. `resolve` returns a job for review.start
---(`{files, label?, sink?, ctx?, stage_dirs?}`) or `nil, err`. The
---optional `resolve_async(fargs, opts, cb)` delivers the same
---`job, err` pair through `cb` on the main loop; without it,
---`M.resolve_async` runs the sync `resolve` in one scheduled step.
---@param resolver {name: string, match: fun(fargs: string[]): boolean, resolve: fun(fargs: string[], opts: table): table|nil, string|nil, resolve_async?: fun(fargs: string[], opts: table, cb: fun(job: table|nil, err: string|nil))}
function M.register(resolver)
  vim.validate("resolver", resolver, "table")
  vim.validate("resolver.name", resolver.name, "string")
  vim.validate("resolver.match", resolver.match, "function")
  vim.validate("resolver.resolve", resolver.resolve, "function")
  vim.validate("resolver.resolve_async", resolver.resolve_async, "function", true)
  table.insert(registry, 1, resolver)
end

---Deliver an early resolver failure through `cb` WITHOUT running it in
---the caller's frame: resolve_async guarantees its callback always
---fires asynchronously on the main loop, success and failure alike.
---@param cb fun(job: table|nil, err: string|nil)
---@param err string
local function fail(cb, err)
  vim.schedule(function()
    cb(nil, err)
  end)
end

---How long the synchronous `M.resolve` wrapper waits for the async
---chain it drives. Generous on purpose: big changesets legitimately
---stage for a while, and the sync API's contract is "block until done".
local RESOLVE_SYNC_TIMEOUT_MS = 4 * 60 * 1000

---A synchronous `resolve` from an async one: drive the chain with
---`vim.wait` (the callbacks land via vim.schedule, which vim.wait
---pumps). Used by the builtins so each resolver has ONE implementation.
---@param resolve_async fun(fargs: string[], opts: table, cb: fun(job: table|nil, err: string|nil))
---@return fun(fargs: string[], opts: table): table|nil, string|nil
local function sync_from_async(resolve_async)
  return function(fargs, opts)
    local done = false
    local job, err
    resolve_async(fargs, opts, function(j, e)
      job, err, done = j, e, true
    end)
    vim.wait(RESOLVE_SYNC_TIMEOUT_MS, function()
      return done
    end, 5)
    if not done then
      return nil, "pjollrig: review resolve timed out"
    end
    return job, err
  end
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

---Do `left` and `right` hold identical bytes? Sizes are compared first
---(one fs_stat each): different sizes cannot match, so only same-size
---pairs pay the two full reads.
local function same_file(left, right)
  local lstat, rstat = uv.fs_stat(left), uv.fs_stat(right)
  if lstat and rstat and lstat.size ~= rstat.size then
    return false
  end
  return read_all(left) == read_all(right)
end

local function list_files(dir)
  local out = {}
  local base = dir:gsub("/$", "")
  -- vim.fs.find's name predicate cannot prune descent — the walk visits
  -- every directory and the predicate only filters what is RETURNED, so
  -- a `.git` predicate still walked the whole .git tree and returned its
  -- internals (HEAD, objects, ...) as reviewable files. vim.fs.dir's
  -- `skip` prunes the walk itself; entries named `.git` (worktree gitdir
  -- pointer files) are dropped from the results too, matching the old
  -- predicate's intent.
  for rel, type_ in
    vim.fs.dir(base, {
      depth = math.huge,
      skip = function(dir_rel)
        return dir_rel:match("[^/]+$") ~= ".git"
      end,
    })
  do
    if type_ == "file" and rel:match("[^/]+$") ~= ".git" then
      out[rel] = base .. "/" .. rel
    end
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
    -- ONE lazily-created stage dir shared by every right-only file: a
    -- per-file mkdtemp costs a subprocess-free but real syscall per
    -- added file and leaves N dirs for stop() cleanup to track.
    local stage_root
    for _, rel in ipairs(sorted) do
      local left, right = lefts[rel], rights[rel]
      if left and right then
        if not same_file(left, right) then
          table.insert(files, { left = left, right = right, status = "M", path = rel })
        end
      elseif left then
        table.insert(files, { left = left, right = right_dir .. "/" .. rel, status = "D", path = rel })
      else
        -- Right-only: stage an empty left so the diff shows all-added.
        stage_root = stage_root or make_stage_dir()
        local staged = stage_root .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(staged, ":h"), "p")
        vim.fn.writefile({}, staged)
        table.insert(files, { left = staged, right = right, status = "A", path = rel })
      end
    end
    return { files = files, label = "dirs", stage_dirs = stage_root and { stage_root } or nil }
  end,
})

-- Builtin: git ref (or bare = HEAD). One async implementation
-- (spawn+callback continuations over review/git.lua's `_async`
-- primitives); the sync `resolve` drives the same chain with vim.wait.
local function resolve_git_async(fargs, opts, cb)
  local G = require("pjollrig.review.git")
  local cwd = opts.cwd or vim.uv.cwd()
  G.root_async(cwd, function(root)
    if not root then
      return cb(nil, "pjollrig: not a git repository and arguments are not directories")
    end
    local ref = fargs[1] or "HEAD"
    local function with_base(base, err)
      if not base then
        return cb(nil, err)
      end
      G.changed_files_async(root, base, function(changed, cerr)
        if not changed then
          return cb(nil, cerr)
        end
        if #changed == 0 then
          return cb(nil, ("pjollrig: no changes vs %s"):format(ref))
        end
        -- Only a dir THIS resolver created is reported for stop()
        -- cleanup; a caller-provided stage_dir stays the caller's to
        -- manage.
        local stage_dir = opts.stage_dir
        local stage_dirs
        if not stage_dir then
          stage_dir = make_stage_dir()
          stage_dirs = { stage_dir }
        end
        G.stage_baseline_async(root, base, changed, stage_dir, function(files, serr)
          if not files then
            return cb(nil, serr)
          end
          cb({ files = files, label = ref, stage_dirs = stage_dirs })
        end)
      end)
    end
    if ref == "HEAD" then
      G.rev_parse_async(root, "HEAD", with_base)
    else
      G.merge_base_async(root, "HEAD", ref, with_base)
    end
  end)
end

M.register({
  name = "git",
  match = function(fargs)
    return #fargs <= 1
  end,
  resolve = sync_from_async(resolve_git_async),
  resolve_async = resolve_git_async,
})

---Make sure every oid in `oids` exists locally (fetching from origin
---when one does not), then `done(err|nil)`. Sequential on purpose: the
---common case is zero fetches, and two concurrent fetches into one
---repo buy nothing.
---@param root string
---@param oids string[]
---@param index integer
---@param done fun(err: string|nil)
local function ensure_oids(root, oids, index, done)
  local G = require("pjollrig.review.git")
  local oid = oids[index]
  if not oid then
    return done(nil)
  end
  G.rev_parse_async(root, oid, function(sha)
    if sha then
      return ensure_oids(root, oids, index + 1, done)
    end
    G.run_async({ "git", "-C", root, "fetch", "-q", "origin", oid }, nil, function(fetch)
      if fetch.code ~= 0 then
        return done(("pjollrig: cannot fetch %s: %s"):format(oid, vim.trim(fetch.stderr)))
      end
      ensure_oids(root, oids, index + 1, done)
    end)
  end)
end

-- Builtin: GitHub PR via gh CLI (auth owned by gh, octo.nvim pattern).
-- Async like the git resolver; additionally the network legs (`gh pr
-- view`, any fetch) run off the caller's frame. Comment import does
-- NOT happen here anymore: a checked-out-head job carries
-- `github_import = {root, number}` — review.start_async runs it after
-- the session is on screen, and the sync M.resolve wrapper runs it
-- before returning (the historical contract).
local function resolve_pr_async(fargs, opts, cb)
  local G = require("pjollrig.review.git")
  if vim.fn.executable("gh") ~= 1 then
    return fail(cb, "pjollrig: pr resolver requires the gh CLI (https://cli.github.com)")
  end
  local cwd = opts.cwd or vim.uv.cwd()
  local number = fargs[2]
  G.root_async(cwd, function(root)
    if not root then
      return cb(nil, "pjollrig: not a git repository")
    end
    G.run_async(
      { "gh", "pr", "view", number, "--json", "baseRefOid,headRefOid,title" },
      { cwd = root },
      function(result)
        if result.code ~= 0 then
          return cb(nil, ("pjollrig: gh pr view failed: %s"):format(vim.trim(result.stderr)))
        end
        local ok, meta = pcall(vim.json.decode, result.stdout)
        if not ok or type(meta) ~= "table" or not meta.headRefOid then
          return cb(nil, "pjollrig: unexpected gh pr view output")
        end
        -- Ensure both oids exist locally before diffing.
        ensure_oids(root, { meta.baseRefOid, meta.headRefOid }, 1, function(oid_err)
          if oid_err then
            return cb(nil, oid_err)
          end
          G.merge_base_async(root, meta.baseRefOid, meta.headRefOid, function(base, err)
            if not base then
              return cb(nil, err)
            end
            -- Same ownership rule as the git resolver: report only a
            -- self-created stage dir for stop() cleanup.
            local stage_dir = opts.stage_dir
            local stage_dirs
            if not stage_dir then
              stage_dir = make_stage_dir()
              stage_dirs = { stage_dir }
            end
            local label = ("pr %s"):format(number)
            if type(meta.title) == "string" and meta.title ~= "" then
              label = ("%s: %s"):format(label, meta.title)
            end
            -- Carry the PR number into the session's sink context:
            -- without it, `:PjollrigReviewFinish github` falls back to
            -- `gh pr view` on the CURRENT branch and posts a
            -- non-checked-out PR's review to the wrong PR (or fails
            -- confusingly).
            local ctx = { pr = tonumber(number) }
            G.rev_parse_async(root, "HEAD", function(head)
              if head == meta.headRefOid then
                -- PR head is checked out: right side = worktree, normal
                -- pairs — real files existing PR review comments can
                -- anchor to, hence the github_import marker.
                G.changed_files_async(root, base, function(changed, cerr)
                  if not changed then
                    return cb(nil, cerr)
                  end
                  -- changed_files compares vs worktree; for a clean
                  -- checkout this equals base..head. Filtering entries
                  -- with no content diff is unnecessary — git already
                  -- did it.
                  if #changed == 0 then
                    return cb(nil, ("pjollrig: no changes in %s"):format(label))
                  end
                  G.stage_baseline_async(root, base, changed, stage_dir, function(files, serr)
                    if not files then
                      return cb(nil, serr)
                    end
                    cb({
                      files = files,
                      label = label,
                      ctx = ctx,
                      stage_dirs = stage_dirs,
                      github_import = { root = root, number = number },
                    })
                  end)
                end)
                return
              end

              -- Head not checked out: stage BOTH sides (comments land on
              -- staged right files as session-scope records; documented
              -- limitation). Existing PR comments are NOT imported here:
              -- both sides are temp paths with session-scope identity,
              -- not worth anchoring to.
              vim.notify(
                ("pjollrig: %s head is not checked out; skipping GitHub comment import"):format(label),
                vim.log.levels.INFO
              )
              -- `-z` keeps paths literal: without it core.quotePath=true
              -- C-quotes non-ASCII names and the quoted string would
              -- become entry.path.
              G.run_async(
                { "git", "-C", root, "diff", "--name-status", "--no-renames", "-z", base, meta.headRefOid },
                nil,
                function(diff)
                  if diff.code ~= 0 then
                    return cb(nil, ("pjollrig: git diff failed: %s"):format(vim.trim(diff.stderr)))
                  end
                  local entries = G.parse_name_status(diff.stdout)
                  if #entries == 0 then
                    return cb(nil, ("pjollrig: no changes in %s"):format(label))
                  end
                  -- Stage each side with one batched materialize pass
                  -- (chunked `git archive` + `tar`, see
                  -- docs/performance.md) instead of two `git show` forks
                  -- per file. The side a file does not exist on (base for
                  -- "A", head for "D") gets an empty staged file so the
                  -- diff shows all-added/all-removed.
                  local base_dir = stage_dir .. "/base"
                  local head_dir = stage_dir .. "/head"
                  local base_paths, head_paths = {}, {}
                  for _, entry in ipairs(entries) do
                    if entry.status ~= "A" then
                      table.insert(base_paths, entry.path)
                    end
                    if entry.status ~= "D" then
                      table.insert(head_paths, entry.path)
                    end
                  end
                  G.materialize_async(root, base, base_paths, base_dir, function(base_err)
                    if base_err then
                      return cb(nil, base_err)
                    end
                    G.materialize_async(root, meta.headRefOid, head_paths, head_dir, function(head_err)
                      if head_err then
                        return cb(nil, head_err)
                      end
                      local files = {}
                      for _, entry in ipairs(entries) do
                        local left = base_dir .. "/" .. entry.path
                        local right = head_dir .. "/" .. entry.path
                        local empty = (entry.status == "A" and left) or (entry.status == "D" and right)
                        if empty then
                          vim.fn.mkdir(vim.fn.fnamemodify(empty, ":h"), "p")
                          vim.fn.writefile({}, empty)
                        end
                        table.insert(files, { left = left, right = right, status = entry.status, path = entry.path })
                      end
                      cb({ files = files, label = label, ctx = ctx, stage_dirs = stage_dirs })
                    end)
                  end)
                end
              )
            end)
          end)
        end)
      end
    )
  end)
end

M.register({
  name = "pr",
  match = function(fargs)
    return fargs[1] == "pr" and tonumber(fargs[2]) ~= nil
  end,
  resolve = sync_from_async(resolve_pr_async),
  resolve_async = resolve_pr_async,
})

-- Builtin: an assistant turn from a Claude Code session transcript,
-- reviewed as a markdown document (review/chat.lua: `chat`, `chat <n>`,
-- `chat all`). Registered unconditionally — like `pr` with gh missing, a
-- missing ~/.claude/projects fails the resolve with a clear message
-- instead of hiding the keyword. Registered AFTER git so it shadows the
-- bare-ref match for `chat`. Its vim.ui.select pickers continue the
-- resolve_async chain, so they open over the already-visible review
-- shell and need no registry support beyond the per-resolver
-- `resolve_async`; the module loads lazily, only when `chat` is used.
local function resolve_chat_async(fargs, opts, cb)
  return require("pjollrig.review.chat").resolve_async(fargs, opts, cb)
end

M.register({
  name = "chat",
  match = function(fargs)
    return fargs[1] == "chat"
  end,
  resolve = sync_from_async(resolve_chat_async),
  resolve_async = resolve_chat_async,
})

---@param fargs string[]
---@return table|nil resolver
local function resolver_for(fargs)
  for _, resolver in ipairs(registry) do
    if resolver.match(fargs) then
      return resolver
    end
  end
  return nil
end

---Synchronous resolve (back-compat API: tests, external callers).
---Blocks until the job is fully staged. The pr resolver's comment
---import — deferred to post-open on the async path — runs here before
---returning, preserving the historical contract that a returned pr job
---already has its GitHub comments in the store.
---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@return {files: table[], label: string, ctx?: table, stage_dirs?: string[]}|nil, string|nil err
function M.resolve(fargs, opts)
  opts = opts or {}
  local resolver = resolver_for(fargs)
  if not resolver then
    return nil, ("pjollrig: cannot resolve review arguments: %s"):format(table.concat(fargs, " "))
  end
  local job, err = resolver.resolve(fargs, opts)
  if job and job.github_import then
    require("pjollrig.review.import").github_pr(job.github_import.root, job.github_import.number)
    job.github_import = nil
  end
  return job, err
end

---Asynchronous resolve — the `:PjollrigReview` path. Returns
---immediately; `cb(job, err)` fires on the main loop once staging is
---complete (never in the caller's frame). Resolvers without a
---`resolve_async` run their sync `resolve` inside one scheduled step,
---so the command still returns first. A pr job may carry
---`github_import = {root, number}`: the caller owns kicking that
---import once the session is open (review.start_async does).
---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@param cb fun(job: {files: table[], label: string, ctx?: table, stage_dirs?: string[], github_import?: {root: string, number: string|integer}}|nil, err: string|nil)
function M.resolve_async(fargs, opts, cb)
  opts = opts or {}
  local resolver = resolver_for(fargs)
  if not resolver then
    return fail(cb, ("pjollrig: cannot resolve review arguments: %s"):format(table.concat(fargs, " ")))
  end
  if resolver.resolve_async then
    return resolver.resolve_async(fargs, opts, cb)
  end
  vim.schedule(function()
    cb(resolver.resolve(fargs, opts))
  end)
end

return M
