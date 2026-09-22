local H = require("helpers")

local ctx

---Stub an icon provider module via package.preload so `require` finds
---it without the real plugin being installed. Cleared in teardown.
local function stub_mini_icons(icon, hl)
  package.preload["mini.icons"] = function()
    return {
      get = function(_category, _name)
        return icon or "M", hl or "MiniIconsAzure", false
      end,
    }
  end
end

local function stub_devicons(icon, hl)
  package.preload["nvim-web-devicons"] = function()
    return {
      get_icon = function(_name, _ext, _opts)
        return icon or "D", hl or "DevIconLua"
      end,
    }
  end
end

local function clear_provider_stubs()
  package.preload["mini.icons"] = nil
  package.loaded["mini.icons"] = nil
  package.preload["nvim-web-devicons"] = nil
  package.loaded["nvim-web-devicons"] = nil
end

local function icons()
  return require("pjollrig.ui.icons")
end

---Set ui.icons on the live merged config (H.setup already ran a full
---pjollrig setup; tests only need to vary this one knob per case).
local function set_icons_config(value)
  require("pjollrig.config").get().ui.icons = value
end

describe("pjollrig ui icons", function()
  before_each(function()
    clear_provider_stubs()
    ctx = H.setup()
    icons()._reset()
  end)

  after_each(function()
    clear_provider_stubs()
    pcall(function()
      icons()._reset()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("defaults ui.icons to auto", function()
    assert.are.equal("auto", require("pjollrig.config").get().ui.icons)
  end)

  describe("enabled()", function()
    it("is true for auto when a provider is loadable", function()
      set_icons_config("auto")
      stub_mini_icons()
      assert.is_true(icons().enabled())
    end)

    it("is false for auto when no provider is loadable", function()
      set_icons_config("auto")
      assert.is_false(icons().enabled())
    end)

    it("is true when forced true even without a provider", function()
      set_icons_config(true)
      assert.is_true(icons().enabled())
    end)

    it("is false when forced false even with a provider", function()
      set_icons_config(false)
      stub_mini_icons()
      assert.is_false(icons().enabled())
    end)
  end)

  describe("file_icon()", function()
    it("prefers mini.icons over nvim-web-devicons", function()
      set_icons_config("auto")
      stub_mini_icons("\u{E620}", "MiniIconsAzure")
      stub_devicons("\u{E7A0}", "DevIconLua")
      local icon, hl = icons().file_icon("foo.lua")
      assert.are.equal("\u{E620}", icon)
      assert.are.equal("MiniIconsAzure", hl)
    end)

    it("falls back to nvim-web-devicons when mini.icons is absent", function()
      set_icons_config("auto")
      stub_devicons("\u{E7A0}", "DevIconLua")
      local icon, hl = icons().file_icon("foo.lua")
      assert.are.equal("\u{E7A0}", icon)
      assert.are.equal("DevIconLua", hl)
    end)

    it("returns nil when icons are disabled", function()
      set_icons_config(false)
      stub_mini_icons()
      local icon, hl = icons().file_icon("foo.lua")
      assert.is_nil(icon)
      assert.is_nil(hl)
    end)

    it("returns nil when enabled but no provider is loadable", function()
      set_icons_config(true)
      local icon, hl = icons().file_icon("foo.lua")
      assert.is_nil(icon)
      assert.is_nil(hl)
    end)

    it("tolerates a provider whose get() errors", function()
      set_icons_config("auto")
      package.preload["mini.icons"] = function()
        return {
          get = function()
            error("mini.icons not set up")
          end,
        }
      end
      local icon, hl = icons().file_icon("foo.lua")
      assert.is_nil(icon)
      assert.is_nil(hl)
    end)
  end)

  describe("badge()", function()
    it("returns Nerd Font glyphs when enabled", function()
      set_icons_config(true)
      assert.are.equal("\u{F09B}", icons().badge("github"))
      assert.are.equal("\u{F0B79}", icons().badge("local"))
      assert.are.equal("\u{F00C}", icons().badge("resolved"))
    end)

    it("returns ASCII fallbacks when disabled", function()
      set_icons_config(false)
      assert.are.equal("[gh]", icons().badge("github"))
      assert.are.equal("\u{25CF}", icons().badge("local"))
      assert.are.equal("\u{2713}", icons().badge("resolved"))
    end)

    it("always returns a string, even for unknown kinds", function()
      set_icons_config(true)
      assert.are.equal("string", type(icons().badge("bogus")))
      set_icons_config(false)
      assert.are.equal("string", type(icons().badge("bogus")))
    end)

    it("exports the badges table for reuse", function()
      local badges = icons().badges
      assert.are.equal("table", type(badges))
      for _, kind in ipairs({ "github", "local", "resolved" }) do
        assert.are.equal("table", type(badges[kind]), kind)
        assert.are.equal("string", type(badges[kind].glyph), kind .. ".glyph")
        assert.are.equal("string", type(badges[kind].ascii), kind .. ".ascii")
      end
    end)
  end)

  describe("memoization", function()
    ---Stub mini.icons with a call counter so tests can assert how often
    ---the provider is actually consulted.
    local function stub_counting_mini_icons()
      local calls = { n = 0 }
      package.preload["mini.icons"] = function()
        return {
          get = function(_category, _name)
            calls.n = calls.n + 1
            return "Z", "MiniIconsAzure", false
          end,
        }
      end
      return calls
    end

    it("memoizes file_icon per path", function()
      set_icons_config("auto")
      local calls = stub_counting_mini_icons()
      local icon1, hl1 = icons().file_icon("foo.lua")
      local icon2, hl2 = icons().file_icon("foo.lua")
      assert.are.equal("Z", icon1)
      assert.are.equal("MiniIconsAzure", hl1)
      assert.are.equal(icon1, icon2)
      assert.are.equal(hl1, hl2)
      assert.are.equal(1, calls.n)
      -- A different path is a different memo slot.
      icons().file_icon("bar.lua")
      assert.are.equal(2, calls.n)
    end)

    it("_reset clears the file_icon memo", function()
      set_icons_config("auto")
      local calls = stub_counting_mini_icons()
      icons().file_icon("foo.lua")
      icons().file_icon("foo.lua")
      assert.are.equal(1, calls.n)
      icons()._reset()
      icons().file_icon("foo.lua")
      assert.are.equal(2, calls.n)
    end)

    it("does not memoize provider errors", function()
      set_icons_config("auto")
      local calls = { n = 0 }
      package.preload["mini.icons"] = function()
        return {
          get = function()
            calls.n = calls.n + 1
            if calls.n == 1 then
              error("mini.icons not set up")
            end
            return "Y", "MiniIconsAzure", false
          end,
        }
      end
      -- First call errors -> nil, and the failure is NOT cached: the
      -- provider may succeed later (mini.icons after its setup()).
      assert.is_nil(icons().file_icon("foo.lua"))
      assert.are.equal("Y", icons().file_icon("foo.lua"))
      -- Now memoized.
      icons().file_icon("foo.lua")
      assert.are.equal(2, calls.n)
    end)

    it("caches the enabled() verdict until _reset", function()
      set_icons_config(true)
      assert.is_true(icons().enabled())
      -- ui.icons only changes via config.setup; flipping it under a live
      -- session needs a _reset (the test seam) to be observed.
      set_icons_config(false)
      assert.is_true(icons().enabled())
      icons()._reset()
      assert.is_false(icons().enabled())
    end)
  end)

  describe("_reset()", function()
    it("clears the cached provider so a newly loadable one is picked up", function()
      set_icons_config("auto")
      assert.is_false(icons().enabled())
      stub_mini_icons()
      -- Cache still says "no provider" until reset.
      assert.is_false(icons().enabled())
      icons()._reset()
      assert.is_true(icons().enabled())
    end)
  end)

  describe("config validation", function()
    it("rejects a garbage string", function()
      local ok, err = pcall(require("pjollrig.config").setup, { ui = { icons = "sometimes" } })
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("ui.icons", 1, true))
      assert.is_truthy(tostring(err):find('"auto"', 1, true))
    end)

    it("rejects a non boolean/string value", function()
      local ok, err = pcall(require("pjollrig.config").setup, { ui = { icons = 42 } })
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("ui.icons", 1, true))
    end)

    it("accepts auto, true, and false", function()
      for _, value in ipairs({ "auto", true, false }) do
        local merged = require("pjollrig.config").setup({
          store = { dir = ctx.state .. "/" },
          ui = { icons = value },
        })
        assert.are.equal(value, merged.ui.icons)
      end
    end)
  end)
end)
