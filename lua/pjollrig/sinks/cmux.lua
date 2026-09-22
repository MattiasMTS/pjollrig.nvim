-- pjollrig.nvim: cmux integration.
--
-- Sends the markdown review payload to a running coding-agent surface
-- in the current cmux workspace. Detection is intentionally generic:
-- Claude Code, Codex, Amp, and future agents can all match by state,
-- title, process command, or screen contents.

local helpers = require("pjollrig.sinks.helpers")

local M = {}

local DEFAULT_PATTERNS = {
  "Claude Code",
  "claude-code",
  "Claude",
  "OpenAI Codex",
  "Codex",
  "sourcegraph/amp",
  "Amp",
  "Pi",
  "π",
}
local DEFAULT_CACHE_TTL_MS = 5000
local agent_surface_cache = {}

local function defaults()
  return {
    command = vim.env.CMUX_BUNDLED_CLI_PATH or "cmux",
    workspace_id = vim.env.CMUX_WORKSPACE_ID,
    current_surface = vim.env.CMUX_SURFACE_ID,
    patterns = DEFAULT_PATTERNS,
    auto_submit = true,
    submit_delay_ms = 120,
    paste_chunk_bytes = 1024,
    paste_chunk_delay_ms = 80,
    paste_retries = 2,
    clear_on_success = true,
    cache = true,
    cache_ttl_ms = DEFAULT_CACHE_TTL_MS,
    process_fallback = true,
    screen_fallback = true,
    read_screen_lines = 120,
    agent_state_dir = vim.env.TMPDIR or "/tmp",
    picker_prompt = "cmux: send review to",
    pre_text = nil,
    post_text = nil,
  }
end

local function normalize_opts(opts)
  opts = vim.tbl_deep_extend("force", defaults(), opts or {})
  opts.enabled = nil
  return opts
end

local function cli(opts)
  return opts.command or vim.env.CMUX_BUNDLED_CLI_PATH or "cmux"
end

local function shorten(value, max)
  value = tostring(value or "")
  return #value <= max and value or (value:sub(1, max - 3) .. "...")
end

local function now_ms()
  return math.floor(vim.uv.hrtime() / 1000000)
end

local function patterns_key(patterns)
  local out = {}
  for _, pattern in ipairs(patterns or {}) do
    table.insert(out, tostring(pattern))
  end
  return table.concat(out, "\n")
end

local function cache_key(opts)
  return table.concat({
    cli(opts),
    opts.workspace_id or "",
    opts.current_surface or "",
    patterns_key(opts.patterns),
    tostring(opts.process_fallback ~= false),
    tostring(opts.screen_fallback ~= false),
    tostring(opts.read_screen_lines or ""),
    opts.agent_state_dir or "",
  }, "\t")
end

-- Split on CR/LF and drop blank lines — deliberately NOT str.split_lines
-- (which keeps blanks): cmux tree/ps output is parsed line-by-line and
-- blank/CR-terminated lines are noise here. Do not fold into pjollrig.str.
local function split_nonempty_lines(text)
  return vim.split(tostring(text or ""), "[\r\n]+", { trimempty = true })
end

local function split_tabs(text)
  return vim.split(tostring(text or ""), "\t", { plain = true })
end

local function is_pi_name(value)
  local lower = tostring(value or ""):lower()
  return lower:find("π", 1, true) ~= nil or lower:match("%f[%w]pi%f[%W]") ~= nil
end

local function title_matches(title, patterns)
  if type(title) ~= "string" then
    return false
  end
  local lower = title:lower()
  for _, pattern in ipairs(patterns or DEFAULT_PATTERNS) do
    local needle = tostring(pattern):lower()
    if (needle == "pi" and is_pi_name(lower)) or (needle ~= "pi" and lower:find(needle, 1, true)) then
      return true
    end
  end
  return false
end

