-- pjollrig.nvim: optional icon provider adapter.
--
-- Neither mini.icons nor nvim-web-devicons is a dependency: both are
-- probed lazily via pcall(require, ...) on first use and the result is
-- cached. `ui.icons` controls behavior: "auto" (default) turns icons
-- on iff a provider is loadable, `true` forces them on (Nerd Font
-- badges work without a provider; filetype icons still need one), and
-- `false` turns everything off.

local M = {}

---Resolved provider cache. nil = not probed yet, false = probed and
---none found, table = { kind, mod }.
---@type {kind: "mini"|"devicons", mod: table}|false|nil
local provider = nil

---Cached `enabled()` verdict. `ui.icons` only changes via
---`config.setup`, so one computation serves until `_reset()`.
---@type boolean?
local enabled_cache = nil

---Per-path memo for `file_icon` — the review panel asks for the same
---paths on every render. Only successful lookups are stored so an
---erroring provider (e.g. mini.icons before its setup()) is retried on
---the next call. Cleared by `_reset()`.
---@type table<string, {[1]: string, [2]: string|nil}>
local icon_cache = {}

---Probe for an icon provider, mini.icons preferred.
---@return {kind: "mini"|"devicons", mod: table}|nil
local function resolve_provider()
  if provider ~= nil then
    return provider or nil
  end
  local ok, mini = pcall(require, "mini.icons")
  if ok and type(mini) == "table" and type(mini.get) == "function" then
    provider = { kind = "mini", mod = mini }
    return provider
  end
  local ok_dev, devicons = pcall(require, "nvim-web-devicons")
  if ok_dev and type(devicons) == "table" and type(devicons.get_icon) == "function" then
    provider = { kind = "devicons", mod = devicons }
    return provider
  end
  provider = false
  return nil
end

---Whether icons should render, per `ui.icons`:
---  "auto"  -> true iff a provider is loadable
---  true    -> always (user vouches for their font's glyphs)
---  false   -> never
---@return boolean
function M.enabled()
  if enabled_cache ~= nil then
    return enabled_cache
  end
  local icons = require("pjollrig.config").get().ui.icons
  if icons == true then
    enabled_cache = true
  elseif icons == false then
    enabled_cache = false
  else
    enabled_cache = resolve_provider() ~= nil
  end
  return enabled_cache
end

---Filetype icon + suggested highlight group for a path, from whichever
---provider is loadable. Returns nils when icons are disabled, no
---provider is loadable, or the provider errors (e.g. mini.icons before
---its setup()).
---@param path string
---@return string|nil icon
---@return string|nil hl
function M.file_icon(path)
  if not M.enabled() then
    return nil, nil
  end
  local cached = icon_cache[path]
  if cached then
    return cached[1], cached[2]
  end
  local p = resolve_provider()
  if not p then
    return nil, nil
  end
  local ok, icon, hl
  if p.kind == "mini" then
    -- MiniIcons.get("file", path) -> icon, hl, is_default. Errors when
    -- called before MiniIcons.setup(), hence the pcall.
    ok, icon, hl = pcall(p.mod.get, "file", path)
  else
    local name = vim.fn.fnamemodify(path, ":t")
    local ext = vim.fn.fnamemodify(path, ":e")
    ok, icon, hl = pcall(p.mod.get_icon, name, ext, { default = true })
  end
  if not ok or type(icon) ~= "string" or icon == "" then
    return nil, nil
  end
  local hl_group = type(hl) == "string" and hl or nil
  icon_cache[path] = { icon, hl_group }
  return icon, hl_group
end

---Badge glyphs per kind: a Nerd Font `glyph` used when icons are
---enabled and a plain `ascii` fallback otherwise. Exported so other
---renderers reuse the same set.
---@type table<string, {glyph: string, ascii: string}>
M.badges = {
  github = { glyph = "\u{F09B}", ascii = "[gh]" }, -- nf-fa-github
  ["local"] = { glyph = "\u{F0B79}", ascii = "\u{25CF}" }, -- nf-md-chat / ●
  resolved = { glyph = "\u{F00C}", ascii = "\u{2713}" }, -- nf-fa-check / ✓
}

---Badge for a comment kind. ALWAYS a string (empty for unknown kinds)
---so callers can concatenate without nil checks.
---@param kind "github"|"local"|"resolved"
---@return string
function M.badge(kind)
  local badge = M.badges[kind]
  if not badge then
    return ""
  end
  return M.enabled() and badge.glyph or badge.ascii
end

---Test seam: forget the resolved provider, the cached `enabled()`
---verdict, and the per-path icon memo so the next calls recompute.
function M._reset()
  provider = nil
  enabled_cache = nil
  icon_cache = {}
end

return M
