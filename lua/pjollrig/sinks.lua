-- Sinks: pi socket, clipboard, cmux, wezterm. `send` reads only the store (via init.list), so GitHub threads
-- (kept in memory by github.lua) can never reach a sink. On ack, every sent comment whose body is unchanged
-- is marked resolved. Add a sink: `require("pjollrig.sinks").sinks.x = function(text, opts, cb) end`.
local M = {}

---Markdown payload; bytes match the pre-rewrite formatter for worktree comments.
function M.format(recs)
  local parts = { ("Pjollrig review (%d comment%s):"):format(#recs, #recs == 1 and "" or "s") }
  for i, r in ipairs(recs) do
    local where = r.lnum .. (r.end_lnum and r.end_lnum ~= r.lnum and ("-" .. r.end_lnum) or "")
    local tag = r.rev and (" (%s @%s)"):format(r.side, r.rev:sub(1, 7)) or r.side == "old" and " (old)" or ""
    local quote = r.side == "old" and not r.rev and ("\n> " .. r.line) or "" -- unpinned: the line is the anchor
    parts[#parts + 1] = ("## M%d %s:%s%s%s\n%s"):format(i, r.path, where, tag, quote, r.body)
  end
  return table.concat(parts, "\n\n")
end

local function run(argv, opts, cb) -- async, callback on the main loop
  vim.system(argv, vim.tbl_extend("force", { text = true }, opts or {}), vim.schedule_wrap(cb))
end

-- Anchored at the title start (after spinner/emoji decoration, never a path): "~/src/pi-mono" is a shell.
M.patterns = { "^[^%w~/.]*claude", "^[^%w~/.]*codex", "^[^%w~/.]*amp%f[%W]", "^[^%w~/.]*π", "^[^%w~/.]*pi%f[%W]" }
local function is_agent(title)
  for _, p in ipairs(M.patterns) do
    if title:lower():find(p) then
      return true
    end
  end
  return false
end

-- Exactly one agent-looking target: use it. Otherwise ask. Never auto-submit into a non-agent (a shell).
local function target(items, o, done, cb)
  local agents = vim.tbl_filter(function(s)
    return is_agent(s.title)
  end, items)
  local function go(s)
    if not s then
      return done(false, "no target picked")
    end
    cb(s, o.auto_submit == true and is_agent(s.title))
  end
  if #agents == 1 then
    return go(agents[1])
  end
  vim.ui.select(items, {
    prompt = "pjollrig: send review to",
    format_item = function(s)
      return s.title .. " [" .. s.ref .. "]"
    end,
  }, go)
end

-- A worktree's cmux workspace holds an editor and a shell; the agent sits in the workspace that created the
-- worktree, which worktrunk's post-start hook records at <git-common-dir>/wt/cmux/<branch, / as ->.
local function owner_workspace()
  local dir = vim.fn.expand("%:p:h")
  dir = vim.fn.isdirectory(dir) == 1 and dir or vim.fn.getcwd()
  local args = vim.split("rev-parse --path-format=absolute --git-common-dir --git-dir --abbrev-ref HEAD", " ")
  local r = vim.system({ "git", "-C", dir, unpack(args) }, { text = true }):wait()
  local common, gitdir, branch = unpack(vim.split(vim.trim(r.stdout or ""), "\n"))
  if r.code ~= 0 or common == gitdir or not branch then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, common .. "/wt/cmux/" .. branch:gsub("/", "-"))
  return ok and lines[1] and vim.trim(lines[1]) ~= "" and vim.trim(lines[1]) or nil
end

local function chunks(text, max) -- byte-bounded pieces on line boundaries; concatenation == text
  local out, cur = {}, ""
  for seg in text:gmatch("[^\n]*\n?") do
    if cur ~= "" and #cur + #seg > max then
      out[#out + 1], cur = cur, ""
    end
    while #seg > max do
      out[#out + 1], seg = seg:sub(1, max), seg:sub(max + 1)
    end
    cur = cur .. seg
  end
  out[#out + 1] = cur ~= "" and cur or nil
  return out
end
M._chunks = chunks

M.sinks = {}

function M.sinks.pi(text, o, cb)
  local done, buf, chan = false, "", nil
  local function finish(ok, err)
    if not done then
      done = true
      pcall(vim.fn.chanclose, chan)
      cb(ok, err)
    end
  end
  local ok, c = pcall(vim.fn.sockconnect, "pipe", vim.env.PI_REVIEW_SOCKET or "", {
    on_data = function(_, data) -- {""} is EOF
      buf = buf .. table.concat(data, "\n")
      local line = buf:match("^(.-)\n")
      if line or (#data == 1 and data[1] == "") then
        local okj, reply = pcall(vim.json.decode, line or "")
        local acked = okj and type(reply) == "table" and reply.ok == true
        finish(acked, not acked and (line or "socket closed before ack") or nil)
      end
    end,
  })
  if not ok then
    return finish(false, c)
  end
  chan = c
  vim.fn.chansend(chan, vim.json.encode({ text = text, auto_submit = o.auto_submit == true }) .. "\n")
  vim.defer_fn(function()
    finish(false, "timed out waiting for pi")
  end, o.timeout_ms or 5000)
end

function M.sinks.clipboard(text, _, cb)
  vim.fn.setreg("+", text)
  cb(true)
end

-- One spawn pastes every chunk in order, then submits unless $3 is 0.
local PASTE = [[cli=$1 s=$2 d=$3; shift 3; for c; do "$cli" set-buffer --name "pjollrig-$PPID" -- "$c" &&
"$cli" paste-buffer --name "pjollrig-$PPID" --surface "$s" || exit 1; sleep 0.08; done
[ "$d" = 0 ] || { sleep "$d"; exec "$cli" send-key --surface "$s" enter; }]]
function M.sinks.cmux(text, o, cb)
  local cli = vim.env.CMUX_BUNDLED_CLI_PATH or "cmux"
  local ws = owner_workspace() or vim.env.CMUX_WORKSPACE_ID
  run({ cli, "tree", "--workspace", ws }, nil, function(r)
    local items = {}
    for line in (r.stdout or ""):gmatch("[^\n]+") do
      local ref = line:match("(surface:%d+)")
      if ref and not line:find(" here", 1, true) then
        items[#items + 1] = { ref = ref, title = line:match('"(.-)"') or ref }
      end
    end
    if #items == 0 then
      return cb(false, "no other cmux surface " .. vim.trim(r.stderr or ""))
    end
    target(items, o, cb, function(s, submit) -- chunked: the PTY drops pastes above ~2 KB
      local delay = tostring(submit and (o.submit_delay_ms or 120) / 1000 or 0)
      run(vim.list_extend({ "sh", "-c", PASTE, "sh", cli, s.ref, delay }, chunks(text, 1024)), nil, function(p)
        cb(p.code == 0, p.stderr)
      end)
    end)
  end)
end

function M.sinks.wezterm(text, o, cb)
  run({ "wezterm", "cli", "list", "--format", "json" }, nil, function(r)
    local ok, panes = pcall(vim.json.decode, r.stdout or "")
    local items = {}
    for _, p in ipairs(ok and type(panes) == "table" and panes or {}) do
      if tostring(p.pane_id) ~= vim.env.WEZTERM_PANE then
        items[#items + 1] = { ref = tostring(p.pane_id), title = p.title or "" }
      end
    end
    if #items == 0 then
      return cb(false, "no other wezterm pane " .. vim.trim(r.stderr or ""))
    end
    target(items, o, cb, function(s, submit)
      run({ "wezterm", "cli", "send-text", "--pane-id", s.ref }, { stdin = text }, function(t)
        if t.code ~= 0 or not submit then
          return cb(t.code == 0, t.stderr)
        end
        run({ "wezterm", "cli", "send-text", "--pane-id", s.ref, "--no-paste", "\r" }, nil, function(e)
          cb(e.code == 0, e.stderr)
        end)
      end)
    end)
  end)
end

local env = { pi = "PI_REVIEW_SOCKET", cmux = "CMUX_WORKSPACE_ID", wezterm = "WEZTERM_PANE" }
function M.available()
  return vim.tbl_filter(function(name)
    return not env[name] or (vim.env[env[name]] or "") ~= ""
  end, vim.tbl_keys(M.sinks))
end

---Send the unresolved comments (current root + in-memory) to a sink; resolve them on ack.
function M.send(name)
  local P = require("pjollrig")
  local recs = P.list()
  if #recs == 0 then
    return vim.notify("pjollrig: no comments to send")
  end
  local names = M.available()
  table.sort(names)
  if not name then
    if #names == 1 then
      return M.send(names[1])
    end
    return vim.ui.select(names, { prompt = "pjollrig: sink" }, function(n)
      if n then
        M.send(n)
      end
    end)
  end
  if not vim.tbl_contains(names, name) then
    return vim.notify("pjollrig: sink unavailable: " .. name, vim.log.levels.ERROR)
  end
  M.sinks[name](M.format(recs), P.config.sinks[name] or {}, function(ok, err)
    for _, r in ipairs(ok and recs or {}) do -- resolve what was delivered; a mid-send edit stays unresolved
      local S = require("pjollrig.store")
      if (S.load(r.root)[r.id] or {}).body == r.body then
        S.patch(r.root, { { r.id, { resolved = true, sent_to = name } } })
      end
    end
    P.refresh()
    local msg = ok and ("got %d comment(s)"):format(#recs) or ("failed: " .. tostring(err))
    vim.notify(("pjollrig: %s %s"):format(name, msg), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    local data = { sink = name, ok = ok, err = err, count = #recs }
    vim.api.nvim_exec_autocmds("User", { pattern = "PjollrigSent", data = data })
  end)
end

return M
