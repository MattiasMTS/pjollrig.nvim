local M = {}

local uv = vim.uv

local function path_join(...)
  return table.concat({ ... }, "/"):gsub("/+", "/")
end

local function can_write_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return false, "empty directory"
  end
  local stat = uv.fs_stat(dir)
  if not stat then
    return false, "directory does not exist"
  end
  if stat.type ~= "directory" then
    return false, "path is not a directory"
  end

  local probe = path_join(dir:gsub("/$", ""), ".pjollrig-health-" .. tostring(vim.fn.getpid()))
  local fd, open_err = uv.fs_open(probe, "w", 384) -- 0o600
  if not fd then
    return false, open_err or "open failed"
  end
  local _, write_err = uv.fs_write(fd, "ok", 0)
  uv.fs_close(fd)
  pcall(uv.fs_unlink, probe)
  if write_err then
    return false, write_err
  end
  return true, nil
end

local function glob_count(pattern)
  local ok, files = pcall(vim.fn.glob, pattern, false, true)
  if not ok or type(files) ~= "table" then
    return 0
  end
  return #files
end

---@return table
function M._collect()
  local config = require("pjollrig.config").get()
  local store = require("pjollrig.store")
  local sinks = require("pjollrig.sinks")
  local cmux = require("pjollrig.sinks.cmux")

  local store_cfg = config.store or {}
  local store_dir = store_cfg.dir or ""
  local store_stat = store_dir ~= "" and uv.fs_stat(store_dir) or nil
  local store_writable, store_write_err = can_write_dir(store_dir)
  local session_store_files = store_dir ~= ""
      and glob_count(store_dir:gsub("/$", "") .. "/session." .. tostring(store_cfg.format))
    or 0
  local sqlite_store_files = store_dir ~= "" and glob_count(store_dir:gsub("/$", "") .. "/*.sqlite3") or 0
  local sqlite_info = store.sqlite_info(store.root())

  local sink_names = sinks.list()
  local sink_health = {}
  for name, spec in pairs(sinks.all()) do
    if type(spec.health) == "function" then
      local ok, result = pcall(spec.health)
      sink_health[name] = ok and result or { err = result }
    end
  end

  local cmux_cfg = (config.sinks or {}).cmux
  local cmux_opts = type(cmux_cfg) == "table" and cmux_cfg or {}

  -- Derive cmux availability from a single source so :checkhealth can't
  -- report inconsistent registered/available states: when the integration is
  -- registered, trust its health closure (computed from the opts it was
  -- registered with); only recompute from live config when unregistered.
  local cmux_registered = sinks.get("cmux") ~= nil
  local cmux_available
  if cmux_registered and type(sink_health.cmux) == "table" then
    cmux_available = sink_health.cmux.available == true
  else
    cmux_available = cmux.is_available(cmux_opts)
  end

  return {
    nvim = {
      version = vim.version(),
      has_required = vim.fn.has("nvim-0.12") == 1,
      has_vim_system = type(vim.system) == "function",
      has_vim_fs_root = type(vim.fs) == "table" and type(vim.fs.root) == "function",
      has_mpack = type(vim.mpack) == "table" and type(vim.mpack.encode) == "function",
    },
    store = {
      dir = store_dir,
      exists = store_stat ~= nil and store_stat.type == "directory",
      writable = store_writable,
      write_error = store_write_err,
      format = store_cfg.format,
      poll_interval_ms = store_cfg.poll_interval_ms,
      schema_version = store.schema_version(),
      root_markers = store_cfg.root_markers or {},
      current_root = store.root(),
      session_file_count = session_store_files,
      sqlite_file_count = sqlite_store_files,
      sqlite_available = sqlite_info.available,
      sqlite_available_error = sqlite_info.available_error,
      sqlite_journal_mode = sqlite_info.journal_mode,
    },
    sinks = {
      names = sink_names,
      health = sink_health,
      clipboard_registered = sinks.get("clipboard") ~= nil,
      clipboard_available = vim.fn.has("clipboard") == 1,
      cmux_registered = cmux_registered,
      cmux_available = cmux_available,
    },
  }
end

local function list_join(values)
  if not values or #values == 0 then
    return "(none)"
  end
  return table.concat(values, ", ")
end

