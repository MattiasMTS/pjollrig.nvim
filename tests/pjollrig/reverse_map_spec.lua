-- Exercises the reverse-map for nvim-runtime-staged buffer paths and
-- the `M.add` URI invariant canary.

local adapter
local uri_mod
local tmp_state
local tmp_root
local saved_home

local function project_subdir(name)
  local cwd = vim.uv.cwd() or vim.fn.getcwd()
  local base = vim.fs.normalize(vim.fn.fnamemodify(cwd .. "/" .. name, ":p"))
  vim.fn.mkdir(base, "p")
  return base
end

---Build a realistic-looking nvim-runtime staged path under the current
---`stdpath('run')`, creating the staged file with the given `body` so
---`fs_stat` succeeds. Mirrors what a tempname-based `:DiffTool` would
---produce.
local function make_staged_file(relative, body)
  local run = vim.fs.normalize(vim.fn.stdpath("run"))
  local bucket = run .. "/" .. tostring(math.random(1e9))
  local full = bucket .. "/" .. relative
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  vim.fn.writefile(body or { "" }, full)
  return full
end

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = project_subdir(".pjollrig-reverse-map-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6)))
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  -- Point HOME at a sandbox so the reverse-map's HOME fallback cannot
  -- collide with the runner's real `~/.config` tree.
  saved_home = vim.env.HOME
  local sandbox_home = vim.fn.tempname()
  vim.fn.mkdir(sandbox_home, "p")
  vim.env.HOME = sandbox_home

  require("pjollrig.store")._reset()
  require("pjollrig").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      canonicalize_symlinks = false,
      poll_interval_ms = 0,
    },
  })
  adapter = require("pjollrig.adapter")
  uri_mod = require("pjollrig.uri")
end

local function teardown_env()
  require("pjollrig.store")._reset()
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "enew!")
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
  if saved_home ~= nil then
    local cur_home = vim.env.HOME
    vim.env.HOME = saved_home
    if cur_home and cur_home ~= saved_home then
      pcall(vim.fn.delete, cur_home, "rf")
    end
  end
end

describe("pjollrig.uri nvim-runtime shape detection", function()
  it("is_nvim_runtime_staged_path matches the nvim.<user>/<run-id>/<N>/... shape", function()
    local uri = require("pjollrig.uri")
    assert.is_true(uri.is_nvim_runtime_staged_path("/var/folders/xx/yy/T/nvim.user/ABCDEF/1/.config/foo.txt"))
    assert.is_true(uri.is_nvim_runtime_staged_path("/private/var/folders/xx/yy/T/nvim.user/ABCDEF/1/src/foo.lua"))
    assert.is_true(uri.is_nvim_runtime_staged_path(uri.run_dir_prefix() .. "1/src/foo.lua"))
    assert.are.equal("src/foo.lua", uri.nvim_runtime_staged_suffix(uri.run_dir_prefix() .. "1/src/foo.lua"))
    -- Three segments after the temp prefix but not matching nvim.<user>:
    -- must reject.
    assert.is_false(uri.is_nvim_runtime_staged_path("/var/folders/xx/yy/T/other/aaa/bbb/src.lua"))
    -- Plain /tmp file:
    assert.is_false(uri.is_nvim_runtime_staged_path("/tmp/foo.txt"))
    -- Not a temp path at all:
    assert.is_false(uri.is_nvim_runtime_staged_path("/Users/me/src/repo/file.lua"))
  end)
end)

describe("pjollrig.adapter reverse-map", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("reverse-maps a staged path to the real project file when unique", function()
    -- Create a real file inside tmp_root so the reverse-map has
    -- exactly one candidate under the project root.
    vim.fn.mkdir(tmp_root .. "/.config/cmux", "p")
    vim.fn.writefile({ "hello" }, tmp_root .. "/.config/cmux/settings.json")
    local staged = make_staged_file(".config/cmux/settings.json", { "hello" })

    -- cd into tmp_root so `vim.fs.root(0, ...)` has a chance at the
    -- marker (we also push the project root explicitly via `store`).
    local prev_cwd = vim.uv.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    vim.cmd.edit(vim.fn.fnameescape(staged))
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(err)
    assert.is_truthy(id)
    -- URI anchors to the real file inside the project root, NOT the
    -- staged path.
    local expected = vim.uri_from_fname(vim.fs.normalize(tmp_root .. "/.config/cmux/settings.json"))
    assert.are.equal(expected, id.uri)
    assert.is_true(id.is_writable)
    assert.are.equal("project", id.scope)

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)

  it("rejects when the reverse-map has no on-disk candidate", function()
    -- Stage a file whose suffix does NOT exist anywhere below the
    -- project root / cwd / HOME.
    local staged = make_staged_file("nonexistent/deep/path/does-not-exist.lua", { "x" })
    local prev_cwd = vim.uv.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    vim.cmd.edit(vim.fn.fnameescape(staged))
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(id)
    assert.is_truthy(err)
    assert.is_truthy(err:match("could not map to a real file"))

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)

  it("rejects when the reverse-map is ambiguous", function()
    -- Reverse-map looks at `vim.fs.root(0, …)`, `vim.fn.getcwd()`, and
    -- `$HOME` (dotfile-suffix only). Plant the same suffix under both
    -- cwd AND the sandbox HOME and pick a dotfile suffix so the HOME
    -- fallback engages — that guarantees two distinct candidates.
    vim.fn.mkdir(tmp_root .. "/.config/ambig", "p")
    vim.fn.writefile({ "a" }, tmp_root .. "/.config/ambig/x.txt")
    vim.fn.mkdir(vim.env.HOME .. "/.config/ambig", "p")
    vim.fn.writefile({ "b" }, vim.env.HOME .. "/.config/ambig/x.txt")

    local staged = make_staged_file(".config/ambig/x.txt", { "c" })
    local prev_cwd = vim.uv.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    vim.cmd.edit(vim.fn.fnameescape(staged))
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(id)
    assert.is_truthy(err)
    assert.is_truthy(err:match("ambiguous reverse%-map"))

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)
end)

