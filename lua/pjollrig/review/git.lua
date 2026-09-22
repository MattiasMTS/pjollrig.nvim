-- pjollrig.nvim: git plumbing for review mode.
--
-- Thin wrappers around `git` used to resolve baselines and stage
-- baseline file versions for diff pairs. No global state. Every
-- blocking primitive has an `_async` twin whose callback fires on the
-- main loop, so the resolvers can run as spawn+callback continuations
-- (`:PjollrigReview` returns within a frame; see sources.resolve_async).

local M = {}

local uv = vim.uv

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

---Spawn `argv` WITHOUT waiting, so independent subprocesses can run
---concurrently; callers `:wait()` the returned handle (see M.wait for
---the normalized result). A module function, like `M.run`, so tests can
---observe subprocess fan-out. Throws when the executable is missing —
---the same loud failure `M.run` has.
---@param argv string[]
---@param opts? {cwd?: string}
---@return vim.SystemObj
function M.spawn(argv, opts)
  opts = opts or {}
  return vim.system(argv, { text = true, cwd = opts.cwd })
end

---Join a handle from `M.spawn`, normalizing the result like `M.run`.
---@param handle vim.SystemObj
---@return {code: integer, stdout: string, stderr: string}
function M.wait(handle)
  local result = handle:wait()
  return {
    code = result.code or -1,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

---Run `argv` asynchronously; `cb` receives the `M.run`-normalized
---result on the main loop (vim.system's on_exit fires in a fast-event
---context, so the callback is rescheduled). A spawn failure (missing
---executable) does NOT throw like `M.run` — an async chain has no
---caller stack to throw into — it reports `code = -1` plus the error
---text as `spawn_err`, so callers can stay loud about hard failures.
---The module-function seam mirrors `M.run`/`M.spawn`: tests observe
---async subprocess traffic by stubbing it.
---@param argv string[]
---@param opts? {cwd?: string}
---@param cb fun(result: {code: integer, stdout: string, stderr: string}, spawn_err?: string)
function M.run_async(argv, opts, cb)
  opts = opts or {}
  local ok, err = pcall(vim.system, argv, { text = true, cwd = opts.cwd }, function(result)
    vim.schedule(function()
      cb({
        code = result.code or -1,
        stdout = result.stdout or "",
        stderr = result.stderr or "",
      })
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = -1, stdout = "", stderr = tostring(err) }, tostring(err))
    end)
  end
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

