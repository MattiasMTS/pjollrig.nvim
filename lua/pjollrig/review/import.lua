-- pjollrig.nvim: import existing GitHub PR review comments as records.
--
-- Best-effort by design: any gh failure notifies WARN and returns — the
-- review session must still open. Imported records carry
-- `meta.github = { id, url, imported = true }`, which (a) dedupes
-- re-imports on `meta.github.id` and (b) excludes them from
-- `review.finish()` and the github sink so GitHub's own comments are
-- never echoed back as a new review. Records also get `meta.excerpt`
-- (the anchored worktree line, same capture the add path stamps) so
-- their cards quote without a live buffer read. A dedupe hit still
-- BACKFILLS thread data (thread_id/thread_node/resolved) and a missing
-- excerpt onto the existing record, so re-running `:PjollrigReview pr N`
-- refreshes resolve support on records imported before the thread
-- query existed (or when it previously failed).
--
-- Split in two since the import moved off the resolve path: `fetch`
-- (the network half — every gh round-trip as an async continuation)
-- and `apply` (the local store pass). `M.github_pr_async` chains them
-- without ever blocking the editor — review.start_async kicks it AFTER
-- the session is on screen; `M.github_pr` stays the synchronous
-- wrapper (vim.wait-driven) for callers that need the historical
-- block-until-imported contract.

local M = {}

---True when `record` was imported from GitHub
---(`meta.github.imported == true`).
---@param record table
---@return boolean
function M.is_import(record)
  local meta = type(record) == "table" and type(record.meta) == "table" and record.meta or nil
  local gh = meta and type(meta.github) == "table" and meta.github or nil
  return gh ~= nil and gh.imported == true
end

---`vim.json.decode` turns JSON null into `vim.NIL`; only accept real
---numbers so outdated comments (line=null) are filtered out.
---@param value any
---@return number|nil
local function num(value)
  return type(value) == "number" and value or nil
end

---@param value any
---@return string|nil
local function str(value)
  return type(value) == "string" and value or nil
end

---@param msg string
local function warn(msg)
  vim.notify(("pjollrig: skipping PR comment import: %s"):format(msg), vim.log.levels.WARN)
end

---How long the synchronous `M.github_pr` wrapper waits for the fetch
---chain it drives (network round-trips; generous like gh's own
---defaults).
local IMPORT_SYNC_TIMEOUT_MS = 2 * 60 * 1000

---@class pjollrig.review.ImportPayload
---@field comments table[] REST review comments, all pages
---@field threads table<number, {thread_node: string, resolved: boolean}>|nil databaseId -> thread, nil when the query failed
---@field thread_err string|nil why `threads` is nil

