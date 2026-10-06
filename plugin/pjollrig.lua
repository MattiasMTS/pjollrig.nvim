local api = vim.api
local subs = { "add", "edit", "delete", "resolve", "list", "send", "review" }

api.nvim_create_user_command("Pjollrig", function(o)
  local P, sub, arg = require("pjollrig"), o.fargs[1] or "list", o.fargs[2]
  if sub == "add" then
    P.add(o.range > 0 and { line1 = o.line1, line2 = o.line2 } or nil)
  elseif sub == "list" then
    P.loclist(arg == "all")
  elseif sub == "send" then
    require("pjollrig.sinks").send(arg)
  elseif sub == "review" and arg == "pr" then
    require("pjollrig.github").start(o.fargs[3])
  elseif sub == "review" then
    require("pjollrig.review").start(arg)
  elseif vim.tbl_contains(subs, sub) then
    P[sub]()
  else
    vim.notify("pjollrig: unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  range = true,
  complete = function(lead, line)
    local n = #vim.split(line:gsub("^%S+%s*", ""), "%s+")
    local sub = line:match("^%S+%s+(%S+)%s")
    local opts = n <= 1 and subs
      or sub == "list" and { "all" }
      or sub == "review" and n == 2 and { "pr" }
      or sub == "send" and require("pjollrig.sinks").available()
      or {}
    return vim.tbl_filter(function(s)
      return vim.startswith(s, lead)
    end, opts)
  end,
})

local g = api.nvim_create_augroup("pjollrig", {})
local function on(event, fn, pattern) -- bare `nvim` (one unnamed buffer) never loads the plugin
  api.nvim_create_autocmd(event, {
    group = g,
    pattern = pattern,
    callback = function(ev)
      if package.loaded.pjollrig or api.nvim_buf_get_name(ev.buf) ~= "" or vim.wo.diff then
        fn(ev)
      end
    end,
  })
end
on("BufReadPost", function(ev)
  require("pjollrig").on_read(ev.buf)
end)
on("BufWinEnter", function(ev)
  require("pjollrig").paint(ev.buf)
  local review = package.loaded["pjollrig.review"]
  if review then
    review.on_enter(ev.buf)
  end
end)
on("BufReadCmd", function(ev)
  require("pjollrig.review").read(ev.buf)
end, "pjollrig://*")
on("BufWritePost", function(ev)
  require("pjollrig").sync(ev.buf)
end)
local function refresh() -- diff partners exist only once 'diff' is on (nvim -d, :diffthis)
  vim.schedule(require("pjollrig").refresh)
end
on("VimEnter", refresh)
on("OptionSet", refresh, "diff")
