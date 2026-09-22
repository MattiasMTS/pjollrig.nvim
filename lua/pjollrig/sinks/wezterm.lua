-- Send reviews to a selected sibling pane in WezTerm.
local helpers = require("pjollrig.sinks.helpers")
local M = {}

function M.is_available(opts)
  opts = opts or {}
  return tonumber(opts.current_pane or vim.env.WEZTERM_PANE) ~= nil and helpers.executable(opts.command or "wezterm")
end

function M.setup(opts)
  opts = vim.tbl_extend("force", {
    command = "wezterm",
    submit_delay_ms = 120,
    timeout_ms = 5000,
    clear_on_success = true,
  }, opts or {})
  vim.validate("wezterm.auto_submit", opts.auto_submit, "boolean", true)
  vim.validate("wezterm.clear_on_success", opts.clear_on_success, "boolean", true)
  vim.validate("wezterm.submit_delay_ms", opts.submit_delay_ms, function(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
  end, "a nonnegative integer")
  vim.validate("wezterm.timeout_ms", opts.timeout_ms, function(value)
    return type(value) == "number" and value > 0 and value % 1 == 0
  end, "a positive integer")
  local remembered, busy

  -- Catch launch failures even when invoked from a picker or timer callback.
  local function run(args, stdin, cb)
    local argv = { opts.command, "cli", "--no-auto-start" }
    vim.list_extend(argv, args)
    local ok, err = pcall(helpers.system_async, argv, {
      stdin = stdin,
      timeout = opts.timeout_ms,
    }, cb)
    if not ok then
      cb({ code = -1, stdout = "", stderr = tostring(err) })
    end
  end

  local function siblings(cb)
    local current = tonumber(opts.current_pane or vim.env.WEZTERM_PANE)
    if not current then
      cb(nil, "WezTerm current pane is unknown (WEZTERM_PANE is missing)")
      return
    end
    run({ "list", "--format", "json" }, nil, function(result)
      if result.code ~= 0 then
        cb(nil, "WezTerm pane discovery failed: " .. result.stderr)
        return
      end
      local ok, panes = pcall(vim.json.decode, result.stdout)
      if not ok or type(panes) ~= "table" or not vim.islist(panes) then
        cb(nil, "WezTerm returned an invalid pane list")
        return
      end
      local source
      for _, pane in ipairs(panes) do
        if type(pane) ~= "table" or type(pane.pane_id) ~= "number" or type(pane.tab_id) ~= "number" then
          cb(nil, "WezTerm returned an invalid pane entry")
          return
        end
        if pane.pane_id == current then
          source = pane
        end
      end
      if not source then
        cb(nil, "Neovim's pane was not found in WezTerm")
        return
      end
      local choices = {}
      for _, pane in ipairs(panes) do
        if pane.tab_id == source.tab_id and pane.pane_id ~= current then
          table.insert(choices, pane)
        end
      end
      cb(choices)
    end)
  end

  return {
    name = "wezterm",
    type = "integration",
    label = "WezTerm pane",
    description = "paste review into another split in this tab",
    clear_on_success = opts.clear_on_success,
    health = function()
      return {
        command = opts.command,
        available = M.is_available(opts),
        current_pane = opts.current_pane or vim.env.WEZTERM_PANE,
      }
    end,
    send = function(comments, ctx, cb)
      if busy then
        cb(false, "a WezTerm send is already in progress")
        return
      end
      local text = helpers.format_markdown_review(comments, opts)
      busy = true
      local function finish(ok, err)
        busy = false
        cb(ok, err)
      end
      local function paste(pane)
        local id = tostring(pane.pane_id)
        run({ "send-text", "--pane-id", id }, text, function(result)
          if result.code ~= 0 then
            finish(false, "WezTerm paste failed; check the target pane before retrying: " .. result.stderr)
            return
          end
          remembered = pane.pane_id
          if not opts.auto_submit then
            finish(true)
            return
          end
          vim.defer_fn(function()
            run({ "send-text", "--pane-id", id, "--no-paste" }, "\r", function(submit)
              if submit.code ~= 0 then
                finish(false, "review pasted but submission failed; press Enter in the WezTerm pane manually")
                return
              end
              finish(true)
            end)
          end, opts.submit_delay_ms)
        end)
      end
      siblings(function(panes, err)
        if not panes or #panes == 0 then
          finish(false, err or "no other WezTerm panes in this tab; open a split for your agent")
          return
        end
        if not ctx.pick then
          for _, pane in ipairs(panes) do
            if pane.pane_id == remembered then
              paste(pane)
              return
            end
          end
        end
        local ok, pick_err = pcall(require("pjollrig.ui.select").select, panes, {
          prompt = "WezTerm: send review to",
          format_item = function(pane)
            return ("%s [pane %d] — %s"):format(pane.title or "untitled", pane.pane_id, pane.cwd or "")
          end,
        }, function(selected)
          if not selected then
            finish(false, "cancelled")
            return
          end
          -- A picker may stay open while panes are closed or moved.
          siblings(function(fresh, list_err)
            for _, pane in ipairs(fresh or {}) do
              if pane.pane_id == selected.pane_id then
                paste(pane)
                return
              end
            end
            finish(false, list_err or "selected WezTerm pane is no longer in this tab; send again to choose a pane")
          end)
        end)
        if not ok then
          finish(false, "WezTerm pane picker failed: " .. tostring(pick_err))
        end
      end)
    end,
  }
end

return M
