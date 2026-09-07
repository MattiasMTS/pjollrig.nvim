-- pjollrig.nvim: builtin "Checks" review-panel tab — CI status for the
-- session under review.
--
-- Registers through panel.register_tab (see review/tabs/init.lua, whose
-- `done` guard keeps the per-open setup() call idempotent; tests
-- re-register after panel._reset_tabs()). PR sessions
-- (session.ctx.pr) list the PR's checks via `gh pr checks`; other
-- sessions fall back to `gh run list --branch <current branch>` when
-- the session root's branch has an upstream. Both shapes normalize to
-- {name, state pass|fail|running|skipped, url, elapsed} and render
-- sorted fail → running → pass → skipped.
--
-- The fetch runs asynchronously (sinks helpers' system_async), kicked
-- off eagerly at session open (spec.prefetch, gated by the
-- `review.panel.prefetch` config) and again on entering the tab, cached per
-- session with a `fetching` guard; `R` drops the cache and refetches,
-- `<CR>`/`gl` open the row's page in the browser.
--
-- Live updates ride the panel's shared spinner ticker: `busy` puts a
-- winbar spinner next to the title while a fetch is in flight, and
-- `animated` makes the ticker re-render the rows each tick while the
-- tab is current and a check is running — so running rows spin their
-- glyph and their elapsed counter (recomputed per build) ticks. The
-- same builds drive a GENTLE REPOLL: while a check is running, a build
-- that finds the last fetch older than REPOLL_SECONDS quietly
-- refetches (cached rows stay on screen). Repolling stops with the
-- animation — tab left, panel closed, or nothing running.

local M = {}

---Seconds between background refetches while the tab is CURRENT and a
---check is still running. The panel ticker re-renders the tab each
---tick in that state, so build() is the natural clock — no timer of
---our own to leak.
local REPOLL_SECONDS = 30

---Per-session tab state, weak-keyed so it dies with the session table:
---  upstream    boolean|nil  cached `@{upstream}` probe (nil = not probed)
---  fetching    boolean      an async gh call is in flight
---  done        boolean      a fetch completed (checks or error below set)
---  fetched_at  integer|nil  epoch seconds of the last completed fetch
---  checks      table[]|nil  normalized {name, state, url, started, completed}
---  error       string|nil   fetch failure message (rendered as a dim row)
---@type table<table, table>
local states = setmetatable({}, { __mode = "k" })

---@param session table
---@return table
local function state_for(session)
  local st = states[session]
  if not st then
    st = {}
    states[session] = st
  end
  return st
end

---Executable for GitHub calls: honours `sinks.github.command` — the
---same knob the github sink and review/github.lua read — and falls back
---to plain `gh`.
---@return string
local function gh_cli()
  local sinks = require("pjollrig.config").get().sinks
  local github = type(sinks) == "table" and sinks.github or nil
  if type(github) == "table" and type(github.command) == "string" and github.command ~= "" then
    return github.command
  end
  return "gh"
end

---The session's PR number, or nil for non-PR sessions.
---@param session table
---@return integer|nil
local function session_pr(session)
  local ctx = type(session.ctx) == "table" and session.ctx or nil
  return ctx and tonumber(ctx.pr) or nil
end

-- ------------------------------------------------------------------
-- Elapsed formatting
-- ------------------------------------------------------------------

---Epoch seconds for an ISO-8601 UTC timestamp ("2024-01-01T12:00:34Z"),
---or nil for missing/unparseable input and Go zero-value timestamps
---(gh emits "0001-01-01T00:00:00Z" for unstarted checks). os.time
---interprets the fields as LOCAL time, so shift by the local-UTC offset
---— differences between two timestamps would cancel it, but the
---running-elapsed path compares against a real epoch.
---@param ts any
---@return integer|nil
local function iso_epoch(ts)
  if type(ts) ~= "string" or ts:sub(1, 5) == "0001-" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  -- The UTC field table comes back with isdst=false; during local DST
  -- that makes os.time mix standard/summer interpretations and the
  -- offset gains a phantom hour. Mirror the local flag so both
  -- os.time calls share one DST assumption.
  local utc = os.date("!*t", t)
  utc.isdst = os.date("*t", t).isdst
  return t + os.difftime(t, os.time(utc))
end

---`18s` / `2m 14s`, clamped at zero.
---@param secs number
---@return string
local function span(secs)
  secs = math.max(0, math.floor(secs))
  if secs < 60 then
    return ("%ds"):format(secs)
  end
  return ("%dm %ds"):format(math.floor(secs / 60), secs % 60)
end

---Elapsed display for one check: `2m 14s` when finished, `running
---34s…` while going, nil when `started` is missing. Pure — `now`
---(epoch seconds, defaulting to os.time()) is injectable for tests.
---@param started any ISO-8601 start timestamp
---@param completed any ISO-8601 end timestamp, nil while running
---@param now? integer
---@return string|nil
function M._elapsed(started, completed, now)
  local from = iso_epoch(started)
  if not from then
    return nil
  end
  local to = iso_epoch(completed)
  if to then
    return span(to - from)
  end
  return ("running %s\u{2026}"):format(span((now or os.time()) - from))
end

-- ------------------------------------------------------------------
-- Fetch + normalize
-- ------------------------------------------------------------------

---`gh pr checks --json state` values -> normalized state. The values gh
---leaves out of this map (IN_PROGRESS, QUEUED, PENDING, WAITING, …) are
---all in-flight, so unknowns default to "running".
local PR_STATES = {
  SUCCESS = "pass",
  NEUTRAL = "pass",
  SKIPPED = "skipped",
  SKIPPING = "skipped",
  FAILURE = "fail",
  ERROR = "fail",
  CANCELLED = "fail",
  TIMED_OUT = "fail",
  ACTION_REQUIRED = "fail",
  STARTUP_FAILURE = "fail",
  STALE = "fail",
}

---One `gh pr checks` item -> {name, state, url, started, completed}.
---The raw timestamps are kept (instead of a pre-formatted elapsed
---string) so build() can recompute a running check's elapsed per
---render and the counter ticks live.
---@param item table
---@return table
local function pr_check(item)
  local state = PR_STATES[tostring(item.state or ""):upper()] or "running"
  return {
    name = tostring(item.name or "?"),
    state = state,
    url = type(item.link) == "string" and item.link or nil,
    started = item.startedAt,
    completed = state ~= "running" and item.completedAt or nil,
  }
end

---`gh run list --json conclusion` values -> normalized state for
---COMPLETED runs (failure/cancelled/timed_out/… all read as "fail").
local RUN_CONCLUSIONS = { success = "pass", neutral = "pass", skipped = "skipped" }

---One `gh run list` item -> {name, state, url, started, completed}
---(raw timestamps, like pr_check).
---@param item table
---@return table
local function run_check(item)
  local state
  if tostring(item.status or "") == "completed" then
    state = RUN_CONCLUSIONS[tostring(item.conclusion or ""):lower()] or "fail"
  else
    state = "running"
  end
  return {
    name = tostring(item.name or "?"),
    state = state,
    url = type(item.url) == "string" and item.url or nil,
    started = item.startedAt,
    completed = state ~= "running" and item.updatedAt or nil,
  }
end

---The session root's current branch, or nil (no root, not a repo,
---detached HEAD reads back as "HEAD" and still names something gh can
---filter on — pass it through).
---@param session table
---@return string|nil
local function current_branch(session)
  if type(session.root) ~= "string" then
    return nil
  end
  local ok, result = pcall(require("pjollrig.sinks.helpers").system, {
    "git",
    "-C",
    session.root,
    "rev-parse",
    "--abbrev-ref",
    "HEAD",
  })
  if not (ok and result.code == 0) then
    return nil
  end
  local branch = vim.trim(result.stdout)
  return branch ~= "" and branch or nil
