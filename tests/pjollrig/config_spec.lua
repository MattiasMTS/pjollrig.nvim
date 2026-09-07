local H = require("helpers")

local ctx

describe("pjollrig config key renames", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("keeps the pre-rename default store so existing comments remain available", function()
    local cfg = require("pjollrig.config").setup({})
    assert.are.equal(vim.fn.stdpath("state") .. "/manicule/", cfg.store.dir)
  end)

  -- Old-name -> new-name pairs. Pre-release breaking renames: no aliases,
  -- but setup() must fail LOUDLY (naming both keys) instead of silently
  -- ignoring the old key.
  local renamed = {
    { opts = { review = { mode = "split" } }, old = "review.mode", new = "review.diff_mode" },
    { opts = { review = { prefetch = true } }, old = "review.prefetch", new = "review.panel.prefetch" },
    { opts = { ui = { display = "eol" } }, old = "ui.display", new = "ui.display_mode" },
    { opts = { ui = { expand = "float" } }, old = "ui.expand", new = "ui.eol_expand" },
    { opts = { ui = { sticky = true } }, old = "ui.sticky", new = "ui.always_show_popups" },
    { opts = { store = { branch = true } }, old = "store.branch", new = "store.scope_by_branch" },
    { opts = { ui = { width = 60 } }, old = "ui.width", new = "ui.editor.width" },
    { opts = { ui = { height = 5 } }, old = "ui.height", new = "ui.editor.height" },
    { opts = { ui = { editor_mode = "insert" } }, old = "ui.editor_mode", new = "ui.editor.start_mode" },
    { opts = { ui = { submit_keys = { "<CR>" } } }, old = "ui.submit_keys", new = "ui.editor.submit_keys" },
    { opts = { ui = { cancel_keys = { "q" } } }, old = "ui.cancel_keys", new = "ui.editor.cancel_keys" },
  }

  it("errors loudly when a renamed key is passed under its old name", function()
    local config = require("pjollrig.config")
    for _, case in ipairs(renamed) do
      local ok, err = pcall(config.setup, case.opts)
      assert.is_false(ok, case.old .. " should be rejected")
      assert.is_truthy(
        tostring(err):find(("%s was renamed to %s"):format(case.old, case.new), 1, true),
        ("%s: %s"):format(case.old, tostring(err))
      )
    end
  end)

  it("accepts and merges the new key names", function()
    local config = require("pjollrig.config")
    local cfg = config.setup({
      store = { dir = ctx.state .. "/", scope_by_branch = true },
      review = { diff_mode = "unified", panel = { prefetch = false } },
      ui = {
        display_mode = "float",
        eol_expand = "rail",
        always_show_popups = true,
        editor = {
          width = 60,
          height = 4,
          start_mode = "normal",
          submit_keys = { "<C-g>" },
          cancel_keys = { "<Esc>" },
        },
      },
    })
    assert.is_true(cfg.store.scope_by_branch)
    assert.are.equal("unified", cfg.review.diff_mode)
    assert.is_false(cfg.review.panel.prefetch)
    assert.are.equal("float", cfg.ui.display_mode)
    assert.are.equal("rail", cfg.ui.eol_expand)
    assert.is_true(cfg.ui.always_show_popups)
    assert.are.equal(60, cfg.ui.editor.width)
    assert.are.equal(4, cfg.ui.editor.height)
    assert.are.equal("normal", cfg.ui.editor.start_mode)
    assert.are.same({ "<C-g>" }, cfg.ui.editor.submit_keys)
    assert.are.same({ "<Esc>" }, cfg.ui.editor.cancel_keys)
  end)

  it("validates the new keys' values under their new names", function()
    local config = require("pjollrig.config")
    local cases = {
      { opts = { review = { diff_mode = "sideways" } }, needle = "review.diff_mode" },
      { opts = { ui = { display_mode = "sideways" } }, needle = "ui.display_mode" },
      { opts = { ui = { eol_expand = "sideways" } }, needle = "ui.eol_expand" },
      { opts = { ui = { always_show_popups = "yes" } }, needle = "ui.always_show_popups" },
      { opts = { store = { scope_by_branch = "yes" } }, needle = "store.scope_by_branch" },
      { opts = { ui = { editor = { width = "wide" } } }, needle = "ui.editor.width" },
      { opts = { ui = { editor = { start_mode = 42 } } }, needle = "ui.editor.start_mode" },
    }
    for _, case in ipairs(cases) do
      local ok, err = pcall(config.setup, case.opts)
      assert.is_false(ok, case.needle .. " should be rejected")
      assert.is_truthy(tostring(err):find(case.needle, 1, true), tostring(err))
    end
  end)

  it("get() returns the live merged table — the runtime-override channel", function()
    local config = require("pjollrig.config")
    assert.are.equal("split", config.get().review.diff_mode)
    -- review.set_diff_mode writes here at runtime; the mutation must be
    -- visible to every later get() (same table, not a copy).
    config.get().review.diff_mode = "unified"
    assert.are.equal("unified", config.get().review.diff_mode)
  end)
end)