local function detect_agent_from_command(command)
  local lower = tostring(command or ""):lower()
  if lower:find("codex", 1, true) then
    return "Codex"
  end
  if lower:find("claude", 1, true) then
    return "Claude"
  end
  if lower:find("sourcegraph/amp", 1, true) or lower:find("/amp", 1, true) then
    return "Amp"
  end
  -- Pi is often launched behind wrappers (e.g. `node /nix/.../pi-coding-agent/...`);
  -- the `pi-coding-agent` path check covers those. For direct launches only the
  -- invoked program (the FIRST argv token) may match by basename: scanning
  -- every token misclassifies commands that merely mention pi in an argument
  -- (`sudo -u pi bash`, `chown pi file`, `ssh -l pi host`). Bare "pi"
  -- substrings (pip, spotify, pi.txt) must not match either.
  if lower:find("pi-coding-agent", 1, true) then
    return "Pi"
  end
  local program = lower:match("%S+")
  if program and program:match("([^/]+)$") == "pi" then
    return "Pi"
  end
  return nil
end

local function detect_agent_from_screen(screen)
  if type(screen) ~= "string" or screen == "" then
    return nil
  end
  local lower = screen:lower()
  if lower:find("openai codex", 1, true) then
    return "Codex"
  end
  if lower:find("gpt-", 1, true) and lower:find("context", 1, true) and lower:find("tokens", 1, true) then
    return "Codex"
  end
  if lower:find("claude code", 1, true) or lower:find("claude-code", 1, true) then
    return "Claude"
  end
  if lower:find("sourcegraph/amp", 1, true) or lower:match("%f[%w]amp%f[%W]") then
    return "Amp"
  end
  if lower:find("pi coding agent", 1, true) or lower:find("π coding agent", 1, true) then
    return "Pi"
  end
  if lower:find("pi-coding-agent", 1, true) then
    return "Pi"
  end
  -- Pi's TUI header shows a standalone π glyph even when no textual agent
  -- name appears on screen. Plain prose "pi" must not match.
  for token in lower:gmatch("%S+") do
    if token == "π" then
      return "Pi"
    end
  end
  return nil
end

local function agent_from_metadata(surface, patterns)
  local candidates = {}
  local function add(value)
    if type(value) == "string" and value ~= "" then
      table.insert(candidates, value)
    end
  end

  add(surface.agent)
  add(surface.agent_key)
  if type(surface.resume_binding) == "table" then
    add(surface.resume_binding.name)
    add(surface.resume_binding.kind)
  end

  for _, candidate in ipairs(candidates) do
    if title_matches(candidate, patterns) then
      return is_pi_name(candidate) and "Pi" or candidate
    end
  end
  return nil
end

---@param surface string|table
---@return string?
local function surface_ref(surface)
  if type(surface) == "string" then
    return surface
  end
  if type(surface) ~= "table" then
    return nil
  end
  return surface.ref or surface.id
end

---@param surface table|string
---@return string
local function surface_label(surface)
  if type(surface) ~= "table" then
    return tostring(surface)
  end
  local title = surface.tab_title or surface.title or surface.name or "cmux surface"
  local ref = surface_ref(surface) or "?"
  local agent = surface.agent or surface.type
  local status = surface.status
  if type(surface.detail) == "string" and surface.detail ~= "" then
    status = type(status) == "string" and status ~= "" and (status .. " - " .. surface.detail) or surface.detail
  end
  local bits = { shorten(title, 54), "[" .. shorten(ref, 18) .. "]" }
  if type(agent) == "string" and agent ~= "" then
    table.insert(bits, agent)
  end
  if type(surface.tty) == "string" and surface.tty ~= "" then
    table.insert(bits, surface.tty)
  end
  if type(status) == "string" and status ~= "" then
    table.insert(bits, status)
  end
  return table.concat(bits, "  ")
end

local function clean_tmpdir(dir)
  return (tostring(dir or "/tmp"):gsub("/+$", ""))
end

