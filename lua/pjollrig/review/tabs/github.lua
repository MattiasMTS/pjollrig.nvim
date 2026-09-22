-- pjollrig.nvim: builtin "PR" review-panel tab for GitHub PR sessions.
--
-- Registered through review/tabs/init.lua on the first panel open.
-- Available only when the active session carries a PR number in its
-- ctx (a `:PjollrigReview pr <n>` session) and the gh CLI is
-- executable. PR details are fetched eagerly at session open
-- (spec.prefetch, gated by `review.panel.prefetch`) or lazily on first show
-- — either way one async `gh pr view`, cached per session+PR, with the
-- registry's winbar spinner marking the in-flight window (spec.busy) —
-- and the threads section derives entirely from records
-- review/import.lua already materialized locally, so rendering never
-- networks beyond that single fetch. A failed fetch renders as a dim
-- error row; the rest of the tab stays usable.

local M = {}

---One-slot fetch cache: the `gh pr view` result for the current
---session's PR. Keyed on session identity + PR number, so a new
---session (or a different PR) refetches and a stale async callback is
---dropped instead of overwriting the newer slot.
---@type {session?: table, pr?: integer, data?: table, err?: string}
local cache = {}

local FIELDS = "title,author,state,reviewDecision,headRefName,baseRefName,url"

---@param value any
---@return string|nil
local function str(value)
  return type(value) == "string" and value or nil
end

local gh_cli = require("pjollrig.review.github").gh_cli

---The session's PR number, or nil when this is not a PR session.
---@param session table|nil
---@return integer|nil
local function pr_number(session)
  local review_ctx = session and session.ctx
  if type(review_ctx) ~= "table" then
    return nil
  end
  return tonumber(review_ctx.pr)
end

---The cache slot, but only when it belongs to exactly this session+PR.
---@param session table|nil
---@return table|nil
local function cached(session)
  if cache.session ~= nil and cache.session == session and cache.pr == pr_number(session) then
    return cache
  end
  return nil
end

---@param session table|nil
---@return boolean
local function available(session)
  return pr_number(session) ~= nil and require("pjollrig.sinks.helpers").executable(gh_cli())
end

---True while the `gh pr view` fetch is in flight — the slot is claimed
---but neither data nor an error has landed. Drives the registry's
---winbar spinner next to the tab title. No row animation: the header
---placeholder is static text.
---@param ctx pjollrig.PanelTabCtx
---@return boolean
local function busy(ctx)
  local slot = cached(ctx.session)
  return slot ~= nil and slot.data == nil and slot.err == nil
end

---Winbar label: `PR #<n>`, decorated with the review decision once the
---fetch landed (✓ approved, ✗ changes requested).
---@param ctx pjollrig.PanelTabCtx
---@return string
local function title(ctx)
  local pr = pr_number(ctx.session)
  if not pr then
    return "PR"
  end
  local label = ("PR #%d"):format(pr)
  local slot = cached(ctx.session)
  local decision = slot and slot.data and str(slot.data.reviewDecision)
  if decision == "APPROVED" then
    return label .. " ✓"
  end
  if decision == "CHANGES_REQUESTED" then
    return label .. " ✗"
  end
  return label
end

---on_show: fetch the PR header once per session+PR, asynchronously,
---and repaint the panel when it lands. A slot claimed here (even
---without data yet) suppresses duplicate fetches while one is in
---flight; errors land in the slot and render as a dim row.
---@param ctx pjollrig.PanelTabCtx
local function fetch(ctx)
  local session = ctx.session
  local pr = pr_number(session)
  if not pr or cached(session) then
    return
  end
  cache = { session = session, pr = pr }
  require("pjollrig.sinks.helpers").system_async(
    { gh_cli(), "pr", "view", tostring(pr), "--json", FIELDS },
    { cwd = session.root },
    function(result)
      if cache.session ~= session or cache.pr ~= pr then
        return -- a newer session/PR owns the slot
      end
      if result.code ~= 0 then
        cache.err = vim.trim(result.stderr)
      else
        local ok, decoded = pcall(vim.json.decode, result.stdout)
        if ok and type(decoded) == "table" then
          cache.data = decoded
        else
          cache.err = "unexpected gh pr view output"
        end
      end
      ctx.refresh()
    end
  )
