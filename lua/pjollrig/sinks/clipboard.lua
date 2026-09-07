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
    format = function(c)
      return helpers.format_line(c)
    end,
  }
  spec.send = function(comments, _ctx, cb)
    local lines = {}
    for _, c in ipairs(comments) do
      table.insert(lines, spec.format(c))
    end
    vim.fn.setreg("+", helpers.wrap_text(table.concat(lines, "\n"), spec))
    if cb then
      cb(true)
    end
  end
  return spec
end

---Build the clipboard sink spec.
---@param opts? {pre_text?: string, post_text?: string}
---@return table spec sink spec (see sinks.register)
function M.setup(opts)
  return build_spec(opts)
end

return M
