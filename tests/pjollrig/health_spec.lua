local H = require("helpers")

local ctx

local function setup_env()
  ctx = H.setup({
    sinks = {
      clipboard = true,
      cmux = false,
    },
  })
  H.edit_project_file(ctx, "src/health.lua", {
    "return true",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

describe("pjollrig health", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("reports runtime, store, and sink diagnostics", function()
    local snapshot = require("pjollrig.health")._collect()

    assert.is_true(snapshot.nvim.has_required)
    assert.is_true(snapshot.nvim.has_vim_system)
    assert.is_true(snapshot.nvim.has_vim_fs_root)
    assert.is_true(snapshot.nvim.has_mpack)

    assert.are.equal(ctx.state .. "/", snapshot.store.dir)
    assert.is_true(snapshot.store.exists)
    assert.is_true(snapshot.store.writable)
    assert.are.equal("json", snapshot.store.format)
    assert.are.equal(0, snapshot.store.poll_interval_ms)
    assert.is_true(snapshot.store.sqlite_available)
    assert.are.equal(require("pjollrig.store").schema_version(), snapshot.store.schema_version)
    assert.are.equal(ctx.root, snapshot.store.current_root)

    assert.is_true(snapshot.sinks.clipboard_registered)
    assert.is_false(snapshot.sinks.cmux_registered)
  end)

  it("runs the checkhealth entrypoint", function()
    local ok, err = pcall(require("pjollrig.health").check)
    assert.is_true(ok, err)
  end)
end)
