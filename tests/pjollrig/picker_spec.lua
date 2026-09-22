-- Headless exercise of the positional-number picker path. Runs each of
-- the self-check scenarios enumerated in the spec so regressions show
-- up as a busted failure instead of requiring manual repro.

local tmp_state
local tmp_root

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  -- Isolate the per-project store to a tempdir and open a buffer inside
  -- the fake root so `store.root()` resolves predictably.
  require("pjollrig.store")._reset()
  -- Force `runtime plugin/pjollrig.lua` to re-source per test so the
  -- plugin's completion cache starts fresh.
  vim.g.loaded_pjollrig = nil
  require("pjollrig").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      -- The test builds synthetic records against `tmp_root`; disable
      -- symlink canonicalisation so the URIs we build here match what
      -- the plugin resolves for the currently-open buffer without
      -- racing `fs_realpath` through the `/private/...` symlink macOS
      -- inserts in `$TMPDIR`.
      canonicalize_symlinks = false,
      poll_interval_ms = 0,
    },
  })
  vim.cmd.edit(tmp_root .. "/a.lua")
end

local function teardown_env()
  require("pjollrig.store")._reset()
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
end

local function add(body, line, relpath)
  local store = require("pjollrig.store")
  local root = store.root()
  assert.is_truthy(root)
  local id = require("pjollrig.id").new()
  local uri = require("pjollrig.uri").for_path(root .. "/" .. relpath)
  store.put(root, {
    id = id,
    uri = uri,
    scope = "project",
    project_root = root,
    range = { start = { line - 1, 0 }, end_ = { line - 1, 0 } },
    body = body,
    author = "t@example.com",
    created_at = 0,
    updated_at = 0,
    resolved = false,
    meta = {},
  })
  store.save(root)
  return id
end

describe("pjollrig positional picker", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("completion returns 1..N as strings", function()
    add("one", 1, "a.lua")
    add("two", 2, "a.lua")
    add("three", 3, "a.lua")
    -- Trigger plugin/pjollrig.lua (not loaded in --noplugin mode).
    vim.cmd("runtime plugin/pjollrig.lua")
    local cmd = vim.api.nvim_get_commands({})["PjollrigDelete"]
    assert.is_truthy(cmd)
    assert.are.same({ "1", "2", "3" }, vim.fn.getcompletion("PjollrigDelete ", "cmdline"))
  end)

  it("completion prefix-filters positions by arglead", function()
    for i = 1, 12 do
      add("note " .. i, i, "a.lua")
    end
    vim.cmd("runtime plugin/pjollrig.lua")
    assert.are.same({ "1", "10", "11", "12" }, vim.fn.getcompletion("PjollrigDelete 1", "cmdline"))
    assert.are.same({ "3" }, vim.fn.getcompletion("PjollrigEdit 3", "cmdline"))
  end)

  it("completion caches positions so repeated <Tab> does not re-query the store", function()
    add("one", 1, "a.lua")
    vim.cmd("runtime plugin/pjollrig.lua")

    local pjollrig = require("pjollrig")
    local orig_list = pjollrig.list
    local calls = 0
    pjollrig.list = function(...)
      calls = calls + 1
      return orig_list(...)
    end
    local first = vim.fn.getcompletion("PjollrigDelete ", "cmdline")
    local second = vim.fn.getcompletion("PjollrigDelete ", "cmdline")
    pjollrig.list = orig_list

    assert.are.same({ "1" }, first)
    assert.are.same({ "1" }, second)
    assert.are.equal(1, calls)
  end)

  it(":PjollrigDelete <n> removes the positional record", function()
    local id1 = add("first", 1, "a.lua")
    add("second", 2, "a.lua")
    local id3 = add("third", 3, "a.lua")
    vim.cmd("runtime plugin/pjollrig.lua")
    vim.cmd("PjollrigDelete 2")
    local remaining = require("pjollrig").list()
    assert.are.equal(2, #remaining)
    assert.are.equal(id1, remaining[1].id)
    assert.are.equal(id3, remaining[2].id)
  end)

  it(":PjollrigDelete with no arg opens the floating picker with formatted items", function()
    add("short", 1, "README.md")
    add("a much longer body that should be truncated to a fixed maximum width", 10, "src/aaaa/bbbb/cccc/dddd.lua")
    local resolved_id = add("already done", 5, "src/zzz.lua")
    local records_pre = require("pjollrig").list()
    local store = require("pjollrig.store")
    for _, r in ipairs(records_pre) do
      if r.id == resolved_id then
        r.resolved = true
        store.put(store.root(), r)
      end
    end

    local captured_items
    local captured_opts
    local orig = require("pjollrig.ui.select").select
    require("pjollrig.ui.select").select = function(items, opts, _cb)
      captured_items = items
      captured_opts = opts
    end
    vim.cmd("runtime plugin/pjollrig.lua")
    vim.cmd("PjollrigDelete")
    require("pjollrig.ui.select").select = orig

    assert.is_truthy(captured_items)
    local records = require("pjollrig").list()
    assert.are.equal(#records, #captured_items)
    for i, item in ipairs(captured_items) do
      assert.are.equal(records[i].id, item.record.id)
      assert.is_truthy(item.display:find(" │ "))
      -- Resolved records must carry the [✓] prefix on the body column.
      if item.record.resolved then
        assert.is_truthy(item.display:find("%[✓%]"))
      end
    end
    -- Sanity-check index padding: 3 records → width 1 → "1", "2", "3".
    assert.is_truthy(captured_items[1].display:match("^1 │ "))
    -- format_item returns the display string verbatim.
    assert.are.equal(captured_items[1].display, captured_opts.format_item(captured_items[1]))
  end)

  it(":PjollrigDelete out-of-range errors and deletes nothing", function()
    add("one", 1, "a.lua")
    add("two", 2, "a.lua")
    add("three", 3, "a.lua")
    vim.cmd("runtime plugin/pjollrig.lua")

    local notified
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    vim.cmd("PjollrigDelete 99")
    vim.notify = orig

    assert.is_truthy(notified)
    assert.are.equal(vim.log.levels.ERROR, notified.level)
    assert.is_truthy(notified.msg:find("no comment at position"))
    assert.are.equal(3, #require("pjollrig").list())
  end)

  it("empty list → INFO notify, no picker", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local notified
    local picker_called = false
    local orig_notify = vim.notify
    local orig_select = require("pjollrig.ui.select").select
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    require("pjollrig.ui.select").select = function()
      picker_called = true
    end
    vim.cmd("PjollrigDelete")
    vim.notify = orig_notify
    require("pjollrig.ui.select").select = orig_select

    assert.is_false(picker_called)
    assert.is_truthy(notified)
    assert.are.equal(vim.log.levels.INFO, notified.level)
    assert.is_truthy(notified.msg:find("no comments"))
  end)

  it("list() orders records by uri → line → id", function()
    add("b-first", 5, "b.lua")
    add("a-second", 10, "a.lua")
    add("a-first", 3, "a.lua")
    -- a.lua records come before b.lua (URI order reflects the
    -- filesystem path order), and within a file lines sort ascending.
    local ordered = require("pjollrig").list()
    local function ends_with(uri, suffix)
      return uri:sub(-#suffix) == suffix
    end
    assert.is_true(ends_with(ordered[1].uri, "/a.lua"))
    assert.is_true(ends_with(ordered[2].uri, "/a.lua"))
    assert.is_true(ends_with(ordered[3].uri, "/b.lua"))
    assert.are.equal("a-first", ordered[1].body)
    assert.are.equal("a-second", ordered[2].body)
  end)
end)