describe("pjollrig M.add invariant canary", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("refuses to persist when identify is injected to diverge", function()
    local pjollrig = require("pjollrig")
    local store = require("pjollrig.store")
    local adapter_mod = require("pjollrig.adapter")
    vim.cmd.edit(tmp_root .. "/canary.lua")
    local bufnr = vim.api.nvim_get_current_buf()

    -- Drive the whole record build, then swap `identify` at the last
    -- moment so the post-build verification sees a different URI and
    -- the canary fires. (The canary runs inline in M.add, so we patch
    -- after the initial identify call happened.)
    local orig_identify = adapter_mod.identify
    local call = 0
    adapter_mod.identify = function(b)
      call = call + 1
      if call == 1 then
        return orig_identify(b)
      end
      local id = orig_identify(b)
      if id then
        id = vim.deepcopy(id)
        id.uri = "file:///this/is/a/different/uri.lua"
      end
      return id
    end

    local notifications = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, lvl)
      table.insert(notifications, { msg = msg, level = lvl })
    end

    pjollrig.add({ body = "canary", range = { start = { 0, 0 }, end_ = { 0, 0 } } })

    adapter_mod.identify = orig_identify
    vim.notify = orig_notify

    -- No record should have landed.
    local root = store.root()
    if root then
      assert.are.equal(0, #store.all(root))
    end
    assert.are.equal(0, #store.session_all())

    -- An ERROR-level notify with the invariant message should have
    -- fired.
    local matched = false
    for _, n in ipairs(notifications) do
      if type(n.msg) == "string" and n.msg:match("URI invariant violated") then
        matched = true
        break
      end
    end
    assert.is_true(matched)
  end)
end)

describe("pjollrig M.list adapter-routed project root", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("finds the project record when reading from a staged DiffToolGit-style buffer", function()
    -- Reproduces the `:PjollrigSend claude-cmux` bug: a comment added
    -- from a staged buffer lands in the real project store (via
    -- adapter.identify's reverse-map), but the read path in `M.list`
    -- used raw `store.root()` which walks up the staged path under
    -- `stdpath('run')` and never finds a marker — making the record
    -- invisible. Requires `M.list` (and every other read site in
    -- init.lua that resolves "project root for the current buffer")
    -- to route through `adapter.identify` first.
    local pjollrig = require("pjollrig")
    local store = require("pjollrig.store")

    -- Plant a real project file at the mapped location so the
    -- reverse-map has exactly one candidate.
    vim.fn.mkdir(tmp_root .. "/src", "p")
    vim.fn.writefile({ "real contents" }, tmp_root .. "/src/feature.lua")

    local staged = make_staged_file("src/feature.lua", { "real contents" })
    local prev_cwd = vim.uv.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    -- Open the staged path. From the plugin's perspective the current
    -- buffer sits under `stdpath('run')` — the DiffToolGit scenario.
    vim.cmd.edit(vim.fn.fnameescape(staged))
    local staged_bufnr = vim.api.nvim_get_current_buf()

    -- Sanity-check the adapter already reverse-maps to the real file
    -- under the real project root. This is the baseline the fix
    -- relies on (writes are known-good).
    local adapter_mod = require("pjollrig.adapter")
    local identity = adapter_mod.identify(staged_bufnr)
    assert.is_truthy(identity)
    assert.are.equal("project", identity.scope)
    assert.are.equal(vim.fs.normalize(tmp_root), vim.fs.normalize(identity.project_root))

    -- Add a comment FROM the staged buffer. The add path already
    -- routes through `adapter.identify`, so this record should land in
    -- the real project store keyed at `tmp_root`.
    pjollrig.add({ body = "routed via adapter", range = { start = { 0, 0 }, end_ = { 0, 0 } } })

    -- Confirm the project store actually owns the record (if this
    -- assertion fails, the fix isn't what's being exercised — the
    -- bug would be on the write side instead).
    local project_records = store.all(vim.fs.normalize(identity.project_root))
    assert.are.equal(1, #project_records)

    -- Stay on the staged buffer. The user's scenario is
    -- `:PjollrigSend claude-cmux` from *inside* the DiffToolGit view.
    assert.are.equal(staged_bufnr, vim.api.nvim_get_current_buf())

    -- The bug: `M.list()` previously called raw `store.root()` on the
    -- staged buffer, walked up to a dead end, and returned 0 records.
    -- With the fix it routes through `adapter.identify` and sees the
    -- project record.
    local results = pjollrig.list()
    assert.are.equal(1, #results)
    assert.are.equal("routed via adapter", results[1].body)

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)
end)
