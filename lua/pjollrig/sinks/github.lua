-- pjollrig.nvim: GitHub PR review sink.
--
-- Posts the comment batch as a pull-request review through the gh CLI
-- (REST: POST /repos/{owner}/{repo}/pulls/{n}/reviews). The target PR
-- comes from ctx.pr when given, otherwise `gh pr view` resolves the PR
-- for the current branch. gh is always invoked with argv only — the
-- JSON review body travels via a temp file passed to `gh api --input`,
-- never through a shell string. The send path runs gh asynchronously
-- (vim.system callbacks) so the UI never blocks on network calls; the
-- sink reports completion through the `send(comments, ctx, cb)` cb.

local helpers = require("pjollrig.sinks.helpers")

local M = {}

local uv = vim.uv

local VALID_EVENTS = { COMMENT = true, REQUEST_CHANGES = true, APPROVE = true }

local function defaults()
  return {
    command = "gh",
    event = "COMMENT",
    -- Posting a review to GitHub is a copy, not a hand-off: keep the
    -- local records unless the user explicitly opts in to clearing.
    clear_on_success = false,
    pre_text = nil,
  }
end

local function normalize_opts(opts)
  opts = vim.tbl_deep_extend("force", defaults(), opts or {})
  opts.enabled = nil
  if not VALID_EVENTS[opts.event] then
    error(
      ('pjollrig: github sink event must be "COMMENT", "REQUEST_CHANGES", or "APPROVE", got %q'):format(
        tostring(opts.event)
      )
    )
  end
  return opts
end

local function cli(opts)
  return opts.command or "gh"
end

---Pick the working directory for gh calls: explicit ctx.cwd, then the
---first record's project root, then the process cwd.
local function resolve_cwd(ctx, comments)
  if type(ctx.cwd) == "string" and ctx.cwd ~= "" then
    return ctx.cwd
  end
  for _, comment in ipairs(comments or {}) do
    if type(comment.project_root) == "string" and comment.project_root ~= "" then
      return comment.project_root
    end
  end
  return uv.cwd()
end

---Run gh asynchronously and decode its JSON stdout. `cb(decoded, nil)`
---on success, `cb(nil, err)` on failure — always on the main loop.
local function gh_json(opts, argv, cwd, cb)
  local full = { cli(opts) }
  vim.list_extend(full, argv)
  helpers.system_async(full, { cwd = cwd }, function(result)
    if result.code ~= 0 then
      cb(nil, result.stderr:gsub("%s+$", ""))
      return
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok or type(decoded) ~= "table" then
      cb(nil, "gh returned invalid JSON: " .. result.stdout:sub(1, 200))
      return
    end
    cb(decoded, nil)
  end)
end

local function resolve_pr(opts, ctx, cwd, cb)
  local explicit = tonumber(ctx.pr)
  if explicit then
    cb(explicit, nil)
    return
  end
  gh_json(opts, { "pr", "view", "--json", "number" }, cwd, function(decoded, err)
    if not decoded or type(decoded.number) ~= "number" then
      local detail = err and err ~= "" and (" (" .. err .. ")") or ""
      cb(nil, "pjollrig: no open PR for this branch; pass ctx.pr or check out the PR branch" .. detail)
      return
    end
    cb(decoded.number, nil)
  end)
end

local function resolve_repo(opts, cwd, cb)
  gh_json(opts, { "repo", "view", "--json", "nameWithOwner" }, cwd, function(decoded, err)
    if not decoded or type(decoded.nameWithOwner) ~= "string" then
      cb(nil, "pjollrig: could not resolve GitHub repository via gh repo view" .. (err and (": " .. err) or ""))
      return
    end
    cb(decoded.nameWithOwner, nil)
  end)
end