end

---A whole-line dim span.
---@param text string
---@return {[1]: integer, [2]: integer, [3]: string}[]
local function dim(text)
  return { { 0, #text, "Comment" } }
end

---Header rows: `#42 <title>` (title emphasized) plus the dim
---`author · head → base · STATE · review: DECISION` line, or the
---fetch-pending/fetch-error placeholder.
---@param rows pjollrig.PanelRow[]
---@param pr integer
---@param slot table|nil
local function header_rows(rows, pr, slot)
  local data = slot and slot.data
  if data then
    local pr_title = str(data.title) or ""
    local prefix = ("#%d"):format(pr)
    local head = pr_title ~= "" and (prefix .. " " .. pr_title) or prefix
    rows[#rows + 1] = {
      text = head,
      spans = pr_title ~= "" and { { #prefix + 1, #head, "Title" } } or nil,
    }
    local parts = {}
    local author = type(data.author) == "table" and str(data.author.login) or nil
    if author then
      parts[#parts + 1] = author
    end
    local head_ref, base_ref = str(data.headRefName), str(data.baseRefName)
    if head_ref and base_ref then
      parts[#parts + 1] = head_ref .. " → " .. base_ref
    end
    if str(data.state) then
      parts[#parts + 1] = data.state
    end
    local decision = str(data.reviewDecision)
    if decision and decision ~= "" then
      parts[#parts + 1] = "review: " .. decision
    end
    local meta = table.concat(parts, " · ")
    if meta ~= "" then
      rows[#rows + 1] = { text = meta, spans = dim(meta) }
    end
  elseif slot and slot.err then
    rows[#rows + 1] = { text = ("#%d"):format(pr) }
    local err = "gh pr view failed: " .. slot.err
    rows[#rows + 1] = { text = err, spans = dim(err) }
  else
    rows[#rows + 1] = { text = ("#%d"):format(pr) }
    local pending = "fetching PR details…"
    rows[#rows + 1] = { text = pending, spans = dim(pending) }
  end
  rows[#rows + 1] = { text = "" }
end

---One thread row for an imported record: `● path:line  first line…`
---(resolved threads swap ● for ✓ and dim the whole row). `data`
---carries the jump target for <CR>.
---@param record table
---@param root string|nil session root, stripped off the displayed path
---@return pjollrig.PanelRow row, boolean resolved
local function thread_row(record, root)
  local path = require("pjollrig.uri").to_path(record.uri) or tostring(record.uri)
  if root and path:sub(1, #root + 1) == root .. "/" then
    path = path:sub(#root + 2)
  end
  local range = type(record.range) == "table" and record.range or {}
  local line = (type(range.start) == "table" and tonumber(range.start[1]) or 0) + 1
  local body = str(record.body) or ""
  local first = body:match("[^\n]*")
  if body:find("\n", 1, true) then
    first = first .. "…"
  end
  local resolved = record.meta.github.resolved == true
  local text = ("%s %s:%d  %s"):format(resolved and "✓" or "●", path, line, first)
  local row = {
    text = text,
    spans = resolved and dim(text) or nil,
    data = { thread = true, id = record.id, uri = record.uri, line = line },
  }
  return row, resolved
end

---@param ctx pjollrig.PanelTabCtx
---@return pjollrig.PanelRow[]
local function build(ctx)
  local session = ctx.session
  local pr = pr_number(session)
  if not pr then
    return {}
  end
  local rows = {}
  header_rows(rows, pr, cached(session))

  -- Threads: imported records over the session's files, open first,
  -- resolved after (each group keeps list()'s uri → line order).
  rows[#rows + 1] = { text = "Threads", spans = { { 0, #"Threads", "Title" } } }
  local is_import = require("pjollrig.review.import").is_import
  local records = require("pjollrig").list({ uris = session.uri_set }, { sync = false, root = session.root })
  local open, resolved = {}, {}
  local unsent = 0
  for _, record in ipairs(records) do
    if is_import(record) then
      local row, is_resolved = thread_row(record, session.root)
      local group = is_resolved and resolved or open
      group[#group + 1] = row
    else
      unsent = unsent + 1
    end
  end
  vim.list_extend(rows, open)
  vim.list_extend(rows, resolved)
  if #open + #resolved == 0 then
    rows[#rows + 1] = { text = "no imported threads", spans = dim("no imported threads") }
  end

  -- Pending: what a send would post, and how.
  rows[#rows + 1] = { text = "" }
  rows[#rows + 1] = { text = "Pending", spans = { { 0, #"Pending", "Title" } } }
  local sinks = require("pjollrig.config").get().sinks
  local github = type(sinks) == "table" and type(sinks.github) == "table" and sinks.github or {}
  local verdict = (str(github.event) or "COMMENT"):lower()
  local pending = ("%d unsent comment%s · verdict: %s"):format(unsent, unsent == 1 and "" or "s", verdict)
  rows[#rows + 1] = { text = pending, spans = dim(pending) }
  local actions = "[S] send review · [R] re-import threads · [O] open in browser"
  rows[#rows + 1] = { text = actions, spans = dim(actions) }
  return rows
end

---<CR>: jump to a thread row's file/line — previous window → edit →
---cursor (the project-panel jump shape, without reaching into panel
---internals). No-op on non-thread rows.
---@param row table|nil
local function jump(row)
  if type(row) ~= "table" or row.thread ~= true then
    return
  end
  local path = require("pjollrig.uri").to_path(row.uri)
  if not path then
    vim.notify("pjollrig: thread's file is no longer available", vim.log.levels.WARN)
    return
  end
  local panel_win = vim.api.nvim_get_current_win()
  local winid = vim.fn.win_getid(vim.fn.winnr("#"))
  if
    winid == 0
    or winid == panel_win
    or not vim.api.nvim_win_is_valid(winid)
    or vim.api.nvim_win_get_config(winid).relative ~= ""
  then
    winid = nil
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if candidate ~= panel_win and vim.api.nvim_win_get_config(candidate).relative == "" then
        winid = candidate
        break
      end
    end
  end
  if not winid then
    return
  end
  vim.api.nvim_set_current_win(winid)
  if not pcall(vim.cmd.edit, vim.fn.fnameescape(path)) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local line = math.min(math.max(tonumber(row.line) or 1, 1), vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
end

---S: the `:PjollrigReviewFinish github` path. finish() is pure, so
---this command surface notifies its failures (same as the user command).
local function send_review()
  local ok, err = require("pjollrig.review").finish({ sink = "github" })
  if not ok then
    vim.notify(err, vim.log.levels.WARN)
  end
end

---R: re-run the PR comment import (the `:PjollrigReview pr <n>`
---entrypoint — it dedupes and backfills thread data), deferred off the
---keystroke; import notifies its own result, then the tab repaints.
---@param _ table|nil
---@param ctx pjollrig.PanelTabCtx
local function reimport(_, ctx)
  local session = ctx.session
  local pr = pr_number(session)
  if not pr or not session.root then
    return
  end
  vim.notify(("pjollrig: re-importing PR #%d review threads..."):format(pr), vim.log.levels.INFO)
  vim.schedule(function()
    require("pjollrig.review.import").github_pr(session.root, pr)
    ctx.refresh()
  end)
end

---O: open the PR in the browser (fire-and-forget; errors notify).
---@param _ table|nil
---@param ctx pjollrig.PanelTabCtx
local function open_in_browser(_, ctx)
  local pr = pr_number(ctx.session)
  if not pr then
    return
  end
  require("pjollrig.sinks.helpers").system_async(
    { gh_cli(), "pr", "view", tostring(pr), "--web" },
    { cwd = ctx.session.root },
    function(result)
      if result.code ~= 0 then
        vim.notify("pjollrig: gh pr view --web failed: " .. vim.trim(result.stderr), vim.log.levels.ERROR)
      end
    end
  )
end

---Register the tab. Called by the builtin loader (review/tabs/init.lua)
---on the first panel open; does nothing else — no work at require time.
function M.setup()
  require("pjollrig.review.panel").register_tab({
    name = "pr",
    title = title,
    available = available,
    build = build,
    on_show = fetch,
    prefetch = true,
    busy = busy,
    keymaps = {
      ["<CR>"] = jump,
      S = send_review,
      R = reimport,
      O = open_in_browser,
    },
  })
end

---Internal: exposed for tests — drop the fetch cache.
function M._reset()
  cache = {}
end

return M
