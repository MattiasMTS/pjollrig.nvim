-- pjollrig.nvim: review an assistant turn from a Claude Code transcript.
--
-- Claude Code writes one JSONL transcript per session to
-- `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, where the slug is
-- the absolute cwd with every non-alphanumeric byte replaced by `-`
-- (`/Users/me/src/github.com/x.nvim` → `-Users-me-src-github-com-x-nvim`).
-- `:PjollrigReview chat` picks a session and one assistant turn from it,
-- writes the turn's text out as a markdown file, and opens it as a
-- DOCUMENT pair (`status = "doc"`, no left side — see review.lua) in the
-- normal review session: no diff against anything, prose wrapping on —
-- so a plan or report the agent wrote can be commented on line by line
-- and the batch sent back through any sink. Read-only and best-effort:
-- the transcripts are never modified, and a missing directory or
-- unrecognized shape fails the resolve with a clear message.
--
-- Transcript shape this reads (verified against Claude Code 2.x files):
--
--   * one JSON object per line; a top-level `type` discriminates. Only
--     `assistant`, `user`, and `ai-title` matter; `last-prompt`, `mode`,
--     `permission-mode`, `attachment`, `system`, `file-history-*`, ... are
--     bookkeeping and ignored. `type` is NOT the first key on
--     assistant/user lines (`parentUuid` is), so the pre-decode filter is
--     a plain `string.find` anywhere in the line, not a prefix match.
--   * `ai-title`: `{type, aiTitle, sessionId}` — the session's generated
--     title, re-emitted per turn; the LAST one wins.
--   * `assistant`: `message.content` is an array of blocks (`text`,
--     `thinking`, `tool_use`); `cwd`, `sessionId`, `gitBranch`,
--     `timestamp` (ISO 8601, UTC) and `isSidechain` (false/null, true
--     for subagent traffic) sit at the top level.
--   * `user`: human prompts (`message.content` a string, or an array of
--     `text`/`image` blocks) AND tool results (`tool_result` blocks) share
--     the type; `isMeta` marks injected context.
--   * nothing links a session to a pull request, so no `pr` field.
--
-- A turn is a run of consecutive assistant events; ANY user event ends it
-- — tool results included — so the agent's final answer to a prompt is
-- its own turn and the one-line narration between tool calls falls under
-- the picker's minimum size (MIN_LINES/MIN_CHARS below). Only `text`
-- blocks count; sidechain events neither add text nor end a run.
--
-- Cost: transcripts run to many MB, so both scans are linear and
-- prefix-filtered — a line is json-decoded only when a plain find for the
-- needed `"type":"…"` marker hits, and a user line is a boundary without
-- decoding at all. The IO is synchronous but runs inside the resolver's
-- own scheduled step (`resolve_async` below), after `:PjollrigReview` has
-- returned and the review shell is on screen; the floating pickers
-- continue that same chain, so the registry needs no extra machinery.

local M = {}

local uv = vim.uv

---A turn is offered when it has at least this many NON-BLANK lines AND
---this many characters: real reports run 10+ lines / 1000+ chars,
---narration between tool calls is one line under ~140 chars. Blank
---lines do not count — text blocks join with one, so a URL plus a
---sentence spans three lines but is two lines of text.
M.MIN_LINES = 3
M.MIN_CHARS = 120

local FORMAT_ERR = "pjollrig: transcript format not recognized (Claude Code changed its session format?)"

local projects_dir

---Test seam: point the reader at another projects dir (nil = default
---`~/.claude/projects`).
---@param path string|nil
function M._set_projects_dir(path)
  projects_dir = path
end

local function get_projects_dir()
  return projects_dir or vim.fn.expand("~/.claude/projects")
end

---Claude Code's project slug for an absolute cwd.
---@param cwd string
---@return string
function M.slug(cwd)
  return (cwd:gsub("[^A-Za-z0-9]", "-"))
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

---Decode one transcript line; nil for anything that is not a JSON object.
local function decode(line)
  local ok, event = pcall(vim.json.decode, line)
  if ok and type(event) == "table" then
    return event
  end
  return nil
end

---First non-blank line of `text`, CR/LF agnostic.
local function first_line(text)
  return vim.trim(text):match("^[^\r\n]*")
end

---Total and non-blank line counts of (trimmed, LF-only) `text`.
---@param text string
---@return integer total, integer nonblank
local function count_lines(text)
  local total, nonblank = 0, 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    total = total + 1
    if line:find("%S") then
      nonblank = nonblank + 1
    end
  end
  return total, nonblank
end

---The prompt text of a user event: a string content, or its first text
---block; nil for tool results and image-only messages.
local function user_text(message)
  if type(message) ~= "table" then
    return nil
  end
  local content = message.content
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        return block.text
      end
    end
  end
  return nil
end

---How many trailing candidate lines a backwards scan decodes before
---giving up: the file's last line can be half-written while Claude Code
---is still streaming to it.
local TAIL_TRIES = 4

---Walk `lines` backwards and return `field` of the first event that
---decodes to a non-empty string for it (at most TAIL_TRIES decodes).
local function last_string_field(lines, field)
  for i = #lines, math.max(1, #lines - TAIL_TRIES + 1), -1 do
    local event = decode(lines[i])
    local value = event and event[field]
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

---Session metadata scan: title (last ai-title, else the first real
---prompt's first line) and branch (the last assistant/user event's
---gitBranch). Decodes only the user lines up to the first real prompt
---plus a trailing ai-title line and a trailing event line; the other
---lines are only `find`-tested and kept by reference.
---@param content string
---@return string|nil title, string|nil branch
local function scan_meta(content)
  local title_lines, event_lines, first_prompt = {}, {}, nil
  for line in content:gmatch("[^\n]+") do
    if line:find('"type":"ai-title"', 1, true) then
      title_lines[#title_lines + 1] = line
    elseif line:find('"type":"assistant"', 1, true) then
      event_lines[#event_lines + 1] = line
    elseif line:find('"type":"user"', 1, true) then
      event_lines[#event_lines + 1] = line
      if not first_prompt and not line:find('"isMeta":true', 1, true) then
        local event = decode(line)
        local text = event and event.type == "user" and user_text(event.message)
        local first = text and first_line(text)
        -- `<command-name>`-style injected messages are not prompts.
        if first and first ~= "" and first:sub(1, 1) ~= "<" then
          first_prompt = first
        end
      end
    end
  end
  return last_string_field(title_lines, "aiTitle") or first_prompt, last_string_field(event_lines, "gitBranch")
end

---@class pjollrig.chat.Session
---@field path string transcript path
---@field id string session id (file basename)
---@field title string
---@field branch string|nil
---@field mtime number epoch seconds
---@field size integer bytes
---@field pr integer|nil never set today (transcripts carry no PR link); kept for the picker label

---Sessions for the cwd's slug (or every slug with `opts.all`), newest
---mtime first. Empty transcripts are skipped. `nil, err` when the
---projects dir itself is missing — Claude Code has never run here.
---@param opts? {cwd?: string, all?: boolean}
---@return pjollrig.chat.Session[]|nil, string|nil err
function M.list_sessions(opts)
  opts = opts or {}
  local root = get_projects_dir()
  if vim.fn.isdirectory(root) ~= 1 then
    return nil,
      ("pjollrig: no Claude Code transcripts at %s (chat review reads Claude Code's session files)"):format(root)
  end
  local dirs = {}
  if opts.all then
    for name, type_ in vim.fs.dir(root) do
      if type_ == "directory" then
        dirs[#dirs + 1] = root .. "/" .. name
      end
    end
  else
    dirs[1] = root .. "/" .. M.slug(opts.cwd or uv.cwd())
  end
  local sessions = {}
  for _, dir in ipairs(dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      for name, type_ in vim.fs.dir(dir) do
        local id = type_ == "file" and name:match("^(.+)%.jsonl$")
        if id then
          local path = dir .. "/" .. name
          local stat = uv.fs_stat(path)
          if stat and stat.size > 0 then
            local content = read_all(path)
            local title, branch = scan_meta(content or "")
            sessions[#sessions + 1] = {
              path = path,
              id = id,
              title = title or id,
              branch = branch,
              mtime = stat.mtime.sec + stat.mtime.nsec / 1e9,
              size = stat.size,
            }
          end
        end
      end
    end
  end
  table.sort(sessions, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return a.id < b.id
  end)
  return sessions
end

---@class pjollrig.chat.Turn
---@field index integer 1 = newest kept turn
---@field timestamp string|nil ISO timestamp of the turn's first text event
---@field text string text blocks joined with blank lines
---@field first_line string
---@field line_count integer total lines, blank ones included (the picker's `(n lines)`)

---Kept assistant turns of `session`, newest first and numbered over the
---kept ones (so `chat <n>` and the picker agree). `nil, err` when the
---file is unreadable or its assistant events lack the expected shape.
---@param session pjollrig.chat.Session
---@return pjollrig.chat.Turn[]|nil, string|nil err
function M.list_turns(session)
  local content = read_all(session.path)
  if not content then
    return nil, ("pjollrig: cannot read transcript %s"):format(session.path)
  end
  local turns = {} -- chronological, unfiltered
  local run, run_ts = {}, nil
  local seen, shaped = 0, 0
  local function flush()
    if #run > 0 then
      local text = vim.trim(table.concat(run, "\n\n"):gsub("\r\n?", "\n"))
      if text ~= "" then
        turns[#turns + 1] = { text = text, timestamp = run_ts }
      end
    end
    run, run_ts = {}, nil
  end
  for line in content:gmatch("[^\n]+") do
    if line:find('"isSidechain":true', 1, true) then
      -- Subagent traffic: neither text nor a boundary.
    elseif line:find('"type":"assistant"', 1, true) then
      -- A tool_result quoting `"type":"assistant"` lands here too; the
      -- decoded type sorts it out.
      local event = decode(line)
      if event and event.type == "assistant" then
        seen = seen + 1
        local blocks = type(event.message) == "table" and event.message.content
        if type(blocks) == "table" then
          shaped = shaped + 1
          for _, block in ipairs(blocks) do
            if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
              run[#run + 1] = block.text
              run_ts = run_ts or event.timestamp
            end
          end
        end
      elseif event and event.type == "user" then
        flush()
      end
    elseif line:find('"type":"user"', 1, true) then
      flush()
    end
  end
  flush()
  if seen > 0 and shaped == 0 then
    return nil, FORMAT_ERR
  end
  local kept = {}
  for i = #turns, 1, -1 do
    local turn = turns[i]
    local line_count, text_lines = count_lines(turn.text)
    if text_lines >= M.MIN_LINES and #turn.text >= M.MIN_CHARS then
      turn.index = #kept + 1
      turn.first_line = first_line(turn.text)
      turn.line_count = line_count
      kept[#kept + 1] = turn
    end
  end
  return kept
end

---Write `turn.text` as markdown under stdpath("cache")/manicule/chat and
---return the path — the text alone. (A header above it would be
---concealed markup in markdown: blank rows on screen, and every
---commented line offset from the turn.) Re-materializing the same turn
---overwrites the same path, so comments left on it keep their URI.
---@param session pjollrig.chat.Session
---@param turn pjollrig.chat.Turn
---@return string path
function M.materialize(session, turn)
  local dir = vim.fn.stdpath("cache") .. "/manicule/chat"
  vim.fn.mkdir(dir, "p")
  local path = ("%s/%s-turn-%d.md"):format(dir, session.id:sub(1, 8), turn.index)
  vim.fn.writefile(vim.split(turn.text, "\n", { plain = true }), path)
  return path
end

-- ---------------------------------------------------------------------------
-- Resolver

local function human_size(bytes)
  if bytes >= 1024 * 1024 then
    return ("%.1f MB"):format(bytes / (1024 * 1024))
  end
  if bytes >= 1024 then
    return ("%d KB"):format(bytes / 1024)
  end
  return ("%d B"):format(bytes)
end

---Epoch seconds for a transcript timestamp (ISO 8601, UTC). os.time reads
---its table as LOCAL time, so the local UTC offset is added back.
---@param iso string
---@return number|nil
local function iso_to_epoch(iso)
  local y, mo, d, h, mi, s = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local as_local = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  local now = os.time()
  local utc = os.date("!*t", now)
  utc.isdst = nil
  return as_local + os.difftime(now, os.time(utc))
end

local function hhmm(iso)
  local epoch = iso and iso_to_epoch(iso)
  if not epoch then
    return "??:??"
  end
  return os.date("%H:%M", epoch) --[[@as string]]
end

---Picker row: `Title · <age> · <branch> · <size>[ · #pr]`.
---@param session pjollrig.chat.Session
function M.format_session(session)
  local parts = {
    session.title,
    require("pjollrig.ui.color").relative_time(math.floor(session.mtime)),
    session.branch or "?",
    human_size(session.size),
  }
  if session.pr then
    parts[#parts + 1] = "#" .. tostring(session.pr)
  end
  return table.concat(parts, " · ")
end

local FIRST_LINE_COLS = 72

---Picker row: `HH:MM  <first line…>  (<n> lines)`, local time.
---@param turn pjollrig.chat.Turn
function M.format_turn(turn)
  local first = turn.first_line
  if vim.fn.strchars(first) > FIRST_LINE_COLS then
    first = vim.fn.strcharpart(first, 0, FIRST_LINE_COLS - 1) .. "…"
  end
  return ("%s  %s  (%d lines)"):format(hhmm(turn.timestamp), first, turn.line_count)
end

---The review job for one turn: the materialized markdown as a document
---pair — `status = "doc"`, no `left` — which the session opens plain
---(review.lua's open_pair). Nothing is staged, so the job owns no stage
---dirs; the cached markdown stays.
---@param session pjollrig.chat.Session
---@param turn pjollrig.chat.Turn
local function job_for(session, turn)
  local right = M.materialize(session, turn)
  return {
    files = { { right = right, status = "doc", path = vim.fs.basename(right) } },
    label = "chat: " .. session.title,
  }
end

---Open a floating picker with the resolver's cancel contract: dismissing the
---picker fails the resolve (the shell closes with that message).
local function pick(items, prompt, format_item, cb, on_choice)
  require("pjollrig.ui.select").select(
    items,
    { prompt = prompt, format_item = format_item, kind = "pjollrig-chat" },
    function(choice)
      if not choice then
        return cb(nil, "pjollrig: chat review cancelled")
      end
      on_choice(choice)
    end
  )
end

---The resolve proper, on the main loop. Forms: `chat` (session picker,
---skipped for a single session, then turn picker), `chat <n>` (newest
---session, kept turn n, no pickers), `chat all` (session picker across
---every project).
local function run(fargs, opts, cb)
  local arg = fargs[2]
  local all = arg == "all"
  local n = nil
  if arg ~= nil and not all then
    n = tonumber(arg)
    if not n or n < 1 or n ~= math.floor(n) then
      return cb(nil, ("pjollrig: usage: :PjollrigReview chat [all|<turn>], got %q"):format(arg))
    end
  end
  local sessions, err = M.list_sessions({ cwd = opts.cwd, all = all })
  if not sessions then
    return cb(nil, err)
  end
  if #sessions == 0 then
    if all then
      return cb(nil, "pjollrig: no Claude Code sessions found under " .. get_projects_dir())
    end
    return cb(nil, ("pjollrig: no Claude Code sessions for %s"):format(opts.cwd or uv.cwd()))
  end
  local function with_session(session)
    local turns, terr = M.list_turns(session)
    if not turns then
      return cb(nil, terr)
    end
    if #turns == 0 then
      return cb(nil, ("pjollrig: no reviewable assistant turns in %q"):format(session.title))
    end
    if n then
      local turn = turns[n]
      if not turn then
        return cb(nil, ("pjollrig: %q has %d reviewable turn(s); no turn %d"):format(session.title, #turns, n))
      end
      return cb(job_for(session, turn))
    end
    pick(turns, "Review assistant turn", M.format_turn, cb, function(turn)
      cb(job_for(session, turn))
    end)
  end
  if n or #sessions == 1 then
    return with_session(sessions[1])
  end
  local prompt = all and "Review Claude Code session (all projects)" or "Review Claude Code session"
  pick(sessions, prompt, M.format_session, cb, with_session)
end

---Resolver entry (registered in review/sources.lua): `cb(job, err)` on
---the main loop, never in the caller's frame. The whole resolve —
---transcript scans, pickers, materialize — starts in one scheduled step
---so `:PjollrigReview` returns first and the review shell is already up
---when a picker opens; picker callbacks continue the chain from
---the picker's own callback.
---@param fargs string[]
---@param opts {cwd?: string}
---@param cb fun(job: table|nil, err: string|nil)
function M.resolve_async(fargs, opts, cb)
  opts = opts or {}
  vim.schedule(function()
    run(fargs, opts, cb)
  end)
end

return M
