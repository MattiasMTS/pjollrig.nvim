-- pjollrig.nvim: GitHub thread interactions for imported PR comments.
--
-- Replies and thread resolution live OUTSIDE the core record model:
-- everything here reads and writes `record.meta` only (`meta.github` on
-- imported records, `meta.github_reply` on locally-authored replies)
-- and talks to GitHub through the gh CLI. The core record schema stays
-- github-agnostic. Network calls run asynchronously (the sink helpers'
-- `system_async`) so panel keymaps never block the UI; `M.reply` itself
-- never networks — it only persists a local record that the github sink
-- posts on the next send.

local M = {}

local function emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

---Find a record by its panel locator across both stores.
---Returns the live record plus a saver that persists mutations through
---the owning store.
---@param locator {id: string, scope?: string, project_root?: string}|nil
---@return table? record, (fun(): boolean, string?)? save
local function find(locator)
  if type(locator) ~= "table" or type(locator.id) ~= "string" then
    return nil, nil
  end
  local store = require("pjollrig.store")
  if locator.scope == "session" then
    for _, r in ipairs(store.session_all()) do
      if r.id == locator.id then
        return r, function()
          store.session_put(r)
          return store.session_save()
        end
      end
    end
    return nil, nil
  end
  local root = locator.project_root
  if not root then
    return nil, nil
  end
  local record = store.get(root, locator.id)
  if not record then
    return nil, nil
  end
  return record, function()
    store.put(root, record)
    return store.save(root)
  end
end

---`meta.github` of an IMPORTED record, or nil for local records.
---@param record table
---@return table|nil
local function imported_github(record)
  local meta = type(record.meta) == "table" and record.meta or nil
  local gh = meta and type(meta.github) == "table" and meta.github or nil
  return (gh and gh.imported == true) and gh or nil
end

---Executable for GitHub calls: honours `sinks.github.command` — the
---same knob the github sink reads — and falls back to plain `gh`.
---@return string
local function gh_cli()
  local sinks = require("pjollrig.config").get().sinks
  local github = type(sinks) == "table" and sinks.github or nil
  if type(github) == "table" and type(github.command) == "string" and github.command ~= "" then
    return github.command
  end
  return "gh"
end

---Reply to the imported GitHub comment behind `locator`: open the
---comment editor and persist the result as a NORMAL local record that
---copies the target's uri + range and carries
---`meta.github_reply = { to = <thread root id>, pr = <n> }`. The github
---sink posts such records to the thread-replies endpoint instead of the
---review payload.
---@param locator {id: string, scope?: string, project_root?: string}|nil
function M.reply(locator)
  local record = find(locator)
  if not record then
    vim.notify("pjollrig: no comment with id " .. tostring(locator and locator.id), vim.log.levels.WARN)
    return
  end
  local gh = imported_github(record)
  if not gh then
    vim.notify("pjollrig: reply targets a comment imported from GitHub", vim.log.levels.WARN)
    return
  end
  local to = gh.thread_id or gh.id
  require("pjollrig.ui").prompt({ prompt = "Reply: " }, function(body)
    if not body or body == "" then
      return
    end
    local store = require("pjollrig.store")
    local now = os.time()
    local reply = {
      id = require("pjollrig.id").new(),
      uri = record.uri,
      scope = record.scope,
      project_root = record.project_root,
      range = vim.deepcopy(record.range),
      body = body,
      author = require("pjollrig.ui").git_email(),
      created_at = now,
      updated_at = now,
      resolved = false,
      meta = { github_reply = { to = to, pr = gh.pr } },
    }
    store.put_record(reply)
    local ok, err
    if reply.scope == "session" then
      ok, err = store.session_save()
    else
      ok, err = store.save(reply.project_root)
    end
    if not ok then
      if reply.scope == "session" then
        store.session_remove(reply.id)
      else
        store.remove(reply.project_root, reply.id)
      end
      vim.notify("pjollrig: failed to persist reply: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Repaint the buffer showing the target file (if loaded) so the
    -- reply renders like any other record; qf/panel refresh rides the
    -- PjollrigAdded event.
    local bufnr = require("pjollrig.uri").bufnr_for_uri(reply.uri)
    if bufnr then
      require("pjollrig")._attach_buffer(bufnr)
    end
    emit("PjollrigAdded", reply)
  end)
end

---Toggle GitHub thread resolution for the imported comment behind
---`locator` via the resolveReviewThread / unresolveReviewThread GraphQL
---mutations. The mutation runs through an async `vim.system` (the same
---helper as the github sink's send path) so pressing `gr` never blocks
---the UI. The UX is pending-style, not optimistic: a
---"resolving/unresolving thread..." notify fires immediately, and the
---local `meta.github.resolved` flip, store save, and PjollrigEdited
---refresh all happen in the callback once GitHub confirmed the mutation
---— the sync version's ordering preserved, so a failed mutation needs
---no rollback. A second `gr` while a mutation is in flight re-sends the
---same (idempotent) mutation and both callbacks set the same final
---value, so state stays consistent. Requires `meta.github.thread_node`
---(captured at import time); records imported before resolve support
---gain it when `:PjollrigReview pr <n>` is re-run — import backfills
---thread data onto deduped records.
---@param locator {id: string, scope?: string, project_root?: string}|nil
function M.toggle_resolve(locator)
  local record, save = find(locator)
  if not record or not save then
    vim.notify("pjollrig: no comment with id " .. tostring(locator and locator.id), vim.log.levels.WARN)
    return
  end
  local gh = imported_github(record)
  if not gh then
    vim.notify("pjollrig: resolve targets a comment imported from GitHub", vim.log.levels.WARN)
    return
  end
  if type(gh.thread_node) ~= "string" or gh.thread_node == "" then
    vim.notify(
      "pjollrig: comment has no review-thread id; re-run :PjollrigReview pr <n> to refresh thread data",
      vim.log.levels.WARN
    )
    return
  end
  local resolving = gh.resolved ~= true
  local mutation = resolving and "resolveReviewThread" or "unresolveReviewThread"
  local query = ("mutation($id:ID!){%s(input:{threadId:$id}){thread{isResolved}}}"):format(mutation)
  vim.notify(("pjollrig: %s thread..."):format(resolving and "resolving" or "unresolving"), vim.log.levels.INFO)
  require("pjollrig.sinks.helpers").system_async(
    { gh_cli(), "api", "graphql", "-f", "query=" .. query, "-f", "id=" .. gh.thread_node },
    { cwd = record.project_root },
    function(result)
      if result.code ~= 0 then
        vim.notify(("pjollrig: gh %s failed: %s"):format(mutation, vim.trim(result.stderr)), vim.log.levels.ERROR)
        return
      end
      -- Network completion can outlive edits, deletion, or cache refresh.
      -- Apply only the thread state to the current record, never a stale copy.
      local current, persist = find({ id = record.id, scope = record.scope, project_root = record.project_root })
      local current_gh = current and imported_github(current)
      if not current_gh or not persist or current_gh.thread_node ~= gh.thread_node then
        return
      end
      local previous, updated_at = current_gh.resolved, current.updated_at
      current_gh.resolved = resolving
      current.updated_at = os.time()
      local ok, err = persist()
      if not ok then
        current_gh.resolved = previous
        current.updated_at = updated_at
        vim.notify("pjollrig: failed to persist thread state: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      emit("PjollrigEdited", current)
      vim.notify(("pjollrig: thread %s"):format(resolving and "resolved" or "unresolved"), vim.log.levels.INFO)
    end
  )
end

return M
