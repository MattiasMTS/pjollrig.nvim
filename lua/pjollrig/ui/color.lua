-- pjollrig.nvim: pure color/format helpers shared by the UI surfaces.
--
-- Home of the palette math (`blend`) and the card timestamp label
-- (`relative_time`). Both are pure functions with no vim state beyond
-- `os.time`/`os.date`, extracted from `ui/render.lua` so they can be
-- consumed without pulling in the renderer.

local M = {}

---Per-channel linear mix of two 24-bit RGB colors: returns `a` moved
---toward `b` by `t` — `t = 0` yields `a` unchanged, `t = 1` yields `b`,
---`0.5` the rounded midpoint. Pure; exported so the palette formulas in
---the renderer's `setup_comment_highlights` are unit-testable.
---@param a integer 24-bit RGB color (0xRRGGBB)
---@param b integer 24-bit RGB color (0xRRGGBB)
---@param t number Mix fraction in [0, 1]
---@return integer
function M.blend(a, b, t)
  local function mix(shift)
    local ca = math.floor(a / shift) % 0x100
    local cb = math.floor(b / shift) % 0x100
    return math.floor(ca + (cb - ca) * t + 0.5)
  end
  return mix(0x10000) * 0x10000 + mix(0x100) * 0x100 + mix(1)
end

--- Relative-time label for the card's author line. Pure — `now` is
--- injectable so tests can run against a fixed clock. Boundaries: under
--- a minute (including future timestamps from clock skew) → "just now";
--- under an hour → "Nm ago"; under a day → "Nh ago"; up to 30 days →
--- "Nd ago"; older → the absolute "%b %d %H:%M" date the old footer
--- used.
---@param ts number Epoch seconds of the record's timestamp
---@param now? number Epoch seconds to measure from (default `os.time()`)
---@return string
function M.relative_time(ts, now)
  local diff = (now or os.time()) - ts
  if diff < 60 then
    return "just now"
  end
  if diff < 3600 then
    return ("%dm ago"):format(math.floor(diff / 60))
  end
  if diff < 86400 then
    return ("%dh ago"):format(math.floor(diff / 3600))
  end
  if diff <= 30 * 86400 then
    return ("%dd ago"):format(math.floor(diff / 86400))
  end
  return os.date("%b %d %H:%M", ts) --[[@as string]]
end

return M