local function read_first_line(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return lines[1]
end

local function state_surface_key(value)
  return (tostring(value or ""):gsub("[^%w%-]", ""))
end

local function read_agent_states(opts)
  local states = {}
  local labels = {}
  local dropped = 0
  local files = vim.fn.glob(clean_tmpdir(opts.agent_state_dir) .. "/cmux-agent-state-*/*.state", false, true)
  for _, file in ipairs(files) do
    local line = read_first_line(file)
    local fields = line and line ~= "" and split_tabs(line) or nil
    local surface_key = fields and fields[6] or nil
    if surface_key and surface_key ~= "" then
      local state = {
        agent_key = fields[1],
        agent_title = fields[2],
        start_ts = tonumber(fields[3]),
        status = fields[4],
        detail = fields[5],
        surface_key = surface_key,
        tab_title = fields[7],
        status_color = fields[8],
        active = fields[9] == "1",
      }
      states[state_surface_key(surface_key)] = state
      table.insert(labels, (state.agent_title or state.agent_key or "agent") .. ":" .. surface_key)
    else
      -- Malformed/empty state file (no surface key): drop it, but leave a
      -- breadcrumb so the "no cmux agent surfaces" error can explain it.
      dropped = dropped + 1
    end
  end
  return states, labels, dropped
end

local function state_for_surface(states, surface)
  return states[state_surface_key(surface.id)]
    or states[state_surface_key(surface.ref)]
    or states[state_surface_key(surface.surface_key)]
end

local function state_matches(state, patterns)
  if type(state) ~= "table" then
    return false
  end
  return title_matches(state.agent_title, patterns) or title_matches(state.agent_key, patterns)
end

local function parse_tree_surface(line)
  local ref = line:match("(surface:%d+)")
  if not ref then
    return nil
  end
  -- Leave title nil when the tree line carries no quoted title, so a real
  -- RPC title can fill it in instead of a placeholder clobbering it.
  return {
    ref = ref,
    title = line:match('%[terminal%]%s+"(.-)"') or line:match('%[browser%]%s+"(.-)"'),
    type = line:match("%[(terminal)%]") or line:match("%[(browser)%]") or "surface",
    tty = line:match("tty=([^%s]+)"),
    is_current = line:find(" here", 1, true) ~= nil,
  }
end

local function parse_tree_result(result)
  if result.code ~= 0 then
    return nil, "cmux tree exited " .. tostring(result.code) .. ": " .. (result.stderr or ""):gsub("%s+$", "")
  end

  local surfaces = {}
  for _, line in ipairs(split_nonempty_lines(result.stdout)) do
    local surface = parse_tree_surface(line)
    if surface then
      table.insert(surfaces, surface)
    end
  end
  if #surfaces == 0 then
    return nil, "cmux tree returned no surfaces"
  end
  return surfaces, nil
end

local function parse_rpc_result(result)
  if result.code ~= 0 then
    return nil, "cmux rpc exited " .. tostring(result.code) .. ": " .. (result.stderr or ""):gsub("%s+$", "")
  end
  local stdout = result.stdout or ""
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" then
    return nil, "cmux rpc returned invalid JSON: " .. stdout:sub(1, 200)
  end
  if type(decoded.surfaces) ~= "table" then
    return nil, "cmux rpc response missing surfaces key"
  end
  return decoded.surfaces, nil
end

local function merge_tree_rpc_surfaces(tree_surfaces, rpc_surfaces)
  local rpc_by_ref = {}
  for _, surface in ipairs(rpc_surfaces or {}) do
    if type(surface) == "table" and surface.ref then
      rpc_by_ref[surface.ref] = surface
    end
  end

  local merged = {}
  for _, surface in ipairs(tree_surfaces) do
    local metadata = rpc_by_ref[surface.ref] or {}
    -- Merge tree fields first, then let RPC metadata win: a real RPC title
    -- must not be clobbered by the tree-parsed (often nil) title. Tree-only
    -- surfaces still get a sensible label via surface_label's fallback.
    table.insert(merged, vim.tbl_extend("force", {}, surface, metadata))
  end
  return merged
end

---@return table[]? surfaces, string? err
local function list_surfaces(opts)
  opts = normalize_opts(opts)
  if not opts.workspace_id or opts.workspace_id == "" then
    return nil, "CMUX_WORKSPACE_ID not set in env"
  end
  -- The tree and rpc listings are independent; fan both out concurrently
  -- and join instead of running two blocking waits back to back.
  local tree_job = vim.system({ cli(opts), "tree", "--workspace", opts.workspace_id }, { text = true })
  local rpc_job = vim.system({
    cli(opts),
    "rpc",
    "surface.list",
    vim.json.encode({ workspace_id = opts.workspace_id }),
  }, { text = true })

  local tree_surfaces, tree_err = parse_tree_result(tree_job:wait())
  local rpc_surfaces, rpc_err = parse_rpc_result(rpc_job:wait())
  if tree_surfaces and rpc_surfaces then
    return merge_tree_rpc_surfaces(tree_surfaces, rpc_surfaces), nil
  end
  if tree_surfaces or rpc_surfaces then
    return tree_surfaces or rpc_surfaces, nil
  end
  return nil, tree_err or rpc_err
end

local function ps_commands_for_tty(tty, cache)
  if not tty or tty == "" then
    return {}
  end
  if cache[tty] then
    return cache[tty]
  end
  if vim.fn.executable("ps") ~= 1 then
    cache[tty] = {}
    return {}
  end

  local result = helpers.system({ "ps", "-t", tty, "-o", "command=" })
  if result.code ~= 0 then
    cache[tty] = {}
    return {}
  end

  local commands = {}
  for _, line in ipairs(split_nonempty_lines(result.stdout)) do
    local command = line:gsub("^%s+", "")
    if command ~= "" then
      table.insert(commands, command)
    end
  end
  cache[tty] = commands
  return commands
end

local function read_surface_screens(opts, surfaces)
  local jobs = {}
  for _, surface in ipairs(surfaces) do
    local ref = surface_ref(surface)
    if ref then
      table.insert(jobs, {
        surface = surface,
        job = vim.system({
          cli(opts),
          "read-screen",
          "--surface",
          ref,
          "--scrollback",
          "--lines",
          tostring(opts.read_screen_lines or 120),
        }, { text = true }),
      })
    end
  end

  local screens = {}
  for _, item in ipairs(jobs) do
    local result = item.job:wait()
    if result.code == 0 then
      screens[item.surface] = result.stdout or ""
    end
  end
  return screens
end

local function is_current_surface(opts, surface)
  if surface.is_current == true then
    return true
  end
  local current = opts.current_surface
  if not current or current == "" then
    return false
  end
  -- Normalize both id and ref forms (tree surfaces only carry .ref) so the
  -- current (nvim) pane is reliably excluded regardless of which key the
  -- environment's CMUX_SURFACE_ID matches.
  local current_key = state_surface_key(current)
  return state_surface_key(surface.id) == current_key
    or state_surface_key(surface.ref) == current_key
    or state_surface_key(surface.surface_key) == current_key
end

local function copy_surface(surface)
  return vim.tbl_extend("force", {}, surface)
end

local function apply_agent_metadata(surface, metadata)
  local out = copy_surface(surface)
  out.agent = metadata.agent or out.agent
  out.agent_key = metadata.agent_key or out.agent_key
  out.status = metadata.status or out.status
  out.detail = metadata.detail or out.detail
  out.tab_title = metadata.tab_title or out.tab_title
  out.active = metadata.active
  out.agent_state = metadata.agent_state
  out.detected_by = metadata.detected_by
  out.tty = metadata.tty or out.tty
  return out
end

-- Worktree -> owning cmux workspace.
--
-- When a review is opened in a linked worktree, the agent that spawned it is
-- not in this cmux workspace: this one holds an editor and a shell, the agent
-- sits in the session the worktree was created from. worktrunk's post-start
-- hook records that session's CMUX_WORKSPACE_ID at
-- `<git-common-dir>/wt/cmux/<branch with / as ->`, so read it back rather than
-- guessing. Agent-agnostic by construction: the hook writes the file whoever
-- ran `wt switch --create`.
---@return string? workspace_id
local function worktree_owner_workspace_id()
  -- Anchor git to the buffer's directory: nvim's cwd may still be the main
  -- checkout when a worktree file was opened by path.
  local dir = vim.fn.expand("%:p:h")
  if dir == "" or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end
  local function git(...)
    local r = helpers.system({ "git", "-C", dir, ... })
    if not r or r.code ~= 0 then
      return ""
    end
    return vim.trim(r.stdout or "")
  end
  local common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
  local private = git("rev-parse", "--path-format=absolute", "--git-dir")
  -- Equal paths mean the main checkout, where the current workspace is right.
  if common == "" or private == "" or common == private then
    return nil
  end
  local branch = git("branch", "--show-current")
  if branch == "" then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, common .. "/wt/cmux/" .. branch:gsub("/", "-"))
  if not ok or type(lines) ~= "table" then
    return nil
  end
  local id = vim.trim(lines[1] or "")
  return id ~= "" and id or nil
