-- pjollrig.nvim: command-line completion for :PjollrigReview.
--
-- Candidates come from subprocesses (git, gh) or a transcript scan
-- (chat), so results are cached for a short TTL: repeated <Tab> presses
-- must not re-spawn processes or re-read files. Completion never errors
-- — any failure degrades to an empty (or minimal) list.

local M = {}

local uv = vim.uv

local CACHE_TTL_MS = 10 * 1000

---@type table<string, {at: number, items: string[]}>
local cache = {}

local function now_ms()
  return uv.hrtime() / 1e6
end

---Memoize `fn()` under `key` for CACHE_TTL_MS.
---@param key string
---@param fn fun(): string[]
---@return string[]
local function cached(key, fn)
  local hit = cache[key]
  local now = now_ms()
  if hit and now - hit.at < CACHE_TTL_MS then
    return hit.items
  end
  local items = fn()
  cache[key] = { at = now, items = items }
  return items
end

---Run `argv` and return stdout lines; empty on any failure.
---@param argv string[]
---@return string[]
local function lines(argv)
  local ok, job = pcall(vim.system, argv, { text = true })
  if not ok then
    return {}
  end
  local result = job:wait()
  if result.code ~= 0 then
    return {}
  end
  return vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true })
end

---First-argument candidates: local branches, remote-tracking branches
---(e.g. `origin/main` — the git resolver merge-bases any rev), and the
---literal resolver keywords `pr` and `chat`.
---@return string[]
local function refs()
  return cached("refs:" .. tostring(uv.cwd()), function()
    local out = lines({ "git", "branch", "--format=%(refname:short)" })
    vim.list_extend(out, lines({ "git", "for-each-ref", "refs/remotes", "--format=%(refname:short)" }))
    table.insert(out, "pr")
    table.insert(out, "chat")
    return out
  end)
end

---Open PR numbers via the gh CLI. Plain number strings — cmdline
---completion tokens can't carry display text like titles.
---@return string[]
local function pr_numbers()
  return cached("pr:" .. tostring(uv.cwd()), function()
    if vim.fn.executable("gh") ~= 1 then
      return {}
    end
    local raw = lines({ "gh", "pr", "list", "--json", "number,title", "--limit", "50" })
    local ok, prs = pcall(vim.json.decode, table.concat(raw, "\n"))
    if not ok or type(prs) ~= "table" then
      return {}
    end
    local out = {}
    for _, pr in ipairs(prs) do
      if type(pr) == "table" and pr.number ~= nil then
        table.insert(out, tostring(pr.number))
      end
    end
    return out
  end)
end

---`chat` position: `all` plus `1..n` for the kept turns of the newest
---session (review/chat.lua's numbering, 1 = latest). File IO only, but a
---big transcript is still a full read+scan, hence the same cache. Any
---failure (no transcripts dir, unrecognized shape) degrades to `all`.
---@return string[]
local function chat_args()
  return cached("chat:" .. tostring(uv.cwd()), function()
    local out = { "all" }
    local ok, count = pcall(function()
      local chat = require("pjollrig.review.chat")
      local sessions = chat.list_sessions()
      if not sessions or #sessions == 0 then
        return 0
      end
      local turns = chat.list_turns(sessions[1])
      return turns and #turns or 0
    end)
    for i = 1, ok and count or 0 do
      table.insert(out, tostring(i))
    end
    return out
  end)
end

---Completion candidates for :PjollrigReview, prefix-filtered by arglead.
---@param arglead string
---@param cmdline string
---@return string[]
function M.candidates(arglead, cmdline)
  local items
  if cmdline:match("PjollrigReview%s+pr%s+%S*$") then
    items = pr_numbers()
  elseif cmdline:match("PjollrigReview%s+chat%s+%S*$") then
    items = chat_args()
  elseif cmdline:match("PjollrigReview%s+%S*$") then
    items = refs()
  else
    return {}
  end
  local out = {}
  for _, item in ipairs(items) do
    if vim.startswith(item, arglead) then
      table.insert(out, item)
    end
  end
  return out
end

function M._reset()
  cache = {}
end

return M
