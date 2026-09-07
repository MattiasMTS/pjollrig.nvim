-- pjollrig.nvim: tiny unique id generator.
--
-- Not a UUID. Combines the high-resolution monotonic clock with 4 random
-- hex chars so collisions within a single Neovim session are unlikely
-- enough to ignore. Good enough for a single-user, per-project store.

local M = {}

-- Seed the RNG once at module load. `math.random` is otherwise
-- deterministic across same-PID process starts, which would make
-- `id.new()`'s random suffix predictable and raise collision risk. Mix
-- the high-resolution monotonic clock with the pid and wall-clock time
-- so two near-simultaneous Neovim starts don't share a seed.
do
  local hr = vim.uv.hrtime()
  math.randomseed(hr % 0x7fffffff + vim.fn.getpid() + os.time())
end

---Generate a new unique id.
---@return string
function M.new()
  local hr = vim.uv.hrtime()
  return string.format("%x-%04x", hr, math.random(0, 0xffff))
end

return M
