if vim.fn.has("nvim-0.12") ~= 1 then
  vim.notify("pjollrig.nvim requires Neovim >= 0.12", vim.log.levels.ERROR)
  return
end

if vim.g.loaded_pjollrig then
  return
end
vim.g.loaded_pjollrig = 1

---Resolve a command's opts into the action to run.
---
---- No argument → open the `vim.ui.select` picker for the action.
---- Numeric argument in `[1, #records]` → dispatch to the action with
---  the id at that position in `list()` ordering.
---- Anything else → ERROR notify.
---@param action "edit"|"delete"|"resolve"
---@param opts table
local function dispatch_positional(action, opts)
  local records = require("pjollrig").list()
  if opts.args == nil or opts.args == "" then
    require("pjollrig.ui.picker").pick(action, records)
    return
  end
  local n = tonumber(opts.args)
  if not n or n ~= math.floor(n) or n < 1 or n > #records then
    vim.notify(("pjollrig: no comment at position %q"):format(opts.args), vim.log.levels.ERROR)
    return
  end
  require("pjollrig")[action](records[n].id, {
    scope = records[n].scope,
    project_root = records[n].project_root,
  })
end

---Keep only the candidates starting with the cmdline prefix `arglead`.
---@param arglead string
---@param candidates string[]
---@return string[]
local function prefix_filter(arglead, candidates)
  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, arglead)
  end, candidates)
end

---Completion candidates are cached for a short TTL (the pattern used by
---pjollrig.review.complete): repeated <Tab> presses must not re-query
---the whole store on every keystroke.
local COMPLETION_CACHE_TTL_MS = 10 * 1000

---@type table<string, {at: number, items: string[]}>
local completion_cache = {}

---Memoize `fn()` under `key` for COMPLETION_CACHE_TTL_MS.
---@param key string
---@param fn fun(): string[]
---@return string[]
local function cached(key, fn)
  local hit = completion_cache[key]
  local now = vim.uv.hrtime() / 1e6
  if hit and now - hit.at < COMPLETION_CACHE_TTL_MS then
    return hit.items
  end
  local items = fn()
  completion_cache[key] = { at = now, items = items }
  return items
end

---Tab-completion returns stringified positions `"1"`..`"N"`. Command-
---line completion tokens don't support display text — that's what the
---picker is for.
---@param arglead string
---@return string[]
local function position_completer(arglead)
  local items = cached("positions:" .. tostring(vim.uv.cwd()), function()
    local records = require("pjollrig").list()
    local out = {}
    for i = 1, #records do
      out[i] = tostring(i)
    end
    return out
  end)
  return prefix_filter(arglead, items)
end

vim.api.nvim_create_user_command("PjollrigAdd", function(opts)
  require("pjollrig").add({ range = opts.range > 0 and { opts.line1, opts.line2 } or nil })
end, { range = true })

-- Outside a review session: the panel in project mode (all project
-- comments, Comments-only tab). Inside one: focus the review panel's
-- Comments tab.
vim.api.nvim_create_user_command("PjollrigList", function()
  require("pjollrig.review.panel").open_comments()
end, {})

vim.api.nvim_create_user_command("PjollrigSend", function(opts)
  local sink = opts.fargs[1]
  local ctx
  if sink == "wezterm" and opts.fargs[2] == "pick" and #opts.fargs == 2 then
    ctx = { pick = true }
  elseif opts.fargs[2] ~= nil then
    vim.notify("pjollrig: usage: PjollrigSend [sink] (or PjollrigSend wezterm pick)", vim.log.levels.ERROR)
    return
  end
  require("pjollrig").send(sink, nil, ctx)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    local sink = cmdline:match("PjollrigSend%s+(%S+)%s")
    if sink then
      return sink == "wezterm" and prefix_filter(arglead, { "pick" }) or {}
    end
    return require("pjollrig.sinks").list()
  end,
})