end

---Return agent-like surfaces in the current cmux workspace.
---@param opts? table
---@return table[]? surfaces, string? err
function M.list_agent_surfaces(opts)
  opts = normalize_opts(opts)
  local key = cache_key(opts)
  if opts.cache ~= false then
    local cached = agent_surface_cache[key]
    if cached and now_ms() - cached.at <= (opts.cache_ttl_ms or DEFAULT_CACHE_TTL_MS) then
      return cached.surfaces, cached.err
    end
    -- TTL expired (or never cached): evict so stale entries don't pile up.
    agent_surface_cache[key] = nil
  end

  local function finish(surfaces, err)
    if opts.cache ~= false then
      agent_surface_cache[key] = {
        at = now_ms(),
        surfaces = surfaces,
        err = err,
      }
    end
    return surfaces, err
  end

  local surfaces, err = list_surfaces(opts)
  if not surfaces then
    return finish(nil, err)
  end

  local states, state_labels, dropped_states = read_agent_states(opts)
  local ps = {}
  local matches = {}
  local seen = {}
  local titles = {}
  local screen_candidates = {}

  local function add_match(surface, metadata)
    if not metadata then
      return
    end
    local ref = surface_ref(surface)
    local key_for_surface = ref or surface.id or tostring(surface.index or surface)
    if not seen[key_for_surface] then
      seen[key_for_surface] = true
      table.insert(matches, apply_agent_metadata(surface, metadata))
    end
  end

  for _, surface in ipairs(surfaces) do
    if type(surface.title) == "string" then
      table.insert(titles, shorten(surface.title, 40))
    end
    if not is_current_surface(opts, surface) then
      local state = state_for_surface(states, surface)
      local agent = state and (state.agent_title or state.agent_key) or nil
      local rpc_agent = agent_from_metadata(surface, opts.patterns)
      local metadata = nil

      if state and state_matches(state, opts.patterns) then
        metadata = {
          agent = agent,
          agent_key = state.agent_key,
          status = state.status,
          detail = state.detail,
          tab_title = state.tab_title,
          active = state.active,
          agent_state = state,
          detected_by = "state",
        }
      elseif rpc_agent then
        metadata = {
          agent = rpc_agent,
          detected_by = "metadata",
        }
      elseif title_matches(surface.title, opts.patterns) or title_matches(surface.name, opts.patterns) then
        metadata = {
          agent = is_pi_name(surface.title) and "Pi" or surface.agent or surface.type,
          detected_by = "title",
        }
      elseif opts.process_fallback ~= false then
        local tty = surface.tty
        for _, command in ipairs(ps_commands_for_tty(tty, ps)) do
          local command_agent = detect_agent_from_command(command)
          if title_matches(command_agent, opts.patterns) then
            metadata = {
              agent = command_agent,
              detected_by = "tty",
              tty = tty,
            }
            break
          end
        end
      end

      if metadata then
        add_match(surface, metadata)
      else
        table.insert(screen_candidates, surface)
      end
    end
  end

  if #screen_candidates > 0 and opts.screen_fallback ~= false then
    local screens = read_surface_screens(opts, screen_candidates)
    for _, surface in ipairs(screen_candidates) do
      local screen_agent = detect_agent_from_screen(screens[surface])
      if title_matches(screen_agent, opts.patterns) then
        add_match(surface, {
          agent = screen_agent,
          detected_by = "screen",
        })
      end
    end
  end

  if #matches == 0 then
    -- Nothing agent-like here. If this is a linked worktree, the agent lives
    -- in the session that created it; look there before giving up. Guarded by
    -- `_worktree_hop` so the retry can only happen once.
    if not opts._worktree_hop then
      local owner = worktree_owner_workspace_id()
      if owner and owner ~= opts.workspace_id then
        local hop = vim.tbl_extend("force", opts, { workspace_id = owner, _worktree_hop = true })
        local owner_surfaces, owner_err = M.list_agent_surfaces(hop)
        if owner_surfaces and #owner_surfaces > 0 then
          return finish(owner_surfaces, owner_err)
        end
      end
    end
    local dropped_note = (dropped_states or 0) > 0
        and ("; dropped " .. tostring(dropped_states) .. " malformed state file(s)")
      or ""
    return finish(
      matches,
      "no cmux agent surfaces among "
        .. tostring(#surfaces)
        .. " surfaces (titles: "
        .. table.concat(titles, ", ")
        .. "; agent states: "
        .. (#state_labels > 0 and table.concat(state_labels, ", ") or "none")
        .. dropped_note
        .. ")"
    )
  end
  return finish(matches, nil)
end

---Whether cmux integration can be used in the current environment.
---@param opts? table
---@return boolean
function M.is_available(opts)
  opts = normalize_opts(opts)
  return opts.workspace_id ~= nil and opts.workspace_id ~= "" and helpers.executable(cli(opts))
end

-- Run `fn` after `ms` milliseconds without blocking the UI; immediately
-- when the delay is zero or unset.
local function defer_ms(ms, fn)
  ms = tonumber(ms) or 0
  if ms <= 0 then
    fn()
    return
  end
  vim.defer_fn(fn, ms)
end

-- Split text into segments that each keep their trailing newline, so the
-- segments concatenate back to the exact original bytes.
local function split_keep_newlines(text)
  local out = {}
  local pos, n = 1, #text
  while pos <= n do
    local nl = text:find("\n", pos, true)
    if nl then
      table.insert(out, text:sub(pos, nl)) -- include the newline
      pos = nl + 1
    else
      table.insert(out, text:sub(pos))
      pos = n + 1
    end
  end
  return out
end

-- Chunk text into byte-bounded pieces, preferring line boundaries. A single
-- line longer than max_bytes is split by bytes. Concatenating the returned
-- chunks in order reproduces the original text byte-for-byte.
local function chunk_text(text, max_bytes)
  max_bytes = math.max(1, math.floor(tonumber(max_bytes) or 1024))
  local chunks, buf, buf_len = {}, {}, 0
  local function flush()
    if buf_len > 0 then
      table.insert(chunks, table.concat(buf))
      buf, buf_len = {}, 0
    end
  end
  for _, seg in ipairs(split_keep_newlines(text)) do
    if #seg > max_bytes then
      flush()
      local i = 1
      while i <= #seg do
        table.insert(chunks, seg:sub(i, i + max_bytes - 1))
        i = i + max_bytes
      end
    elseif buf_len + #seg > max_bytes then
      flush()
      table.insert(buf, seg)
      buf_len = #seg
    else
      table.insert(buf, seg)
      buf_len = buf_len + #seg
    end
  end
  flush()
  return chunks
end

-- Compose an actionable error for a chunked paste that failed partway. The
-- cmux CLI surface used here pastes per chunk (no atomic append+paste), so a
-- failure can leave a truncated review in the pane; tell the caller how many
-- chunks landed and that the pane should be cleared before retrying. When
-- nothing pasted the pane is untouched, so say a plain retry is safe.
local function partial_paste_error(pasted, total, detail)
  local msg
  if pasted == 0 then
    msg =
      string.format("cmux paste failed before any of %d chunks landed; the pane is untouched — safe to retry", total)
  else
    msg = string.format(
      "cmux paste failed after %d/%d chunks; the pane holds a truncated review — clear it before retrying",
      pasted,
      total
    )
  end
  if detail and detail ~= "" then
    msg = msg .. " (" .. detail .. ")"
  end
  return msg
end

-- Upload and paste one chunk at a time. This bounds child-process load and
-- avoids this send competing with itself for cmux's buffer storage.
-- Retain retries for dropped uploads, including contention with other clients.
local function send_chunked(opts, ref, text, chunk_bytes, done)
  local chunks = chunk_text(text, chunk_bytes)
  local total = #chunks
  local retries = math.max(0, math.floor(tonumber(opts.paste_retries) or 2))
  local stamp = string.format("%d", vim.uv.hrtime())
  local send_chunk

  local function retry_or_fail(idx, attempt, detail)
    if attempt >= retries then
      done(false, partial_paste_error(idx - 1, total, detail))
      return
    end
    defer_ms(opts.paste_chunk_delay_ms, function()
      send_chunk(idx, attempt + 1)
    end)
  end

  send_chunk = function(idx, attempt)
    local name = "pjollrig-" .. stamp .. "-" .. idx
    helpers.system_async({ cli(opts), "set-buffer", "--name", name, "--", chunks[idx] }, nil, function(upload)
      if upload.code ~= 0 then
        retry_or_fail(idx, attempt, (upload.stderr:gsub("%s+$", "")))
        return
      end
      helpers.system_async({ cli(opts), "paste-buffer", "--name", name, "--surface", ref }, nil, function(paste)
        if paste.code ~= 0 then
          retry_or_fail(idx, attempt, (paste.stderr:gsub("%s+$", "")))
          return
        end
        if idx == total then
          done(true)
          return
        end
        defer_ms(opts.paste_chunk_delay_ms, function()
          send_chunk(idx + 1, 0)
        end)
      end)
    end)
  end

  send_chunk(1, 0)
end

local function send_text(opts, surface, text, cb)
  local ref = surface_ref(surface)
  if not ref or ref == "" then
    cb(false, "cmux target has no surface ref")
    return
  end
  text = tostring(text or "")
  local chunk_bytes = math.max(1, math.floor(tonumber(opts.paste_chunk_bytes) or 1024))

  -- After the text has landed: auto-submit (deferred, not busy-waited)
  -- unless disabled, then report to the caller.
  local function submit(ok, err)
    if not ok then
      cb(false, err)
      return
    end
    if opts.auto_submit == false then
      cb(true, nil)
      return
    end
    defer_ms(opts.submit_delay_ms, function()
      helpers.system_async({ cli(opts), "send-key", "--surface", ref, "enter" }, nil, function(key_result)
        if key_result.code ~= 0 then
          cb(false, "text landed but submit failed; press Enter in the cmux pane manually")
          return
        end
        cb(true, nil)
      end)
    end)
  end

  -- Route through the chunked set-buffer/paste-buffer path whenever the
  -- payload is multiline OR larger than the chunk threshold. A single,
  -- newline-free payload that exceeds the threshold must NOT be passed as
  -- one argv to `cmux send --` (it can fail at the exec layer with E2BIG).
  -- The small/simple `cmux send` path stays only for genuinely small,
  -- single-line payloads.
  if text:find("\n", 1, true) or #text > chunk_bytes then
    send_chunked(opts, ref, text, chunk_bytes, submit)
  else
    helpers.system_async({ cli(opts), "send", "--surface", ref, "--", text }, nil, function(result)
      if result.code ~= 0 then
        submit(false, (result.stderr:gsub("%s+$", "")))
        return
      end
      submit(true, nil)
    end)
  end
end

local function pick_surface(opts, cb)
  local surfaces, err = M.list_agent_surfaces(opts)
  if not surfaces or #surfaces == 0 then
    cb(nil, err or "no cmux agent surfaces found")
    return
  end
  if #surfaces == 1 then
    cb(surfaces[1])
    return
  end
  require("pjollrig.ui.select").select(surfaces, {
    prompt = opts.picker_prompt,
    format_item = surface_label,
  }, function(surface)
    cb(surface, surface and nil or "cancelled")
  end)
end

local function ctx_surface(ctx)
  ctx = ctx or {}
  return ctx.surface or ctx.surface_ref or ctx.agent_id
end

---Build a cmux sink spec.
---@param opts? table
---@return table
function M.setup(opts)
  opts = normalize_opts(opts)
  return {
    name = "cmux",
    type = "integration",
    label = "cmux agent",
    description = "send review to a running cmux coding agent",
    clear_on_success = opts.clear_on_success,
    pre_text = opts.pre_text,
    post_text = opts.post_text,
    validate = function(ctx)
      if ctx_surface(ctx) then
        return true
      end
      if not helpers.executable(cli(opts)) then
        return false, "cmux executable not found: " .. tostring(cli(opts))
      end
      local surfaces, err = M.list_agent_surfaces(opts)
      if not surfaces or #surfaces == 0 then
        return false, err or "no cmux agent surfaces found"
      end
      return true
    end,
    health = function()
      return {
        command = cli(opts),
        available = M.is_available(opts),
        workspace_id = opts.workspace_id,
      }
    end,
    send = function(comments, ctx, cb)
      local target = ctx_surface(ctx)
      local text = helpers.format_markdown_review(comments, opts)
      if target then
        send_text(opts, target, text, cb)
        return
      end
      pick_surface(opts, function(surface, err)
        if not surface then
          cb(false, err or "cancelled")
          return
        end
        send_text(opts, surface, text, function(ok, send_err)
          if ok then
            vim.notify("Review sent to " .. surface_label(surface), vim.log.levels.INFO)
          end
          cb(ok, send_err)
        end)
      end)
    end,
  }
end

-- Exposed for unit tests only.
M._internal = {
  detect_agent_from_command = detect_agent_from_command,
  detect_agent_from_screen = detect_agent_from_screen,
}

return M
