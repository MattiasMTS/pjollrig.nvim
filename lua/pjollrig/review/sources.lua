-- pjollrig.nvim: local review source resolvers.
-- User resolvers prepend to the registry and may override the builtins.
-- Git resolution/staging runs asynchronously; the synchronous API drives
-- the same chain with vim.wait. Synchronous user/directory resolvers run
-- in a scheduled callback when invoked through resolve_async.
local M = {}
local registry = {}
local uv = vim.uv

-- Avoid Neovim's runtime staged-path pattern: deleted-file comments must
-- remain writable session records, not unidentified diff-side records.
local function make_stage_dir()
  local tmpdir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  local dir = uv.fs_mkdtemp(tmpdir .. "/pjollrig-review-XXXXXX")
  if not dir or dir == "" or dir == "/" then
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

---Register a resolver, with the newest matching registration taking priority.
---The job returned by resolve is passed to review.start; optional resolve_async
---delivers the same job/error through cb on the main loop.
---@param resolver {name: string, match: fun(fargs: string[]): boolean, resolve: fun(fargs: string[], opts: table): table|nil, string|nil, resolve_async?: fun(fargs: string[], opts: table, cb: fun(job: table|nil, err: string|nil))}
function M.register(resolver)
  vim.validate("resolver", resolver, "table")
  vim.validate("resolver.name", resolver.name, "string")
  vim.validate("resolver.match", resolver.match, "function")
  vim.validate("resolver.resolve", resolver.resolve, "function")
  vim.validate("resolver.resolve_async", resolver.resolve_async, "function", true)
  table.insert(registry, 1, resolver)
end

local function fail(cb, err)
  vim.schedule(function()
    cb(nil, err)
  end)
end

-- Large changesets can legitimately take time to stage. The sync API waits
-- for completion; the interactive command uses resolve_async instead.
local RESOLVE_SYNC_TIMEOUT_MS = 4 * 60 * 1000
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
  -- Prune .git directories, and omit linked-worktree .git pointer files.
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
        -- One shared stage dir for empty baselines of right-only files.
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

local function resolve_git_async(fargs, opts, cb)
  local G = require("pjollrig.review.git")
  local cwd = opts.cwd or uv.cwd()
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
        -- Only self-created stage dirs are owned/deleted by the session.
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

local function resolver_for(fargs)
  for _, resolver in ipairs(registry) do
    if resolver.match(fargs) then
      return resolver
    end
  end
end

---Synchronous resolve for external callers with pre-open staging needs.
---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@return {files: table[], label: string, ctx?: table, stage_dirs?: string[]}|nil, string|nil err
function M.resolve(fargs, opts)
  local resolver = resolver_for(fargs)
  if not resolver then
    return nil, ("pjollrig: cannot resolve review arguments: %s"):format(table.concat(fargs, " "))
  end
  return resolver.resolve(fargs, opts or {})
end

---Returns immediately; cb fires on the main loop after staging completes.
---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@param cb fun(job: {files: table[], label: string, ctx?: table, stage_dirs?: string[]}|nil, err: string|nil)
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
