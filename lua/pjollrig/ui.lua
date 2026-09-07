-- pjollrig.nvim: picker-agnostic UI glue.
--
-- `M.prompt` now delegates to the floating editor at
-- `lua/pjollrig/ui/editor.lua`. That gives
-- multi-line markdown-flavoured editing with user-configurable submit /
-- cancel keys instead of the single-line `vim.ui.input` we used in v0.
--
-- `M.select_sink` auto-sends when there is a single sink and opens a
-- configurable picker when multiple sinks are registered. The default
-- picker is `vim.ui.select`, so dressing.nvim / snacks.nvim / fzf-lua /
-- telescope-ui-select continue to work out of the box.

local M = {}

---@class pjollrig.SinkChoice
---@field name string Registered sink name
---@field label string Human-friendly label
---@field description string? Optional description from the sink spec
---@field display string Rendered picker label
---@field sink table Raw sink spec

---Open the floating comment editor and invoke `cb` with the body
---(or `nil` on cancel).
---@param opts { prompt?: string, default?: string, anchor_pos?: integer[], anchor_winid?: integer }|nil
---@param cb fun(body: string|nil)
function M.prompt(opts, cb)
  opts = opts or {}
  local cfg = require("pjollrig.config").get().ui
  require("pjollrig.ui.editor").open({
    title = opts.prompt or "Comment",
    default = opts.default or "",
    anchor_winid = opts.anchor_winid,
    anchor_pos = opts.anchor_pos,
    cfg = cfg,
  }, cb)
end

---Prompt for a registered sink name.
---@param cb fun(name: string|nil)
function M.select_sink(cb)
  local sinks = require("pjollrig.sinks")
  local names = sinks.list()
  if #names == 0 then
    vim.notify("pjollrig: no sinks registered", vim.log.levels.WARN)
    cb(nil)
    return
  end
  if #names == 1 then
    cb(names[1])
    return
  end

  local choices = {}
  for _, name in ipairs(names) do
    local sink = sinks.get(name) or {}
    local label = sink.label or sink.display_name or name
    local description = sink.description
    local display = label
    if type(description) == "string" and description ~= "" then
      display = display .. " - " .. description
    end
    table.insert(choices, {
      name = name,
      label = label,
      description = description,
      display = display,
      sink = sink,
    })
  end

  local function finish(choice)
    if type(choice) == "string" then
      cb(choice)
      return
    end
    if type(choice) == "table" and type(choice.name) == "string" then
      cb(choice.name)
      return
    end
    cb(nil)
  end

  local picker = ((require("pjollrig.config").get() or {}).ui or {}).sink_picker
  local opts = {
    prompt = "Pjollrig: send to",
    format_item = function(item)
      return item.display or item.name
    end,
  }
  if type(picker) == "function" then
    local ok, err = pcall(picker, choices, opts, finish)
    if not ok then
      vim.notify("pjollrig: sink picker failed: " .. tostring(err), vim.log.levels.ERROR)
      cb(nil)
    end
    return
  end

  vim.ui.select(choices, opts, finish)
end

local cached_email

---Best-effort author identity. Falls back to $USER or "?".
---@return string
function M.git_email()
  if cached_email then
    return cached_email
  end
  local ok, result = pcall(function()
    return vim.system({ "git", "config", "user.email" }, { text = true }):wait()
  end)
  if ok and result and result.code == 0 and result.stdout then
    local trimmed = (result.stdout:gsub("%s+$", ""))
    if trimmed ~= "" then
      cached_email = trimmed
      return cached_email
    end
  end
  cached_email = vim.env.USER or "?"
  return cached_email
end

return M
