-- pjollrig.nvim: builtin review-panel tab loader.
--
-- Registers the bundled panel tabs (see panel.register_tab) the way
-- sinks/init.lua registers the bundled sinks. The panel calls setup()
-- on every open; the `done` guard makes that idempotent, so tab
-- modules never see a duplicate-name registration error.

local M = {}

-- The builtin tab modules. They ship separately and may be absent
-- (older releases, partial checkouts): pcall-require tolerates a
-- missing module silently, so the panel works with whatever subset
-- exists.
local MODULES = {
  "pjollrig.review.tabs.github",
  "pjollrig.review.tabs.checks",
}

local done = false

---Load and register the builtin tabs. Idempotent per Neovim session.
function M.setup()
  if done then
    return
  end
  done = true
  for _, name in ipairs(MODULES) do
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" and type(mod.setup) == "function" then
      mod.setup()
    end
  end
end

---Internal: exposed for tests — allow setup() to run again.
function M._reset()
  done = false
end

return M
