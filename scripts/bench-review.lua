#!/usr/bin/env -S nvim --clean --headless -l

local uv = vim.uv
local project = uv.cwd()
vim.opt.runtimepath:prepend(project)
package.path = table.concat({ project .. "/lua/?.lua", project .. "/lua/?/init.lua", package.path }, ";")

local function run(argv, cwd)
  local result = vim.system(argv, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, ("%s failed:\n%s"):format(table.concat(argv, " "), result.stderr or ""))
  return result
end

local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "wb"))
  fd:write(content)
  fd:close()
end

local function elapsed_ms(fn)
  local start = uv.hrtime()
  local result = fn()
  return (uv.hrtime() - start) / 1e6, result
end

local function find_upvalue(fn, wanted)
  for index = 1, 100 do
    local name, value = debug.getupvalue(fn, index)
    if not name then
      break
    end
    if name == wanted then
      return value
    end
  end
  error("missing upvalue " .. wanted)
end

local root = assert(uv.fs_mkdtemp((vim.env.TMPDIR or "/tmp"):gsub("/$", "") .. "/pjollrig-bench-XXXXXX"))
local stage_resolve = root .. "-resolve"
local stage_only = root .. "-stage"

local function cleanup()
  if vim.env.PJOLLRIG_BENCH_KEEP == "1" then
    print("benchmark repo: " .. root)
    return
  end
  vim.fn.delete(root, "rf")
  vim.fn.delete(stage_resolve, "rf")
  vim.fn.delete(stage_only, "rf")
end

local ok, err = xpcall(function()
  run({ "git", "init", "-q", "-b", "main", root })
  run({ "git", "config", "user.email", "benchmark@pjollrig.local" }, root)
  run({ "git", "config", "user.name", "Pjollrig Benchmark" }, root)
  run({ "git", "config", "commit.gpgsign", "false" }, root)

  -- 667 modified + 667 deleted tracked files, then 666 untracked additions.
  for index = 1, 1334 do
    local path = root .. ("/pkg/%04d/module.lua"):format(index)
    write(path, ("local M = {}\nM.value = %d\nreturn M\n"):format(index))
  end
  run({ "git", "add", "." }, root)
  run({ "git", "commit", "-qm", "benchmark baseline" }, root)
  run({ "git", "checkout", "-qb", "bench" }, root)

  for index = 1, 667 do
    local path = root .. ("/pkg/%04d/module.lua"):format(index)
    write(path, ("local M = {}\nM.value = %d\nM.changed = true\nreturn M\n"):format(index))
  end
  for index = 668, 1334 do
    assert(vim.fn.delete(root .. ("/pkg/%04d/module.lua"):format(index)) == 0)
  end
  for index = 1335, 2000 do
    local path = root .. ("/pkg/%04d/module.lua"):format(index)
    write(path, ("local M = {}\nM.value = %d\nM.added = true\nreturn M\n"):format(index))
  end

  local S = require("pjollrig.review.sources")
  local G = require("pjollrig.review.git")

  local resolve_ms, resolved = elapsed_ms(function()
    return assert(S.resolve({ "main" }, { cwd = root, stage_dir = stage_resolve }))
  end)
  assert(#resolved.files == 2000, ("expected 2000 resolved files, got %d"):format(#resolved.files))

  local base = assert(G.merge_base(root, "HEAD", "main"))
  local changed = assert(G.changed_files(root, base))
  assert(#changed == 2000, ("expected 2000 changed files, got %d"):format(#changed))
  local stage_ms, staged = elapsed_ms(function()
    return G.stage_baseline(root, base, changed, stage_only)
  end)
  assert(#staged == 2000)

  local comments = {}
  local uri_mod = require("pjollrig.uri")
  for index = 1, 500 do
    local pair = resolved.files[index]
    local path = pair.status == "D" and pair.left or pair.right
    comments[index] = {
      id = tostring(index),
      uri = uri_mod.for_path(path),
      body = "benchmark comment",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    }
  end
  -- The store is stubbed by design: resolve/stage/panel-row building are
  -- the benchmark targets, not SQLite I/O.
  package.loaded["pjollrig"] = {
    list = function()
      return comments
    end,
  }
  -- Mirror the session shape review.start builds, including the cached
  -- uris/root the panel reads (review.state() carries them since the
  -- session-cache change; older builds ignore the extra fields).
  -- pair_path and diffstat come off the REAL review module, captured
  -- before it is stubbed below.
  local pair_path = require("pjollrig.review").pair_path
  local session_uris = {}
  local session_uri_set = {}
  for index, pair in ipairs(resolved.files) do
    local uri = uri_mod.for_path(pair_path(pair))
    session_uris[index] = uri
    session_uri_set[uri] = true
  end
  -- Diffstat pass: what the FIRST panel render of a session pays — read
  -- both sides of every M pair and vim.diff them (A/D shortcut to one
  -- side's line count). Measured on the REAL review module (explicit
  -- files bypass the session cache) before it is stubbed; the result
  -- feeds the stub below, mirroring the session cache, so the
  -- row-building numbers stay row-building only.
  local real_diffstat = require("pjollrig.review").diffstat
  local panel_diffstat_ms, session_diffstat = elapsed_ms(function()
    return real_diffstat(resolved.files)
  end)
  assert(#session_diffstat == 2000)
  package.loaded["pjollrig.review"] = {
    state = function()
      return {
        files = resolved.files,
        label = "benchmark",
        uris = session_uris,
        uri_set = session_uri_set,
        root = root,
      }
    end,
    pair_path = pair_path,
    diffstat = function()
      return session_diffstat
    end,
  }
  package.loaded["pjollrig.review.panel"] = nil
  local panel = require("pjollrig.review.panel")
  -- build_file_rows sits behind render since the owned-buffer rewrite;
  -- chase it through the upvalue chain.
  local render = find_upvalue(panel.open, "render")
  local build_file_rows = find_upvalue(render, "build_file_rows")
  local panel_ms, items = elapsed_ms(build_file_rows)
  assert(#items == 2000)

  -- Icons pass: headless `--clean` loads no icon provider, so the plain
  -- panel number above silently skips the icon branch. Stub a provider
  -- (the icons_spec pattern) and force icons on so that branch is
  -- measured too, reported as its own line.
  package.preload["mini.icons"] = function()
    return {
      get = function(_category, _name)
        return "X", "MiniIconsAzure", false
      end,
    }
  end
  require("pjollrig.config").get().ui.icons = true
  require("pjollrig.ui.icons")._reset()
  local panel_icons_ms, icon_items = elapsed_ms(build_file_rows)
  assert(#icon_items == 2000)

  print(("files: %d (M=667 A=666 D=667), comments: %d"):format(#changed, #comments))
  print(("resolve_ms: %.3f"):format(resolve_ms))
  print(("stage_baseline_ms: %.3f"):format(stage_ms))
  print(("panel_diffstat_ms: %.3f"):format(panel_diffstat_ms))
  print(("panel_build_file_rows_ms: %.3f"):format(panel_ms))
  print(("panel_build_file_rows_icons_ms: %.3f"):format(panel_icons_ms))
end, debug.traceback)

cleanup()
if not ok then
  error(err)
end