end

---Fetch the session's checks once: `gh pr checks` for PR sessions, `gh
---run list` on the current branch otherwise. No-ops while a fetch is in
---flight or after one completed (R resets the guard). `gh pr checks`
---exits non-zero when checks are failing or pending, so a parseable
---stdout wins over the exit code.
---@param ctx pjollrig.PanelTabCtx
local function fetch(ctx)
  local session = ctx.session
  if not session then
    return
  end
  local st = state_for(session)
  if st.fetching or st.done then
    return
  end
  local gh = gh_cli()
  local argv, normalize
  local pr = session_pr(session)
  if pr then
    argv = { gh, "pr", "checks", tostring(pr), "--json", "name,state,link,startedAt,completedAt" }
    normalize = pr_check
  else
    local branch = current_branch(session)
    if not branch then
      st.done = true
      st.error = "could not resolve the session branch"
      return
    end
    argv = {
      gh,
      "run",
      "list",
      "--branch",
      branch,
      "--json",
      "name,status,conclusion,url,startedAt,updatedAt",
      "--limit",
      "30",
    }
    normalize = run_check
  end
  st.fetching = true
  require("pjollrig.sinks.helpers").system_async(argv, { cwd = session.root }, function(result)
    st.fetching = false
    st.done = true
    st.fetched_at = os.time() -- the repoll clock (see maybe_repoll)
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if ok and type(decoded) == "table" and vim.islist(decoded) then
      local checks = {}
      for _, item in ipairs(decoded) do
        if type(item) == "table" then
          checks[#checks + 1] = normalize(item)
        end
      end
      st.checks = checks
      st.error = nil
    else
      st.checks = nil
      local stderr = vim.trim(result.stderr)
      st.error = stderr ~= "" and stderr or ("gh exited with code %d"):format(result.code)
    end
    ctx.refresh()
  end)
end

-- ------------------------------------------------------------------
-- Tab spec: availability, title, build, keymaps
-- ------------------------------------------------------------------

---Available when gh is executable AND the session either came from a PR
---or its root's current branch has an upstream to look up runs for. The
---upstream probe (`git rev-parse --abbrev-ref @{upstream}`) runs ONCE
---per session and is cached; availability is re-evaluated per render.
---@param session table|nil
---@return boolean
local function available(session)
  if not session or vim.fn.executable(gh_cli()) ~= 1 then
    return false
  end
  if session_pr(session) then
    return true
  end
  if type(session.root) ~= "string" then
    return false
  end
  local st = state_for(session)
  if st.upstream == nil then
    local ok, result = pcall(require("pjollrig.sinks.helpers").system, {
      "git",
      "-C",
      session.root,
      "rev-parse",
      "--abbrev-ref",
      "@{upstream}",
    })
    st.upstream = ok and result.code == 0
  end
  return st.upstream
end

---Winbar label: `Checks` before the first fetch (and on error or an
---empty check list), `Checks ✗` once any check failed, else
---`Checks <passed>/<total>`.
---@param ctx pjollrig.PanelTabCtx
---@return string
local function title(ctx)
  local st = ctx.session and states[ctx.session] or nil
  local checks = st and st.checks or nil
  if not checks or #checks == 0 then
    return "Checks"
  end
  local passed = 0
  for _, check in ipairs(checks) do
    if check.state == "fail" then
      return "Checks \u{2717}"
    end
    if check.state == "pass" then
      passed = passed + 1
    end
  end
  return ("Checks %d/%d"):format(passed, #checks)
end

---state -> {glyph, highlight} for the row lead.
local GLYPHS = {
  fail = { "\u{2717}", "DiagnosticError" },
  pass = { "\u{2713}", "DiagnosticOk" },
  running = { "\u{25CF}", "DiagnosticInfo" },
  skipped = { "\u{25CB}", "Comment" },
}

---Render order: failures first, then in-flight, passes, skips.
local ORDER = { "fail", "running", "pass", "skipped" }

---Any check still in flight? Running checks are what the row animation
---and the gentle repoll key off.
---@param checks table[]|nil
---@return boolean
local function any_running(checks)
  for _, check in ipairs(checks or {}) do
    if check.state == "running" then
      return true
    end
  end
  return false
end

---`✗ lint-test (ubuntu, nightly)  1m 48s` — colored glyph, dim elapsed.
---Running rows swap the static ● for the panel's current spinner frame
---and recompute their `running 34s…` elapsed from the raw timestamps,
---so each ticker-driven build advances both.
---@param check table normalized check
---@param frame string|nil ctx.spinner_frame
---@return pjollrig.PanelRow
local function check_row(check, frame)
  local glyph, glyph_hl = GLYPHS[check.state][1], GLYPHS[check.state][2]
  if check.state == "running" and frame then
    glyph = frame
  end
  local text = glyph .. " " .. check.name
  local spans = { { 0, #glyph, glyph_hl } }
  local elapsed = M._elapsed(check.started, check.completed, os.time())
  if elapsed then
    spans[#spans + 1] = { #text + 2, #text + 2 + #elapsed, "Comment" }
    text = text .. "  " .. elapsed
  end
  return {
    text = text,
    spans = spans,
    data = { name = check.name, state = check.state, url = check.url },
  }
end

---A fully dim row (loading/error/empty states and the footer).
---@param text string
---@return pjollrig.PanelRow
local function dim_row(text)
  return { text = text, spans = { { 0, #text, "Comment" } } }
end

local FOOTER = "<CR> open in browser \u{00B7} R refresh"

---Gentle repoll: when a build finds the tab showing a RUNNING check
---whose data is older than REPOLL_SECONDS, clear `done` (re-arming the
---fetch guards) and refetch in the background. Builds only happen
---while the tab is current and the panel is open, and the ticker only
---drives them while something runs — so the repoll stops exactly when
---the task does: tab left, panel closed, or nothing running.
---@param ctx pjollrig.PanelTabCtx
---@param st table
local function maybe_repoll(ctx, st)
  if st.fetching or not st.done or not any_running(st.checks) then
    return
  end
  if os.time() - (st.fetched_at or 0) < REPOLL_SECONDS then
    return
  end
  st.done = false
  fetch(ctx)
end

---@param ctx pjollrig.PanelTabCtx
---@return pjollrig.PanelRow[]
local function build(ctx)
  local st = ctx.session and state_for(ctx.session) or {}
  maybe_repoll(ctx, st)
  local rows = {}
  if st.checks and #st.checks > 0 then
    -- Cached rows render even while a repoll is in flight — a
    -- background refresh must not flash the loading row.
    for _, state in ipairs(ORDER) do
      for _, check in ipairs(st.checks) do
        if check.state == state then
          rows[#rows + 1] = check_row(check, ctx.spinner_frame)
        end
      end
    end
  elseif st.fetching then
    rows[#rows + 1] = dim_row((ctx.spinner_frame or "\u{25CF}") .. " fetching checks\u{2026}")
  elseif st.error then
    rows[#rows + 1] = dim_row(st.error)
  elseif st.checks then
    rows[#rows + 1] = dim_row("no checks found")
  end
  rows[#rows + 1] = dim_row(FOOTER)
  return rows
end

---Winbar spinner while a fetch is in flight (initial, R, or repoll).
---@param ctx pjollrig.PanelTabCtx
---@return boolean
local function busy(ctx)
  local st = ctx.session and states[ctx.session] or nil
  return st ~= nil and st.fetching == true
end

---Row animation while anything needs live frames: a running check
---(spinning glyph + ticking elapsed) or an in-flight fetch showing the
---loading row. Only consulted while the tab is current.
---@param ctx pjollrig.PanelTabCtx
---@return boolean
local function animated(ctx)
  local st = ctx.session and states[ctx.session] or nil
  return st ~= nil and (st.fetching == true or any_running(st.checks))
end

---Open the row's check page in the browser via vim.ui.open (0.12 has
---it); when it is unavailable or fails, surface the url in a notify so
---the user can open it themselves. No-op on url-less rows (footer,
---loading/error/empty states).
---@param row table|nil
local function open_url(row)
  local url = type(row) == "table" and row.url or nil
  if type(url) ~= "string" or url == "" then
    return
  end
  if type(vim.ui.open) == "function" then
    local ok, _, err = pcall(vim.ui.open, url)
    if ok and not err then
      return
    end
  end
  vim.notify("pjollrig: open " .. url, vim.log.levels.INFO)
end

---`R`: drop the fetch cache (keeping the upstream probe) and refetch;
---the immediate refresh shows the loading row until gh answers.
---@param _ table|nil
---@param ctx pjollrig.PanelTabCtx
local function refetch(_, ctx)
  if not ctx.session then
    return
  end
  local st = states[ctx.session]
  if st then
    st.fetching, st.done, st.checks, st.error = false, false, nil, nil
  end
  fetch(ctx)
  ctx.refresh()
end

---Register the checks tab. Zero work happens at require time; callers
---(the tabs loader, tests after panel._reset_tabs()) invoke this once
---per registry lifetime — a duplicate call errors like any duplicate
---tab registration.
function M.setup()
  require("pjollrig.review.panel").register_tab({
    name = "checks",
    title = title,
    available = available,
    build = build,
    on_show = fetch,
    prefetch = true,
    busy = busy,
    animated = animated,
    keymaps = {
      ["<CR>"] = function(row)
        open_url(row)
      end,
      ["gl"] = function(row)
        open_url(row)
      end,
      ["R"] = refetch,
    },
  })
end

---Internal: exposed for tests — the per-session tab state (repoll
---clock, fetch guards).
---@param session table
---@return table
function M._state_for(session)
  return state_for(session)
end

return M
