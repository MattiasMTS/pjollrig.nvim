-- Child process for store_spec: nvim --headless -l tests/store_worker.lua <go-file> <root> <role> [n]
local uv, S = vim.uv, require("pjollrig.store")
local go, root, role, n = arg[1], arg[2], arg[3], tonumber(arg[4] or 100)
while not uv.fs_stat(go) do -- barrier: all workers start together
  uv.sleep(1)
end
if role == "add" then
  for i = 1, n do
    S.patch(
      root,
      { { S.id(), { path = "a.lua", side = "new", lnum = i, line = "x", body = "b", pid = uv.os_getpid() } } }
    )
  end
elseif role == "stale" then -- loaded once, never re-reads, then :w-syncs every comment's position
  for id, r in pairs(vim.deepcopy(S.load(root))) do
    S.patch(root, { { id, { lnum = r.lnum + 1, end_lnum = r.lnum + 1, line = "moved" } } })
  end
elseif role == "resolve" then
  for i = 1, n do
    S.patch(root, { { "s" .. i, { resolved = true, sent_to = "pi" } } })
  end
elseif role == "edit" then
  for i = 1, n do
    S.patch(root, { { "s" .. i, { body = "edited" } } })
  end
elseif role == "torn" then -- crash mid-write leaves a fragment without newline; a later nvim appends normally
  local fd = uv.fs_open(S.path(root), "a", 420)
  uv.fs_write(fd, '\n{"id":"s5","at":1,"set":{"bo')
  uv.fs_close(fd)
  S.patch(root, { { "after-torn", { path = "a.lua", side = "new", lnum = 1, line = "x", body = "survives" } } })
end
