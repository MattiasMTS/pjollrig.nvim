-- pjollrig.nvim: reference sink — copies formatted comments into the
-- system clipboard register ("+"). Serves as a minimal implementation
-- template for more involved sinks (PR drafts, webhooks, etc.).

local M = {}

local function build_spec(opts)
  opts = opts or {}
  local helpers = require("pjollrig.sinks.helpers")
  local spec = {
    name = "clipboard",
    type = "sink",
    label = "Clipboard",
    description = "copy formatted comments to the + register",
    pre_text = opts.pre_text,
    post_text = opts.post_text,
    clear_on_success = opts.clear_on_success,
    format = function(c)
      return helpers.format_line(c)
    end,
    -- Like every sink, a successful copy clears the sent comments by
    -- default, so a copy that silently went nowhere would lose them.
    -- Without a provider `setreg("+")` succeeds but stores nothing.
    validate = function()
      if vim.fn.has("clipboard") ~= 1 then
        return false, "no clipboard provider available (see :checkhealth provider); comments kept"
      end
      return true
    end,
  }
  spec.send = function(comments, _ctx, cb)
    local lines = {}
    for _, c in ipairs(comments) do
      table.insert(lines, spec.format(c))
    end
    local text = helpers.wrap_text(table.concat(lines, "\n"), spec)
    vim.fn.setreg("+", text)
    -- Read back before reporting success: only a verified copy may
    -- trigger clear_on_success. Trailing newlines are provider noise.
    local stored = vim.fn.getreg("+")
    if type(stored) ~= "string" or stored:gsub("\n+$", "") ~= text:gsub("\n+$", "") then
      cb(false, "clipboard copy could not be verified; comments kept")
      return
    end
    cb(true)
  end
  return spec
end

---Build the clipboard sink spec.
---@param opts? {pre_text?: string, post_text?: string, clear_on_success?: boolean}
---@return table spec sink spec (see sinks.register)
function M.setup(opts)
  return build_spec(opts)
end

return M
