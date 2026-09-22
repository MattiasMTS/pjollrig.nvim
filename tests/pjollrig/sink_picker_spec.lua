-- Exercises no-arg :PjollrigSend sink selection. The default path uses
-- the floating picker, while users can override ui.sink_picker for Snacks,
-- Telescope, fzf-lua, or any other picker.

local tmp_state

local function setup_env(opts)
  tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  require("pjollrig.store")._reset()
  require("pjollrig.sinks")._reset()

  local base = {
    store = {
      dir = tmp_state .. "/",
      format = "json",
      canonicalize_symlinks = false,
      poll_interval_ms = 0,
    },
    sinks = {
      clipboard = false,
      cmux = false,
      socket = false,
    },
  }
  require("pjollrig").setup(vim.tbl_deep_extend("force", base, opts or {}))
end

local function teardown_env()
  require("pjollrig.store")._reset()
  require("pjollrig.sinks")._reset()
  pcall(vim.fn.delete, tmp_state, "rf")
end

local function register_sink(name, seen)
  require("pjollrig").register_sink({
    name = name,
    label = "Agent " .. name,
    description = "sink " .. name,
    send = function(comments, ctx, cb)
      table.insert(seen, { name = name, count = #comments, ctx = ctx })
      cb(true)
    end,
  })
end

describe("pjollrig sink picker", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("select_sink returns the only sink without opening a picker", function()
    local seen = {}
    register_sink("only", seen)

    local picked
    local orig_select = require("pjollrig.ui.select").select
    require("pjollrig.ui.select").select = function()
      error("the floating picker should not be called for a single sink")
    end
    require("pjollrig.ui").select_sink(function(name)
      picked = name
    end)
    require("pjollrig.ui.select").select = orig_select

    assert.are.equal("only", picked)
  end)

  it("select_sink opens the floating picker when multiple sinks exist", function()
    local seen = {}
    register_sink("alpha", seen)
    register_sink("beta", seen)

    local captured_items
    local captured_opts
    local picked
    local orig_select = require("pjollrig.ui.select").select
    require("pjollrig.ui.select").select = function(items, opts, cb)
      captured_items = items
      captured_opts = opts
      cb(items[2])
    end
    require("pjollrig.ui").select_sink(function(name)
      picked = name
    end)
    require("pjollrig.ui.select").select = orig_select

    assert.are.equal("beta", picked)
    assert.are.equal(2, #captured_items)
    assert.are.equal("alpha", captured_items[1].name)
    assert.are.equal("beta", captured_items[2].name)
    assert.are.equal("Agent alpha - sink alpha", captured_opts.format_item(captured_items[1]))
  end)

  it("select_sink delegates to ui.sink_picker when configured", function()
    teardown_env()
    local picker_called = false
    setup_env({
      ui = {
        sink_picker = function(choices, opts, cb)
          picker_called = true
          assert.are.equal("Pjollrig: send to", opts.prompt)
          cb(choices[1].name)
        end,
      },
    })
    local seen = {}
    register_sink("alpha", seen)
    register_sink("beta", seen)

    local picked
    local orig_select = require("pjollrig.ui.select").select
    require("pjollrig.ui.select").select = function()
      error("the floating picker should not be called when ui.sink_picker is set")
    end
    require("pjollrig.ui").select_sink(function(name)
      picked = name
    end)
    require("pjollrig.ui.select").select = orig_select

    assert.is_true(picker_called)
    assert.are.equal("alpha", picked)
  end)

  it("send with no sink dispatches to the selected sink", function()
    teardown_env()
    setup_env({
      ui = {
        sink_picker = function(choices, _opts, cb)
          cb(choices[2])
        end,
      },
    })
    local seen = {}
    register_sink("alpha", seen)
    register_sink("beta", seen)

    require("pjollrig").send(nil, nil, { marker = "ctx" })

    assert.are.equal(1, #seen)
    assert.are.equal("beta", seen[1].name)
    assert.are.equal(0, seen[1].count)
    assert.are.equal("ctx", seen[1].ctx.marker)
  end)

  it("select_sink warns when there are no sinks", function()
    local notified
    local picked = "unset"
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    require("pjollrig.ui").select_sink(function(name)
      picked = name
    end)
    vim.notify = orig_notify

    assert.is_nil(picked)
    assert.is_truthy(notified)
    assert.are.equal(vim.log.levels.WARN, notified.level)
    assert.is_truthy(notified.msg:find("no sinks registered"))
  end)
end)
