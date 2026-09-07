-- pjollrig.nvim: sink registry.
--
-- A sink is anything that accepts a list of comment records and does
-- something useful with them — copy to clipboard, open a draft PR,
-- post to a chat webhook, pipe into another tool, etc. Adapters are
-- registered via `M.register` and dispatched via `M.dispatch`.

local M = {}
local sinks = {}

local builtin_integrations = {
  clipboard = "pjollrig.sinks.clipboard",
  cmux = "pjollrig.sinks.cmux",
  github = "pjollrig.sinks.github",
  socket = "pjollrig.sinks.socket",
}

local builtin_defaults = {
  clipboard = {
    enabled = true,
  },
  cmux = {
    enabled = true,
  },
  github = {
    enabled = true,
  },
  socket = {
    enabled = true,
  },
}

local function integration_opts(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function normalize_integration(value, default)
  default = default or {}
  local opts = integration_opts(value)
  local enabled = default.enabled

  if value == nil then
    return enabled, opts
  end
  if type(value) == "boolean" then
    return value, opts
  end

  if type(value) == "table" then
    if value.enabled ~= nil then
      enabled = value.enabled
    end
    return enabled, opts
  end

  return value, opts
end

local function load_spec(module_name, opts)
  local mod = require(module_name)
  if type(mod.setup) == "function" then
    return mod.setup(opts)
  end
  if type(mod.spec) == "function" then
    return mod.spec(opts)
  end
  return mod.spec
end

---Register a sink adapter.
---
---Errors when a sink with the same name is already registered (mirrors
---`panel.register_tab`): a user sink can never silently clobber a builtin
---or another user sink. To replace a builtin, disable it in config first
---(e.g. `sinks = { github = false }`). `M.setup` re-registers builtins
---safely because it clears the builtin names before registering them.
---@param spec {name: string, send: fun(comments, ctx, cb), type?: string, label?: string, description?: string, pre_text?: string, post_text?: string, format?: fun(c): string, validate?: fun(ctx): boolean, string?, health?: fun(): table?, clear_on_success?: boolean, hidden?: boolean}
---
---Spec fields:
---  name              string     unique sink identifier
---  type              string?    "sink" (default) or "integration"
---  label             string?    display name for pickers / health
---  description       string?    picker hint / documentation
---  pre_text          string?    text prepended to text payloads by bundled sinks
---  post_text         string?    text appended to text payloads by bundled sinks
---  send              function   function(comments, ctx, cb) — cb(ok: boolean, err: string?)
---  format            function?  per-record formatter
---  validate          function?  gate the dispatch; return false, err to reject
---  health            function?  returns optional diagnostic info for checkhealth
---  clear_on_success  boolean?   if true, core deletes every record in the batch
---                               after the sink's send callback reports ok=true.
---                               default: false (records persist).
---  hidden            boolean?   if true, the sink stays registered (dispatchable
---                               by name via `get`/`dispatch`) but is excluded
---                               from `list()`, i.e. from interactive pickers,
---                               single-sink auto-dispatch, and completion.
---                               For sinks that only work with a caller-supplied
---                               ctx (e.g. socket). default: false.
function M.register(spec)
  vim.validate("name", spec.name, "string")
  vim.validate("send", spec.send, "function")
  vim.validate("type", spec.type, "string", true)
  vim.validate("label", spec.label, "string", true)
  vim.validate("description", spec.description, "string", true)
  vim.validate("pre_text", spec.pre_text, "string", true)
  vim.validate("post_text", spec.post_text, "string", true)
  vim.validate("format", spec.format, "function", true)
  vim.validate("validate", spec.validate, "function", true)
  vim.validate("health", spec.health, "function", true)
  vim.validate("clear_on_success", spec.clear_on_success, "boolean", true)
  vim.validate("hidden", spec.hidden, "boolean", true)
  if sinks[spec.name] then
    error(("pjollrig: sink %q is already registered"):format(spec.name))
  end
  spec.type = spec.type or "sink"
  sinks[spec.name] = spec
end

---Register all bundled sinks/integrations according to config.
---
---`sinks.clipboard` defaults to true.
---`sinks.cmux` defaults to `{ enabled = true }`: register when a cmux
---workspace and usable cmux executable are available.
---
---Idempotent for builtins: every builtin name is cleared before its spec
---is (re-)registered, so repeated setup() calls (config reload, tests)
---never trip `register`'s duplicate-name error. User-registered sinks
---under non-builtin names are left untouched.
---@param cfg table|nil per-sink config keyed by builtin name; `false` or `{ enabled = false }` disables a builtin
function M.setup(cfg)
  cfg = cfg or {}
  for name in pairs(builtin_integrations) do
    sinks[name] = nil
  end
  for name, module_name in pairs(builtin_integrations) do
    local enabled, opts = normalize_integration(cfg[name], builtin_defaults[name])
    local mod = require(module_name)
    if enabled and type(mod.is_available) == "function" then
      enabled = mod.is_available(opts)
    end
    if enabled then
      M.register(load_spec(module_name, opts))
    end
  end
end

---Look up a registered sink by name.
---@param name string
---@return table|nil
function M.get(name)
  return sinks[name]
end

---Return all registered sink specs keyed by name.
---
---The result is a deepcopied snapshot — mutating it never affects the
---registry. Do not call in hot paths (checkhealth-style consumers only).
---@return table<string, table>
function M.all()
  return vim.deepcopy(sinks)
end

---List sink names offered for interactive selection.
---
---Hidden sinks (`spec.hidden`) stay registered — `get`/`dispatch` by name
---keep working, e.g. a review job dispatching to "socket" with a session ctx —
---but are excluded here so pickers, single-sink auto-dispatch, and cmdline
---completion never offer a sink that cannot validate without a
---caller-supplied ctx.
---@return string[]
function M.list()
  local names = {}
  for name, spec in pairs(sinks) do
    if not spec.hidden then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

---Dispatch a comment list to a named sink.
---
---Every outcome — unknown sink, failed validate, sync throw in send,
---async failure — is reported through `cb(ok, err)`; `cb` fires exactly
---once, with `err` set only when `ok` is false. Dispatch never throws for
---sink-level failures.
---@param name string
---@param comments table
---@param ctx table|nil
---@param cb fun(ok: boolean, err: string?) required; receives the outcome exactly once
function M.dispatch(name, comments, ctx, cb)
  vim.validate("cb", cb, "function")
  local sink = sinks[name]
  if not sink then
    cb(false, "pjollrig: unknown sink: " .. tostring(name))
    return
  end
  ctx = ctx or {}
  if sink.validate then
    local ok, valid, err = pcall(sink.validate, ctx)
    if not ok then
      cb(false, "pjollrig: sink " .. tostring(name) .. " validate failed: " .. tostring(valid))
      return
    end
    if not valid then
      cb(false, err)
      return
    end
  end
  local done = false
  local function finish(ok, err)
    if done then
      return
    end
    done = true
    cb(ok, err)
  end
  local ok, err = pcall(sink.send, comments, ctx, finish)
  if not ok then
    finish(false, "pjollrig: sink " .. tostring(name) .. " send failed: " .. tostring(err))
  end
end

---Internal: exposed for tests.
function M._reset()
  sinks = {}
end

return M