vim.api.nvim_create_user_command("PjollrigResolve", function(opts)
  dispatch_positional("resolve", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("PjollrigDelete", function(opts)
  dispatch_positional("delete", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("PjollrigEdit", function(opts)
  dispatch_positional("edit", opts)
end, { nargs = "?", complete = position_completer })

---During an active review session, :PjollrigToggle shows/hides the
---review panel; otherwise it flips comment visuals on/off.
local function toggle()
  if require("pjollrig.review").state() then
    require("pjollrig.review.panel").toggle()
    return
  end
  require("pjollrig.ui.render").toggle()
end

vim.api.nvim_create_user_command("PjollrigToggle", toggle, {})

-- `:PjollrigDisplay <mode>` sets the comment display mode; with no
-- argument it cycles float → eol → inline → hidden → float.
vim.api.nvim_create_user_command("PjollrigDisplay", function(opts)
  require("pjollrig.ui.render").set_display_mode(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = function(arglead)
    return prefix_filter(arglead, { "float", "eol", "inline", "hidden" })
  end,
})

local function dispatch_jump(direction, opts)
  local count = 1
  if opts.args ~= nil and opts.args ~= "" then
    count = tonumber(opts.args)
    if not count or count ~= math.floor(count) or count < 1 then
      vim.notify(("pjollrig: jump count must be a positive integer, got %q"):format(opts.args), vim.log.levels.ERROR)
      return
    end
  end
  require("pjollrig").jump(direction, { count = count })
end

vim.api.nvim_create_user_command("PjollrigNext", function(opts)
  dispatch_jump("next", opts)
end, { nargs = "?" })

vim.api.nvim_create_user_command("PjollrigPrev", function(opts)
  dispatch_jump("prev", opts)
end, { nargs = "?" })

vim.keymap.set({ "n", "x" }, "<Plug>(pjollrig-add)", function()
  require("pjollrig").add()
end, { silent = true })

vim.keymap.set("n", "<Plug>(pjollrig-list)", function()
  require("pjollrig.review.panel").open_comments()
end, { silent = true })

local function jump_next()
  require("pjollrig").jump("next", { count = vim.v.count1 })
end

local function jump_prev()
  require("pjollrig").jump("prev", { count = vim.v.count1 })
end

vim.keymap.set("n", "<Plug>(pjollrig-next)", jump_next, { silent = true })

vim.keymap.set("n", "<Plug>(pjollrig-prev)", jump_prev, { silent = true })

-- Edit the first comment at/covering the cursor.
-- Pjollrig is buffer-agnostic, so we resolve the target record via the
-- render layer's cursor hit-test helper.
vim.keymap.set("n", "<Plug>(pjollrig-edit)", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = require("pjollrig.ui.render").record_at_cursor(bufnr)
  if not id then
    vim.notify("pjollrig: no comment at cursor", vim.log.levels.WARN)
    return
  end
  require("pjollrig").edit(id)
end, { silent = true })

-- Delete the first comment at/covering the cursor.
vim.keymap.set("n", "<Plug>(pjollrig-delete)", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = require("pjollrig.ui.render").record_at_cursor(bufnr)
  if not id then
    vim.notify("pjollrig: no comment at cursor", vim.log.levels.WARN)
    return
  end
  require("pjollrig").delete(id)
end, { silent = true })

-- Flip visuals on/off without touching the store (or show/hide the
-- review panel during a session). No default binding — the command is
-- enough for most users; expose the <Plug> for anyone who wants a keymap.
vim.keymap.set("n", "<Plug>(pjollrig-toggle)", toggle, { silent = true })

-- Cycle the comment display mode (float → eol → inline → hidden). No
-- default binding — same policy as <Plug>(pjollrig-toggle).
vim.keymap.set("n", "<Plug>(pjollrig-display-cycle)", function()
  require("pjollrig.ui.render").set_display_mode()
end, { silent = true })

-- Default keymaps. The popup footer advertises `gca` / `gcd` so users
-- expect them to work out of the box. Set `vim.g.pjollrig_no_default_keymaps = 1`
-- before the plugin loads to opt out.
if vim.g.pjollrig_no_default_keymaps ~= 1 then
  vim.keymap.set("n", "gca", "<Plug>(pjollrig-edit)", {
    desc = "Pjollrig: edit comment at cursor",
  })
  vim.keymap.set("n", "gcd", "<Plug>(pjollrig-delete)", {
    desc = "Pjollrig: delete comment at cursor",
  })
  vim.keymap.set("n", "]m", jump_next, {
    desc = "Pjollrig: next comment",
  })
  vim.keymap.set("n", "[m", jump_prev, {
    desc = "Pjollrig: previous comment",
  })
end

-- Review mode commands. `:PjollrigReview` returns within one frame:
-- review.start_async opens the shell (tab + panel with a resolving
-- spinner) immediately and the resolver runs as async continuations —
-- see review.start_async / sources.resolve_async. Errors resolve late
-- and always notify from a scheduled callback, safely outside the
-- command context (an ERROR notify inside nvim_cmd — the lazy-loading
-- stub re-invocation path — behaves like :echoerr and is rethrown as
-- a "Vim:" traceback).
vim.api.nvim_create_user_command("PjollrigReview", function(opts)
  require("pjollrig.review").start_async(opts.fargs)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    return require("pjollrig.review.complete").candidates(arglead, cmdline)
  end,
})

vim.api.nvim_create_user_command("PjollrigReviewNext", function()
  require("pjollrig.review").next()
end, {})

vim.api.nvim_create_user_command("PjollrigReviewPrev", function()
  require("pjollrig.review").prev()
end, {})

-- finish()/stop() are pure (ok, err returns); this command layer owns
-- the user-facing notifications for their pre-flight failures.
vim.api.nvim_create_user_command("PjollrigReviewFinish", function(opts)
  local ok, err = require("pjollrig.review").finish({ sink = opts.args ~= "" and opts.args or nil })
  if not ok then
    vim.notify(err, vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  complete = function()
    return require("pjollrig.sinks").list()
  end,
})

vim.api.nvim_create_user_command("PjollrigReviewStop", function()
  local ok, err = require("pjollrig.review").stop()
  if not ok then
    vim.notify(err, vim.log.levels.WARN)
  end
end, {})

vim.api.nvim_create_user_command("PjollrigReviewFiles", function(opts)
  require("pjollrig.review").set_file_mode(opts.args)
end, {
  nargs = "?",
  complete = function(arglead)
    return prefix_filter(arglead, { "single", "all" })
  end,
})

-- `:PjollrigReviewDiffMode` with no argument toggles split <-> unified.
vim.api.nvim_create_user_command("PjollrigReviewDiffMode", function(opts)
  require("pjollrig.review").set_diff_mode(opts.args)
end, {
  nargs = "?",
  complete = function(arglead)
    return prefix_filter(arglead, { "split", "unified" })
  end,
})

vim.keymap.set("n", "<Plug>(pjollrig-review-next)", function()
  require("pjollrig.review").next()
end, { silent = true })

vim.keymap.set("n", "<Plug>(pjollrig-review-prev)", function()
  require("pjollrig.review").prev()
end, { silent = true })

vim.keymap.set("n", "<Plug>(pjollrig-review-diff-mode)", function()
  require("pjollrig.review").set_diff_mode()
end, { silent = true })
