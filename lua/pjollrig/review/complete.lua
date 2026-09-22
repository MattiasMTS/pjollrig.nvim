-- Local Git-ref completion. Cache subprocess results across repeated <Tab>s.
local M = {}
local uv = vim.uv
local CACHE_TTL_MS = 10 * 1000
local cache = {}

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

local function refs()
  local key = tostring(uv.cwd())
  local now = uv.hrtime() / 1e6
  local hit = cache[key]
  if hit and now - hit.at < CACHE_TTL_MS then
    return hit.items
  end
  local items = lines({ "git", "for-each-ref", "refs/heads", "refs/remotes", "--format=%(refname:short)" })
  cache[key] = { at = now, items = items }
  return items
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.candidates(arglead, cmdline)
  if not cmdline:match("PjollrigReview%s+%S*$") then
    return {}
  end
  local out = {}
  for _, item in ipairs(refs()) do
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