function M.check()
  local health = vim.health
  local snapshot = M._collect()

  health.start("pjollrig.nvim")
  if snapshot.nvim.has_required then
    local version = snapshot.nvim.version
    health.ok(("Neovim version: %d.%d.%d"):format(version.major, version.minor, version.patch))
  else
    health.error("pjollrig requires Neovim >= 0.12")
  end
  if snapshot.nvim.has_vim_system then
    health.ok("vim.system is available")
  else
    health.error("vim.system is unavailable; update Neovim")
  end
  if snapshot.nvim.has_vim_fs_root then
    health.ok("vim.fs.root is available")
  else
    health.error("vim.fs.root is unavailable; update Neovim")
  end
  if snapshot.nvim.has_mpack then
    health.ok("vim.mpack is available")
  else
    health.error("vim.mpack is unavailable; mpack stores cannot be written")
  end

  health.start("pjollrig store")
  health.info("store.dir: " .. tostring(snapshot.store.dir))
  health.info("store.format: " .. tostring(snapshot.store.format))
  health.info("store.poll_interval_ms: " .. tostring(snapshot.store.poll_interval_ms))
  health.info("store.schema_version: " .. tostring(snapshot.store.schema_version))
  if snapshot.store.exists then
    health.ok("store directory exists")
  else
    health.warn("store directory does not exist; call require('pjollrig').setup() before using the plugin")
  end
  if not snapshot.store.exists then
    health.warn("store writability skipped because the directory is missing")
  elseif snapshot.store.writable then
    health.ok("store directory is writable")
  else
    health.error("store directory is not writable: " .. tostring(snapshot.store.write_error))
  end
  if type(snapshot.store.root_markers) == "table" and #snapshot.store.root_markers > 0 then
    health.ok("root markers: " .. table.concat(snapshot.store.root_markers, ", "))
  else
    health.warn("store.root_markers is empty; project-scope records will not resolve")
  end
  if snapshot.store.current_root then
    health.info("current project root: " .. snapshot.store.current_root)
  else
    health.info("current buffer has no project root")
  end
  if snapshot.store.sqlite_available then
    health.ok("SQLite library is available")
  else
    health.error("SQLite library is unavailable: " .. tostring(snapshot.store.sqlite_available_error))
  end
  if snapshot.store.sqlite_journal_mode then
    if snapshot.store.sqlite_journal_mode == "wal" then
      health.ok("SQLite journal_mode: wal")
    else
      health.warn("SQLite journal_mode: " .. tostring(snapshot.store.sqlite_journal_mode))
    end
  end
  health.info("SQLite project stores: " .. tostring(snapshot.store.sqlite_file_count))
  health.info("session store files: " .. tostring(snapshot.store.session_file_count))

  health.start("pjollrig sinks")
  health.info("registered sinks: " .. list_join(snapshot.sinks.names))
  if #snapshot.sinks.names == 0 then
    health.warn("no sinks registered; call require('pjollrig').setup()")
  end
  if snapshot.sinks.clipboard_registered then
    if snapshot.sinks.clipboard_available then
      health.ok("clipboard sink registered and + clipboard is available")
    else
      health.warn("clipboard sink registered but Neovim has no + clipboard provider")
    end
  else
    health.info("clipboard sink is not registered")
  end
  if snapshot.sinks.cmux_registered then
    local cmux_health = snapshot.sinks.health.cmux or {}
    if cmux_health.available then
      health.ok("cmux integration registered and available: " .. tostring(cmux_health.command))
    else
      health.warn("cmux integration registered but unavailable: " .. tostring(cmux_health.command or "cmux"))
    end
    if cmux_health.workspace_id then
      health.info("cmux workspace: " .. tostring(cmux_health.workspace_id))
    end
  elseif snapshot.sinks.cmux_available then
    health.info("cmux is available but the integration is not registered")
  else
    health.info("cmux integration is not registered")
  end

  health.start("pjollrig review mode")
  if vim.fn.executable("git") == 1 then
    health.ok("git is available")
  else
    health.warn("git is not available; :PjollrigReview needs git for ref/pr resolvers")
  end
  if vim.fn.executable("tar") == 1 then
    health.ok("tar is available")
  else
    health.warn("tar is not available; review baseline staging degrades or fails without it")
  end
  if vim.fn.executable("gh") == 1 then
    health.ok("gh CLI is available")
  else
    health.info("gh CLI not found; :PjollrigReview pr <n> is disabled")
  end
end

return M