---Async `M.root`; `cb(root|nil)` fires on the main loop.
---@param dir string
---@param cb fun(root: string|nil)
function M.root_async(dir, cb)
  M.run_async({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, nil, function(result)
    cb(result.code == 0 and trim(result.stdout) or nil)
  end)
end

---@param root string
---@param ref string
---@return string|nil sha, string|nil err
function M.rev_parse(root, ref)
  local result = git(root, "rev-parse", "--verify", ref .. "^{commit}")
  if result.code ~= 0 then
    return nil, ("pjollrig: cannot resolve ref %q: %s"):format(ref, trim(result.stderr))
  end
  return trim(result.stdout), nil
end

---Async `M.rev_parse`; `cb(sha|nil, err|nil)` fires on the main loop.
---@param root string
---@param ref string
---@param cb fun(sha: string|nil, err: string|nil)
function M.rev_parse_async(root, ref, cb)
  M.run_async({ "git", "-C", root, "rev-parse", "--verify", ref .. "^{commit}" }, nil, function(result)
    if result.code ~= 0 then
      cb(nil, ("pjollrig: cannot resolve ref %q: %s"):format(ref, trim(result.stderr)))
      return
    end
    cb(trim(result.stdout), nil)
  end)
end

---@param root string
---@param a string
---@param b string
---@return string|nil sha, string|nil err
function M.merge_base(root, a, b)
  local result = git(root, "merge-base", a, b)
  if result.code ~= 0 then
    return nil, ("pjollrig: merge-base %s %s failed: %s"):format(a, b, trim(result.stderr))
  end
  return trim(result.stdout), nil
end

---Async `M.merge_base`; `cb(sha|nil, err|nil)` fires on the main loop.
---@param root string
---@param a string
---@param b string
---@param cb fun(sha: string|nil, err: string|nil)
function M.merge_base_async(root, a, b, cb)
  M.run_async({ "git", "-C", root, "merge-base", a, b }, nil, function(result)
    if result.code ~= 0 then
      cb(nil, ("pjollrig: merge-base %s %s failed: %s"):format(a, b, trim(result.stderr)))
      return
    end
    cb(trim(result.stdout), nil)
  end)
end

---Untracked paths from NUL-separated `git status --porcelain=v1 -z`
---output. Preferred over `ls-files --others`: status uses the untracked
---cache and fsmonitor, ls-files always walks the worktree (~3x slower on
---large repos). Status collapses fully-untracked directories to `dir/`;
---those are expanded with a *scoped* ls-files, which is cheap because it
---only walks the collapsed directory.
---@param stdout string
---@return string[] paths, string[] collapsed
local function parse_untracked(stdout)
  local paths = {}
  local collapsed = {}
  for record in stdout:gmatch("[^%z]+") do
    local path = record:match("^%?%? (.+)$")
    if path then
      if path:sub(-1) == "/" then
        table.insert(collapsed, path)
      else
        table.insert(paths, path)
      end
    end
  end
  return paths, collapsed
end

---Append the ls-files expansion of collapsed directories to `paths`.
---@param paths string[]
---@param stdout string scoped `ls-files --others` output
local function append_expanded(paths, stdout)
  for sub in stdout:gmatch("[^\n]+") do
    table.insert(paths, sub)
  end
end

---Scoped `ls-files --others` argv expanding `collapsed` directories.
---One subprocess stays cheap regardless of how many directories
---collapsed: the walk only descends into those directories.
---@param root string
---@param collapsed string[]
---@return string[]
local function expand_argv(root, collapsed)
  local argv = { "git", "-C", root, "ls-files", "--others", "--exclude-standard", "--" }
  vim.list_extend(argv, collapsed)
  return argv
end

---@param root string
---@param stdout string
---@return string[] paths
local function untracked_from_status(root, stdout)
  local paths, collapsed = parse_untracked(stdout)
  -- Expand ALL collapsed directories with one scoped ls-files call.
  if #collapsed > 0 then
    local expanded = M.run(expand_argv(root, collapsed))
    if expanded.code == 0 then
      append_expanded(paths, expanded.stdout)
    end
  end
  return paths
end

---Entries from NUL-separated `git diff --name-status -z` output
---(`STATUS\0path\0STATUS\0path\0...`). Without `-z`, core.quotePath=true
---(the default) C-quotes non-ASCII paths (`"\303\245.txt"`) and the
---quoted string would leak into entry.path, so callers MUST pass `-z`.
---Rename/copy statuses (`R<score>`/`C<score>`) carry TWO paths
---(`old\0new\0`); the destination is kept so the stream stays aligned
---even though callers pass `--no-renames` today.
---Rare statuses (T, R, C, ...) collapse into "M"; we only branch on A/D.
---@param stdout string
---@return {path: string, status: "M"|"A"|"D"}[]
function M.parse_name_status(stdout)
  local tokens = {}
  for token in (stdout or ""):gmatch("[^%z]+") do
    tokens[#tokens + 1] = token
  end
  local entries = {}
  local i = 1
  while i < #tokens do
    local status = tokens[i]:sub(1, 1)
    local path = tokens[i + 1]
    i = i + 2
    if (status == "R" or status == "C") and i <= #tokens then
      -- Two-path record: source first, then the destination.
      path = tokens[i]
      i = i + 1
    end
    if status ~= "A" and status ~= "D" then
      status = "M"
    end
    entries[#entries + 1] = { path = path, status = status }
  end
  return entries
end

---Merge diff entries with untracked "A" paths, deduped and sorted —
---the tail shared by the sync and async changed_files variants.
---@param diff_stdout string
---@param untracked string[]
---@return {path: string, status: "M"|"A"|"D"}[]
local function assemble_entries(diff_stdout, untracked)
  local entries = {}
  local seen = {}
  for _, entry in ipairs(M.parse_name_status(diff_stdout)) do
    if not seen[entry.path] then
      seen[entry.path] = true
      table.insert(entries, entry)
    end
  end
  for _, path in ipairs(untracked) do
    if not seen[path] then
      seen[path] = true
      table.insert(entries, { path = path, status = "A" })
    end
  end
  table.sort(entries, function(x, y)
    return x.path < y.path
  end)
  return entries
end

local function diff_argv(root, base)
  return { "git", "-C", root, "diff", "--name-status", "--no-renames", "-z", base }
end

local function status_argv(root)
  return { "git", "-C", root, "status", "--porcelain=v1", "-z", "--no-renames" }
end

---Changed files vs `base`, including untracked files as "A".
---@param root string
---@param base string
---@return {path: string, status: "M"|"A"|"D"}[]|nil, string|nil err
function M.changed_files(root, base)
  -- Run diff and status concurrently; each costs ~100ms on large repos
  -- and they are independent.
  local diff_job = vim.system(diff_argv(root, base), { text = true })
  local status_job = vim.system(status_argv(root), { text = true })
  local result = diff_job:wait()
  local untracked = status_job:wait()
  if result.code ~= 0 then
    return nil, ("pjollrig: git diff failed: %s"):format(trim(result.stderr or ""))
  end
  local paths = untracked.code == 0 and untracked_from_status(root, untracked.stdout or "") or {}
  return assemble_entries(result.stdout or "", paths), nil
end

---Async `M.changed_files`: diff and status still fan out concurrently,
---joined by callback; any collapsed-directory expansion runs as one
---more async subprocess. `cb(entries|nil, err|nil)` on the main loop.
---@param root string
---@param base string
---@param cb fun(entries: {path: string, status: "M"|"A"|"D"}[]|nil, err: string|nil)
function M.changed_files_async(root, base, cb)
  local diff_result, status_result
  local pending = 2
  local function join()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if diff_result.code ~= 0 then
      cb(nil, ("pjollrig: git diff failed: %s"):format(trim(diff_result.stderr or "")))
      return
    end
    local paths, collapsed = {}, {}
    if status_result.code == 0 then
      paths, collapsed = parse_untracked(status_result.stdout or "")
    end
    if #collapsed == 0 then
      cb(assemble_entries(diff_result.stdout or "", paths), nil)
      return
    end
    M.run_async(expand_argv(root, collapsed), nil, function(expanded)
      if expanded.code == 0 then
        append_expanded(paths, expanded.stdout)
      end
      cb(assemble_entries(diff_result.stdout or "", paths), nil)
    end)
  end
  M.run_async(diff_argv(root, base), nil, function(result)
    diff_result = result
    join()
  end)
  M.run_async(status_argv(root), nil, function(result)
    status_result = result
    join()
  end)
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

---mkdir -p; `known_dirs` caches directories already confirmed
---to exist so repeated calls stay cheap.
---@param path string
---@param known_dirs table<string, boolean>
local function mkdir_p(path, known_dirs)
  if known_dirs[path] then
    return
  end
  assert(vim.fn.mkdir(path, "p", 493) == 1, "pjollrig: cannot create staging directory " .. path)
  known_dirs[path] = true
end

---Write `content` to `path` as a regular file, creating parent
---directories and replacing any non-file already there (e.g. a symlink
---tar extracted from an archive).
---@param path string
---@param content string
---@param known_dirs table<string, boolean>
local function write_regular(path, content, known_dirs)
  local parent = path:match("^(.*)/[^/]+$")
  if parent then
    mkdir_p(parent, known_dirs)
  end
  local stat = uv.fs_lstat(path)
  if stat and stat.type ~= "file" then
    local ok, err = uv.fs_unlink(path)
    assert(ok, ("pjollrig: cannot replace staged baseline %s: %s"):format(path, tostring(err)))
  end
  local fd, err = uv.fs_open(path, "w", 438) -- 0666, filtered by umask
  assert(fd, ("pjollrig: cannot stage baseline %s: %s"):format(path, tostring(err)))
  local _, write_err = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  assert(not write_err, ("pjollrig: cannot write staged baseline %s: %s"):format(path, tostring(write_err)))
end

---Materialize the blob contents of `paths` at `ref` under `dir`,
---mirroring relative paths. Batched: chunked `git archive` + `tar`
---subprocesses instead of one `git show` fork per file (numbers in
---docs/performance.md) — archives for all chunks fan out concurrently,
---extractions join them in order — with a per-file `git show` self-heal
---for anything archive missed. Paths absent at `ref` become empty regular
---files; symlink blobs become regular files holding the link target.
---Requires the `tar` executable and fails loudly when it is missing.
---@param root string
---@param ref string
---@param paths string[]
---@param dir string
---Split `paths` into `git archive` pathspec chunks.
---
---`git archive` has no pathspec-from-file support (including Git 2.55),
---so keep each argv comfortably below platform ARG_MAX instead. Bound
---path count too: archive's pathspec matching slows sharply with a huge
---flat argv even below ARG_MAX (200-path chunks benchmark faster).
---@param root string
---@param ref string
---@param dir string
---@param paths string[]
---@return string[][]
local function archive_chunks(root, ref, dir, paths)
  local max_argv_bytes = 64 * 1024
  local max_paths_per_chunk = 200
  local base_bytes = #root + #ref + #dir + 1024
  local chunks = {}
  local chunk = {}
  local chunk_bytes = base_bytes

  for _, path in ipairs(paths) do
    local path_bytes = #path + 1
    if #chunk > 0 and (chunk_bytes + path_bytes > max_argv_bytes or #chunk >= max_paths_per_chunk) then
      chunks[#chunks + 1] = chunk
      chunk = {}
      chunk_bytes = base_bytes
    end
    table.insert(chunk, path)
    chunk_bytes = chunk_bytes + path_bytes
  end
  if #chunk > 0 then
    chunks[#chunks + 1] = chunk
  end
  return chunks
end

---@param root string
---@param ref string
---@param archive_path string
---@param chunk_paths string[]
---@return string[]
local function archive_argv(root, ref, archive_path, chunk_paths)
  local argv = { "git", "-C", root, "--literal-pathspecs", "archive", "-o", archive_path, ref, "--" }
  vim.list_extend(argv, chunk_paths)
  return argv
end

---The per-file recovery pass closing out a materialize: anything a
---failed chunk covered — or that extraction left missing or as a
---non-regular file (symlink blobs) — is staged via `git show`, with
---paths absent at `ref` becoming empty regular files.
---@param root string
---@param ref string
---@param paths string[]
---@param dir string
---@param failed_paths table<string, true>
---@param known_dirs table<string, boolean>
local function self_heal(root, ref, paths, dir, failed_paths, known_dirs)
  for _, path in ipairs(paths) do
    local staged = dir .. "/" .. path
    local stat = uv.fs_lstat(staged)
    if failed_paths[path] or not stat or stat.type ~= "file" then
      write_regular(staged, M.show_file(root, ref, path) or "", known_dirs)
    end
  end
end

function M.materialize(root, ref, paths, dir)
  local known_dirs = {}
  mkdir_p(dir, known_dirs)

  local chunks = archive_chunks(root, ref, dir, paths)

  -- Chunks are independent (distinct pathspecs, distinct archive
  -- tempfiles, one shared output dir): fan out ALL `git archive`
  -- subprocesses first, then join each and extract its tar, so
  -- archives N+1.. run while tar N extracts instead of serializing
  -- archive/tar pairs. Extraction itself stays sequential — concurrent
  -- tars into one tree would race on shared parent directories.
  -- `tar` must exist: M.run throws when it is missing.
  local failed_paths = {}
  local jobs = {}
  for i, chunk_paths in ipairs(chunks) do
    local archive_path = vim.fn.tempname() .. ".tar"
    jobs[i] = {
      paths = chunk_paths,
      archive = archive_path,
      handle = M.spawn(archive_argv(root, ref, archive_path, chunk_paths)),
    }
  end
  for _, job in ipairs(jobs) do
    local archive_result = M.wait(job.handle)
    local tar_result = M.run({ "tar", "-xf", job.archive, "-C", dir })
    pcall(uv.fs_unlink, job.archive)

    if archive_result.code ~= 0 or tar_result.code ~= 0 then
      for _, path in ipairs(job.paths) do
        failed_paths[path] = true
      end
    end
  end

  self_heal(root, ref, paths, dir, failed_paths, known_dirs)
end

---Async `M.materialize`: every `git archive` chunk fans out
---immediately; each chunk's tar runs from its archive's completion
---callback, with extractions still serialized (concurrent tars into
---one tree race on shared parent directories) while later archives
---keep running. The self-heal pass runs once every chunk has settled,
---then `cb(err)` fires on the main loop — `err` is non-nil only for a
---hard failure (tar unavailable, staging dir unwritable), keeping the
---sync version's loud tar failure, now surfaced through the chain
---instead of a throw.
---@param root string
---@param ref string
---@param paths string[]
---@param dir string
---@param cb fun(err: string|nil)
function M.materialize_async(root, ref, paths, dir, cb)
  local known_dirs = {}
  local ok_mkdir, mkdir_err = pcall(mkdir_p, dir, known_dirs)
  if not ok_mkdir then
    vim.schedule(function()
      cb(tostring(mkdir_err))
    end)
    return
  end

  local chunks = archive_chunks(root, ref, dir, paths)
  local failed_paths = {}
  local settled = 0
  local hard_err = nil
  local queue = {}
  local extracting = false

  local function finish_if_done()
    if settled < #chunks or extracting or #queue > 0 then
      return
    end
    if hard_err then
      cb(hard_err)
      return
    end
    local ok, err = pcall(self_heal, root, ref, paths, dir, failed_paths, known_dirs)
    if ok then
      cb(nil)
    else
      cb(tostring(err))
    end
  end

  local function pump()
    if extracting then
      return
    end
    local job = table.remove(queue, 1)
    if not job then
      finish_if_done()
      return
    end
    extracting = true
    local function settle(tar_code, spawn_err)
      pcall(uv.fs_unlink, job.archive)
      if job.code ~= 0 or tar_code ~= 0 then
        for _, path in ipairs(job.paths) do
          failed_paths[path] = true
        end
      end
      if spawn_err then
        hard_err = hard_err or ("pjollrig: cannot extract staged baselines: %s"):format(spawn_err)
      end
      settled = settled + 1
      extracting = false
      pump()
    end
    if job.code ~= 0 then
      settle(0) -- the archive itself failed: nothing to extract, self-heal covers it
      return
    end
    M.run_async({ "tar", "-xf", job.archive, "-C", dir }, nil, function(result, spawn_err)
      settle(result.code, spawn_err)
    end)
  end

  if #chunks == 0 then
    vim.schedule(finish_if_done)
    return
  end
  for _, chunk_paths in ipairs(chunks) do
    local archive_path = vim.fn.tempname() .. ".tar"
    M.run_async(archive_argv(root, ref, archive_path, chunk_paths), nil, function(result)
      queue[#queue + 1] = { paths = chunk_paths, archive = archive_path, code = result.code }
      pump()
    end)
  end
end

---Write baseline versions of `entries` under `dir`, mirroring relative
---paths. Returns diff pairs; `right` always names the worktree path even
---when the file was deleted (callers branch on `status == "D"`).
---The post-materialize tail shared by both stage_baseline variants:
---stage an empty left for every "A" entry (so the diff shows
---all-added) and build the diff pairs.
---@param root string
---@param entries {path: string, status: string}[]
---@param dir string
---@return {left: string, right: string, status: string, path: string}[]
local function baseline_pairs(root, entries, dir)
  local known_dirs = {}
  local files = {}
  for _, entry in ipairs(entries) do
    local left = dir .. "/" .. entry.path
    if entry.status == "A" then
      write_regular(left, "", known_dirs)
    end
    table.insert(files, {
      left = left,
      right = root .. "/" .. entry.path,
      status = entry.status,
      path = entry.path,
    })
  end
  return files
end

---@param root string
---@param base string
---@param entries {path: string, status: string}[]
---@param dir string
---@return {left: string, right: string, status: string, path: string}[]
function M.stage_baseline(root, base, entries, dir)
  local tracked = {}
  for _, entry in ipairs(entries) do
    if entry.status ~= "A" then
      table.insert(tracked, entry.path)
    end
  end
  M.materialize(root, base, tracked, dir)
  return baseline_pairs(root, entries, dir)
end

---Async `M.stage_baseline`; `cb(files|nil, err|nil)` on the main loop.
---@param root string
---@param base string
---@param entries {path: string, status: string}[]
---@param dir string
---@param cb fun(files: {left: string, right: string, status: string, path: string}[]|nil, err: string|nil)
function M.stage_baseline_async(root, base, entries, dir, cb)
  local tracked = {}
  for _, entry in ipairs(entries) do
    if entry.status ~= "A" then
      table.insert(tracked, entry.path)
    end
  end
  M.materialize_async(root, base, tracked, dir, function(err)
    if err then
      cb(nil, err)
      return
    end
    local ok, files = pcall(baseline_pairs, root, entries, dir)
    if ok then
      cb(files, nil)
    else
      cb(nil, tostring(files))
    end
  end)
end

return M
