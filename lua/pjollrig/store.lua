-- JSONL patch-event log, one file per realroot. Each line: {"id":..,"at":seconds,"set":{field=value,..}}.
-- Replay merges `set` into the record, so writers touching different fields commute (a stale :w move can
-- never undo another nvim's `resolved`). Fields are never unset: write false/explicit values instead.
-- Roots not starting with "/" ("buffer:<n>") live in memory only.
-- ponytail: no compaction (~200 B per mutation); add snapshot+rename when a log reaches a few MB.
local M = {}
local uv = vim.uv
local cache = {} -- cache[path] = {key, recs, bad}
M.mem = {} -- mem[root] = recs

function M.path(root)
  return vim.fn.stdpath("state") .. "/pjollrig/" .. root:gsub("[/\\:]", "%%") .. ".jsonl"
end

local seq = 0
function M.id() -- unique across concurrent nvims: pid differs; time+seq differs within one pid
  seq = seq + 1
  return ("%x-%x-%x"):format(os.time(), uv.os_getpid(), seq)
end

---Stat-gated full replay: free when the file is unchanged, re-read otherwise (other nvims write too).
---@return table<string, table> records by id (tombstones have deleted=true)
function M.load(root)
  if root:sub(1, 1) ~= "/" then
    return M.mem[root] or {}
  end
  local p = M.path(root)
  local st = uv.fs_stat(p)
  local key = st and ("%d:%d:%d:%d"):format(st.ino, st.size, st.mtime.sec, st.mtime.nsec) or ""
  if cache[p] and cache[p].key == key then
    return cache[p].recs
  end
  local recs = {}
  for line in st and io.lines(p) or function() end do
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true } })
    if ok and type(ev) == "table" and type(ev.id) == "string" and type(ev.set) == "table" then
      recs[ev.id] = vim.tbl_extend("force", recs[ev.id] or { id = ev.id }, ev.set)
    end -- else: torn tail from a crash, or a hand edit: skip, never rewrite
  end
  cache[p] = { key = key, recs = recs }
  return recs
end

---@param patches {[1]:string, [2]:table}[] list of {id, fields}; written with ONE write(2)
function M.patch(root, patches)
  if root:sub(1, 1) ~= "/" then
    local recs = M.mem[root] or {}
    M.mem[root] = recs
    for _, p in ipairs(patches) do
      recs[p[1]] = vim.tbl_extend("force", recs[p[1]] or { id = p[1] }, p[2])
    end
    return recs
  end
  local t, now = {}, os.time()
  for _, p in ipairs(patches) do
    t[#t + 1] = "\n" .. vim.json.encode({ id = p[1], at = now, set = p[2] }) -- leading \n ends any torn tail
  end
  local path, s = M.path(root), table.concat(t)
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p") -- races with other nvims: EEXIST is fine
  local fd = assert(uv.fs_open(path, "a", 420))
  local n, err = uv.fs_write(fd, s)
  uv.fs_close(fd)
  assert(n, err)
  return M.load(root) -- re-read: picks up other nvims' events too
end

return M