---`meta.github_reply` payload for a record authored as a thread reply
---(via the review panel's `r` action), or nil.
---@param comment table
---@return {to: number|string, pr?: number}|nil
local function reply_meta(comment)
  local meta = type(comment.meta) == "table" and comment.meta or nil
  local reply = meta and type(meta.github_reply) == "table" and meta.github_reply or nil
  return (reply and reply.to ~= nil) and reply or nil
end

---Build the REST review payload. Records whose URI cannot be resolved to
---a project-relative path (session-scope temp buffers, files outside the
---root) are skipped; the skip count is noted in the review body. Records
---carrying `meta.github_reply` are returned separately — they post to
---the thread-replies endpoint, never inside the review. Records already
---posted by an earlier send (`meta.github_sent`) are excluded so a
---re-send — after full success or a partial failure — never duplicates.
---@param event string the review verdict for this send
local function build_review(comments, opts, event)
  local review_comments = {}
  local review_records = {}
  local replies = {}
  local skipped = 0
  local skipped_imported = 0
  local already_sent = 0
  local is_import = require("pjollrig.review.import").is_import
  for _, comment in ipairs(comments) do
    local path = helpers.relative_path(comment)
    local reply = reply_meta(comment)
    local meta = type(comment.meta) == "table" and comment.meta or nil
    if meta and meta.github_sent ~= nil then
      -- Posted by a previous send (full or partial): never repost.
      already_sent = already_sent + 1
    elseif is_import(comment) then
      -- Never echo comments imported FROM GitHub back as a new review.
      skipped_imported = skipped_imported + 1
    elseif reply then
      table.insert(replies, { to = reply.to, pr = tonumber(reply.pr), body = comment.body or "", record = comment })
    elseif not path or path == "." then
      skipped = skipped + 1
    else
      local start_lnum, end_lnum = helpers.line_span(comment)
      local entry = {
        path = path,
        line = end_lnum,
        side = "RIGHT",
        body = comment.body or "",
      }
      if end_lnum > start_lnum then
        entry.start_line = start_lnum
        entry.start_side = "RIGHT"
      end
      table.insert(review_comments, entry)
      table.insert(review_records, comment)
    end
  end

  local summary = ("Pjollrig review: %d comment%s"):format(#review_comments, #review_comments == 1 and "" or "s")
  if skipped > 0 then
    summary = summary .. (" (%d skipped: no repository-relative path)"):format(skipped)
  end
  if skipped_imported > 0 then
    summary = summary .. (" (%d skipped: imported from GitHub)"):format(skipped_imported)
  end
  if already_sent > 0 then
    summary = summary .. (" (%d already sent)"):format(already_sent)
  end
  if #replies > 0 then
    summary = summary .. (" (%d thread repl%s posted separately)"):format(#replies, #replies == 1 and "y" or "ies")
  end
  local body = summary
  if type(opts.pre_text) == "string" and vim.trim(opts.pre_text) ~= "" then
    body = vim.trim(opts.pre_text) .. "\n\n" .. summary
  end

  local payload = {
    event = event,
    body = body,
    comments = review_comments,
  }
  return payload, skipped, skipped_imported, replies, review_records, already_sent
end

---Mark each record as posted (`meta.github_sent = os.time()`) and
---persist through the owning store — the same put+save path record
---mutations like review resolve use. Ad-hoc tables without a store home
---(no id / no root) still get the in-memory marker. Marking happens
---per posted unit, so a partial failure retries only the remainder.
local function mark_sent(records)
  local store = require("pjollrig.store")
  local roots = {}
  local session = false
  local now = os.time()
  for _, record in ipairs(records) do
    if type(record) == "table" then
      if type(record.meta) ~= "table" then
        record.meta = {}
      end
      record.meta.github_sent = now
      if record.id ~= nil then
        if record.scope == "session" then
          store.session_put(record)
          session = true
        elseif type(record.project_root) == "string" and record.project_root ~= "" then
          store.put(record.project_root, record)
          roots[record.project_root] = true
        end
      end
    end
  end
  if session then
    store.session_save()
  end
  for root in pairs(roots) do
    store.save(root)
  end
end

local function post_review(opts, repo, pr, review, cwd, cb)
  local tmp = vim.fn.tempname() .. ".json"
  -- `writefile` can also signal failure by returning -1 without throwing.
  local write_ok, wrote = pcall(vim.fn.writefile, { vim.json.encode(review) }, tmp)
  if not write_ok or wrote ~= 0 then
    cb(false, "pjollrig: github sink could not write review payload to " .. tmp)
    return
  end
  helpers.system_async({
    cli(opts),
    "api",
    ("repos/%s/pulls/%d/reviews"):format(repo, pr),
    "--method",
    "POST",
    "--input",
    tmp,
  }, { cwd = cwd }, function(result)
    vim.fn.delete(tmp)
    if result.code ~= 0 then
      cb(false, "pjollrig: gh api failed: " .. result.stderr:gsub("%s+$", ""))
      return
    end
    cb(true, nil)
  end)
end

---Post one thread reply: POST /repos/{owner}/{repo}/pulls/{n}/comments/{id}/replies.
---The reply's own PR number (recorded at import time) wins over the
---review's resolved PR so replies land on the thread they came from.
local function post_reply(opts, repo, pr, reply, cwd, cb)
  local target_pr = reply.pr or pr
  helpers.system_async({
    cli(opts),
    "api",
    ("repos/%s/pulls/%d/comments/%s/replies"):format(repo, target_pr, tostring(reply.to)),
    "--method",
    "POST",
    "-f",
    "body=" .. reply.body,
  }, { cwd = cwd }, function(result)
    if result.code ~= 0 then
      cb(false, "pjollrig: gh api reply failed: " .. result.stderr:gsub("%s+$", ""))
      return
    end
    cb(true, nil)
  end)
end

---Whether the github integration can be used in the current environment.
---@param opts? table
---@return boolean
function M.is_available(opts)
  opts = normalize_opts(opts)
  return helpers.executable(cli(opts))
end

---Build a github sink spec.
---@param opts? {command?: string, event?: string, clear_on_success?: boolean, pre_text?: string}
---@return table
function M.setup(opts)
  opts = normalize_opts(opts)
  return {
    name = "github",
    type = "integration",
    label = "GitHub PR review",
    description = "post comments as a pull-request review via gh",
    clear_on_success = opts.clear_on_success == true,
    -- Delivery contract with core's `clear_on_success` handling: this
    -- sink stamps `meta.github_sent` (via `mark_sent`) on exactly the
    -- records it delivered, so on success core clears ONLY records
    -- carrying that marker. Records `build_review` diverts out of the
    -- payload (no repository-relative path, imported from GitHub)
    -- never get the marker and therefore survive the auto-clear.
    -- Records marked by an EARLIER send also carry it and are cleared
    -- deliberately: they were delivered then, so clearing completes
    -- that hand-off — keeping them would strand records that can
    -- never post again.
    sent_marker = "github_sent",
    -- `:PjollrigSend github <verdict>` may pass a per-send review
    -- event via ctx.event; the command layer refuses verdicts for
    -- sinks without this flag.
    accepts_verdict = true,
    pre_text = opts.pre_text,
    validate = function(ctx)
      if not helpers.executable(cli(opts)) then
        return false, "pjollrig: github sink requires the gh executable"
      end
      local cwd = resolve_cwd(ctx or {}, nil)
      local result = helpers.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" })
      if result.code ~= 0 then
        return false, "pjollrig: github sink requires a git repository (cwd: " .. cwd .. ")"
      end
      return true
    end,
    health = function()
      return {
        available = M.is_available(opts),
        gh = vim.fn.exepath(cli(opts)),
      }
    end,
    send = function(comments, ctx, cb)
      -- Per-send verdict: ctx.event (from `:PjollrigSend github <verdict>`)
      -- overrides the configured opts.event.
      local event = opts.event
      if ctx.event ~= nil then
        if not VALID_EVENTS[ctx.event] then
          cb(
            false,
            ('pjollrig: github sink ctx.event must be "COMMENT", "REQUEST_CHANGES", or "APPROVE", got %q'):format(
              tostring(ctx.event)
            )
          )
          return
        end
        event = ctx.event
      end
      local cwd = resolve_cwd(ctx, comments)
      local review, skipped, skipped_imported, replies, review_records, already_sent =
        build_review(comments, opts, event)
      -- Skipped records are withheld from GitHub but stay local (the
      -- `sent_marker` contract keeps them out of any auto-clear); the
      -- user must still SEE what was withheld, not just the count
      -- buried in the posted review body.
      local function notify_skipped()
        if skipped == 0 and skipped_imported == 0 then
          return
        end
        local parts = {}
        if skipped > 0 then
          table.insert(parts, ("%d without a repository-relative path"):format(skipped))
        end
        if skipped_imported > 0 then
          table.insert(parts, ("%d imported from GitHub"):format(skipped_imported))
        end
        vim.notify(
          "pjollrig: github sink skipped " .. table.concat(parts, ", ") .. " (kept locally)",
          vim.log.levels.WARN
        )
      end
      if #review.comments == 0 and #replies == 0 then
        if already_sent > 0 then
          vim.notify(
            ("pjollrig: github sink: %d already sent; nothing new to post"):format(already_sent),
            vim.log.levels.INFO
          )
          notify_skipped()
          cb(true, nil)
          return
        end
        cb(
          false,
          ("pjollrig: github sink found no comments with a resolvable repository path (%d skipped)"):format(
            skipped + skipped_imported
          )
        )
        return
      end
      -- The gh steps below are sequential network calls, each run through
      -- an async vim.system so the UI never blocks on gh. The chain is
      -- kept flat: named steps hand off to the next from their callback
      -- (already vim.schedule'd back to the main loop by system_async)
      -- instead of nesting closures per step.
      local repo, pr
      local errors = {}

      local function finish()
        if #errors > 0 then
          cb(
            false,
            table.concat(errors, "; ")
              .. " (already-posted items were marked sent and will not repost; retry sends only the remainder)"
          )
          return
        end
        notify_skipped()
        cb(true, nil)
      end

      -- Replies post independently: mark each success immediately and
      -- collect failures, so a retry re-attempts ONLY what failed.
      local function step_replies(index)
        local reply = replies[index]
        if not reply then
          finish()
          return
        end
        post_reply(opts, repo, pr, reply, cwd, function(ok, err)
          if ok then
            mark_sent({ reply.record })
          else
            table.insert(errors, err)
          end
          step_replies(index + 1)
        end)
      end

      local function step_review()
        if #review.comments == 0 then
          step_replies(1)
          return
        end
        post_review(opts, repo, pr, review, cwd, function(ok, err)
          if not ok then
            cb(false, err)
            return
          end
          mark_sent(review_records)
          step_replies(1)
        end)
      end

      local function step_pr()
        resolve_pr(opts, ctx, cwd, function(resolved, err)
          if not resolved then
            cb(false, err)
            return
          end
          pr = resolved
          step_review()
        end)
      end

      resolve_repo(opts, cwd, function(resolved, err)
        if not resolved then
          cb(false, err)
          return
        end
        repo = resolved
        step_pr()
      end)
    end,
  }
end

return M