---The network half: `gh repo view`, then the REST comment stream and
---the GraphQL thread stream. The two streams are independent and each
---gh round-trip costs real time, so their FIRST requests fan out
---concurrently; pagination within a stream stays sequential (page N+1
---needs page N's cursor) as async continuations. `cb(payload|nil,
---err)` fires on the main loop; a comment-stream failure is fatal
---(err), a thread-stream failure only degrades (payload.thread_err).
---@param root string
---@param number string|integer
---@param cb fun(payload: pjollrig.review.ImportPayload|nil, err: string|nil)
local function fetch(root, number, cb)
  local G = require("pjollrig.review.git")
  G.run_async({ "gh", "repo", "view", "--json", "nameWithOwner" }, { cwd = root }, function(repo_result)
    if repo_result.code ~= 0 then
      return cb(nil, vim.trim(repo_result.stderr))
    end
    local repo_ok, repo = pcall(vim.json.decode, repo_result.stdout)
    if not repo_ok or type(repo) ~= "table" or type(repo.nameWithOwner) ~= "string" then
      return cb(nil, "unexpected gh repo view output")
    end

    local endpoint = ("repos/%s/pulls/%s/comments"):format(repo.nameWithOwner, number)
    local owner, name = repo.nameWithOwner:match("^([^/]+)/(.+)$")
    local thread_query = "query($owner:String!,$name:String!,$number:Int!,$cursor:String){"
      .. "repository(owner:$owner,name:$name){pullRequest(number:$number){"
      .. "reviewThreads(first:100,after:$cursor){"
      .. "pageInfo{hasNextPage endCursor}"
      .. "nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}"
    local function thread_argv(cursor)
      local args = {
        "gh",
        "api",
        "graphql",
        "-f",
        "query=" .. thread_query,
        "-f",
        "owner=" .. tostring(owner),
        "-f",
        "name=" .. tostring(name),
        "-F",
        "number=" .. tostring(number),
      }
      if cursor then
        args[#args + 1] = "-f"
        args[#args + 1] = "cursor=" .. cursor
      end
      return args
    end

    -- Both streams settle exactly once and join here.
    local comments, comments_err
    local threads, thread_err
    local pending = 2
    local function join()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if not comments then
        return cb(nil, comments_err)
      end
      cb({ comments = comments, threads = threads, thread_err = thread_err })
    end

    -- Comment stream. Prefer `--paginate --slurp`: gh wraps one JSON
    -- array per page in an outer array, so page boundaries never
    -- require rewriting the payload (a gsub on `][` would corrupt
    -- comment bodies containing brackets).
    G.run_async({ "gh", "api", endpoint, "--paginate", "--slurp" }, { cwd = root }, function(result)
      if result.code == 0 then
        local ok, pages = pcall(vim.json.decode, result.stdout)
        if not ok or type(pages) ~= "table" then
          comments_err = "unexpected gh api output"
          return join()
        end
        local out = {}
        for _, page in ipairs(pages) do
          if type(page) ~= "table" then
            comments_err = "unexpected gh api output"
            return join()
          end
          for _, comment in ipairs(page) do
            out[#out + 1] = comment
          end
        end
        comments = out
        return join()
      end
      local stderr = result.stderr:lower()
      if not (stderr:find("slurp", 1, true) or stderr:find("unknown flag", 1, true)) then
        comments_err = vim.trim(result.stderr)
        return join()
      end
      -- gh too old for `--slurp`: fetch pages manually until a short page.
      local per_page = 100
      local acc = {}
      local function page(n)
        G.run_async(
          { "gh", "api", ("%s?page=%d&per_page=%d"):format(endpoint, n, per_page) },
          { cwd = root },
          function(r)
            if r.code ~= 0 then
              comments_err = vim.trim(r.stderr)
              return join()
            end
            local ok, list = pcall(vim.json.decode, r.stdout)
            if not ok or type(list) ~= "table" then
              comments_err = "unexpected gh api output"
              return join()
            end
            for _, comment in ipairs(list) do
              acc[#acc + 1] = comment
            end
            if #list < per_page then
              comments = acc
              return join()
            end
            page(n + 1)
          end
        )
      end
      page(1)
    end)

    -- Thread stream — best-effort resolve support: the REST comments
    -- payload carries no review-thread ids, and resolving needs the
    -- THREAD node id. The GraphQL query maps each thread's first
    -- comment databaseId to the thread node + isResolved, following
    -- `pageInfo`/`after:` cursors so PRs with more than 100 threads
    -- still backfill every thread; failure degrades to
    -- import-without-resolve.
    if not owner then
      thread_err = "unexpected repository name " .. repo.nameWithOwner
      return join()
    end
    local map = {}
    local function thread_page(cursor)
      G.run_async(thread_argv(cursor), { cwd = root }, function(result)
        if result.code ~= 0 then
          thread_err = vim.trim(result.stderr)
          return join()
        end
        local ok, decoded = pcall(vim.json.decode, result.stdout)
        local review_threads = ok
          and type(decoded) == "table"
          and vim.tbl_get(decoded, "data", "repository", "pullRequest", "reviewThreads")
        local nodes = type(review_threads) == "table" and review_threads.nodes
        if type(nodes) ~= "table" then
          thread_err = "unexpected gh graphql output"
          return join()
        end
        for _, node in ipairs(nodes) do
          local db = type(node) == "table" and vim.tbl_get(node, "comments", "nodes", 1, "databaseId")
          if type(node.id) == "string" and type(db) == "number" then
            map[db] = { thread_node = node.id, resolved = node.isResolved == true }
          end
        end
        local page_info = type(review_threads.pageInfo) == "table" and review_threads.pageInfo or {}
        local next_cursor = page_info.hasNextPage == true and str(page_info.endCursor) or nil
        if not next_cursor then
          threads = map
          return join()
        end
        thread_page(next_cursor)
      end)
    end
    thread_page(nil)
  end)
end

---The local half: materialize the fetched comments as project records
---anchored to worktree files under `root`, deduping and backfilling on
---`meta.github.id`. Synchronous — store work only, no subprocesses.
---@param root string
---@param number string|integer
---@param payload pjollrig.review.ImportPayload
local function apply(root, number, payload)
  local comments = payload.comments

  local threads = {}
  if payload.threads then
    threads = payload.threads
  elseif #comments > 0 then
    -- Nothing to import means nothing to resolve: stay silent on thread
    -- failures then (the sequential code never even issued the query).
    vim.notify(("pjollrig: PR thread resolve support unavailable: %s"):format(payload.thread_err), vim.log.levels.WARN)
  end

  local store = require("pjollrig.store")
  local uri_mod = require("pjollrig.uri")
  local id_mod = require("pjollrig.id")
  local str_util = require("pjollrig.str")

  -- Worktree file lines keyed by relative path: several comments often
  -- land in the same file and the import pass is one-shot, so each file
  -- is read at most once. `false` = unreadable (excerpt skipped).
  ---@type table<string, string[]|false>
  local file_lines = {}

  ---Excerpt of the worktree text a record anchors to — the same capture
  ---the add path stamps at creation time (init.lua), so imported cards
  ---quote without a live buffer read on every render. The import runs
  ---with the PR head checked out, so the anchored coordinates name real
  ---worktree lines. Nil when the file or line is unavailable.
  ---@param path string path relative to `root`
  ---@param start_line integer 1-based first line of the anchored range
  ---@param end_line integer 1-based last line of the anchored range
  ---@return string|nil
  local function excerpt_for(path, start_line, end_line)
    local lines = file_lines[path]
    if lines == nil then
      local ok, read = pcall(vim.fn.readfile, root .. "/" .. path)
      lines = ok and read or false
      file_lines[path] = lines
    end
    if not lines then
      return nil
    end
    return str_util.excerpt(lines[start_line], end_line > start_line)
  end

  -- Dedupe against every record already carrying a GitHub comment id.
  -- Map id -> record (not a boolean) so a dedupe hit can backfill.
  local existing = {}
  for _, record in ipairs(store.all(root)) do
    local meta = type(record.meta) == "table" and record.meta or nil
    local gh = meta and type(meta.github) == "table" and meta.github or nil
    if gh and gh.id ~= nil then
      existing[tostring(gh.id)] = record
    end
  end

  ---Backfill thread data onto a deduped record. Returns true when a
  ---`meta.github` field actually changed (caller persists).
  ---@param record table existing record for this comment id
  ---@param comment table incoming REST comment payload
  ---@return boolean changed
  local function backfill(record, comment)
    local gh = record.meta.github
    local thread_id = num(comment.in_reply_to_id) or comment.id
    local thread = threads[thread_id]
    local changed = false
    if gh.thread_id ~= thread_id then
      gh.thread_id = thread_id
      changed = true
    end
    if thread then
      if gh.thread_node ~= thread.thread_node then
        gh.thread_node = thread.thread_node
        changed = true
      end
      if gh.resolved ~= thread.resolved then
        gh.resolved = thread.resolved
        changed = true
      end
    end
    -- Records imported before excerpt capture existed: stamp the same
    -- worktree excerpt new imports get, so their cards stop re-reading
    -- the live buffer on every render. The record's own (re-anchored)
    -- range is the line its card cites today.
    if record.meta.excerpt == nil and type(comment.path) == "string" then
      local range = type(record.range) == "table" and record.range or {}
      local start_row = type(range.start) == "table" and num(range.start[1]) or nil
      if start_row then
        local end_row = type(range.end_) == "table" and num(range.end_[1]) or start_row
        local excerpt = excerpt_for(comment.path, start_row + 1, end_row + 1)
        if excerpt then
          record.meta.excerpt = excerpt
          changed = true
        end
      end
    end
    return changed
  end

  local imported = 0
  local updated = 0
  local skipped = 0
  local now = os.time()
  for _, comment in ipairs(comments) do
    local prior = type(comment) == "table" and existing[tostring(comment.id)] or nil
    if prior then
      if backfill(prior, comment) then
        prior.updated_at = now
        store.put_record(prior)
        updated = updated + 1
      end
    elseif type(comment) == "table" and type(comment.path) == "string" then
      -- `line`/`start_line` are coordinates in the file named by
      -- `side`/`start_side`: RIGHT is the checked-out head worktree,
      -- LEFT is the base. Comments on the base side and comments
      -- without a current line (outdated positions, where only
      -- `original_line` — a superseded head commit's coordinate —
      -- remains) are skipped: neither anchors to the worktree.
      local line = comment.side ~= "LEFT" and num(comment.line) or nil
      if line then
        local start_line = comment.start_side ~= "LEFT" and num(comment.start_line) or nil
        start_line = start_line or line
        local user = type(comment.user) == "table" and comment.user or {}
        -- Replies chain to the thread ROOT (GitHub's replies endpoint
        -- rejects reply-to-a-reply ids), so record the root id up front:
        -- the comment's own id for top-level comments, its
        -- in_reply_to_id otherwise.
        local thread_id = num(comment.in_reply_to_id) or comment.id
        local thread = threads[thread_id]
        store.put_record({
          id = id_mod.new(),
          uri = uri_mod.for_path(root .. "/" .. comment.path),
          scope = "project",
          project_root = root,
          range = { start = { start_line - 1, 0 }, end_ = { line - 1, 0 } },
          body = str(comment.body) or "",
          author = str(user.login),
          created_at = now,
          updated_at = now,
          resolved = false,
          meta = {
            excerpt = excerpt_for(comment.path, start_line, line),
            github = {
              id = comment.id,
              url = str(comment.html_url),
              imported = true,
              thread_id = thread_id,
              pr = tonumber(number),
              thread_node = thread and thread.thread_node or nil,
              resolved = thread and thread.resolved or nil,
            },
          },
        })
        imported = imported + 1
      else
        skipped = skipped + 1
      end
    end
  end
  local skip_note = skipped > 0
      and (" (%d skipped: outdated or base-side position%s)"):format(skipped, skipped == 1 and "" or "s")
    or ""
  if imported == 0 and updated == 0 then
    if skipped > 0 then
      vim.notify("pjollrig: imported 0 PR comments" .. skip_note, vim.log.levels.INFO)
    end
    return
  end
  local save_ok, err = store.save(root)
  if not save_ok then
    return warn("failed to persist imported comments: " .. tostring(err))
  end
  if imported > 0 then
    vim.notify(
      ("pjollrig: imported %d PR comment%s"):format(imported, imported == 1 and "" or "s") .. skip_note,
      vim.log.levels.INFO
    )
  end
end

---Fetch review comments for PR `number` and materialize them as
---project records anchored to worktree files under `root` (the PR head
---must be checked out so `comment.path` names real files). Dedupes on
---`meta.github.id`, so re-running `:PjollrigReview pr N` never
---duplicates — but a dedupe hit backfills missing/changed thread data
---onto the existing record so resolve support can be refreshed.
---
---SYNCHRONOUS wrapper: drives the async fetch with vim.wait, then
---applies. For the non-blocking variant see `M.github_pr_async`.
---@param root string git worktree root with the PR head checked out
---@param number string|integer PR number
function M.github_pr(root, number)
  local done = false
  local payload, err
  fetch(root, number, function(p, e)
    payload, err, done = p, e, true
  end)
  vim.wait(IMPORT_SYNC_TIMEOUT_MS, function()
    return done
  end, 5)
  if not done then
    return warn("gh timed out")
  end
  if not payload then
    return warn(err)
  end
  apply(root, number, payload)
end

---`M.github_pr` without the block: the gh round-trips run as async
---continuations and the store pass lands from their final callback.
---`cb` (optional) fires on the main loop once the import settled —
---after records landed, or after the best-effort WARN on failure.
---@param root string git worktree root with the PR head checked out
---@param number string|integer PR number
---@param cb? fun()
function M.github_pr_async(root, number, cb)
  fetch(root, number, function(payload, err)
    if not payload then
      warn(err)
    else
      apply(root, number, payload)
    end
    if cb then
      cb()
    end
  end)
end

return M
