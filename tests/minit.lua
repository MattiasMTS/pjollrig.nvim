#!/usr/bin/env -S nvim -l

local uv = vim.uv
local cwd = uv.cwd()

local args = {}
local offline = vim.env.LAZY_OFFLINE == "1" or vim.env.LAZY_OFFLINE == "true"
local filter_pattern = vim.env.PJOLLRIG_TEST_FILTER
for _, arg in ipairs(_G.arg or {}) do
  if arg == "--minitest" then
    -- Compatibility with the previous lazy.minit-based command.
  elseif arg == "--offline" then
    offline = true
  elseif arg:sub(1, 9) == "--filter=" then
    filter_pattern = arg:sub(10)
  else
    table.insert(args, arg)
  end
end

vim.env.LAZY_STDPATH = vim.env.LAZY_STDPATH or ".tests"

local root = vim.fn.fnamemodify(vim.env.LAZY_STDPATH, ":p"):gsub("[\\/]$", "")
for _, name in ipairs({ "config", "data", "state", "cache" }) do
  vim.env[("XDG_%s_HOME"):format(name:upper())] = root .. "/" .. name
end

local mini_test_path = vim.fn.stdpath("data") .. "/lazy/mini.test"
local mini_test_commit = "4b187876dc134c820677f9e67f0b28910be739ea"
if vim.fn.isdirectory(mini_test_path) ~= 1 then
  if offline then
    error("mini.test is not installed in " .. mini_test_path .. "; rerun without --offline once to install test deps")
  end
  vim.fn.mkdir(vim.fn.fnamemodify(mini_test_path, ":h"), "p")
  local output = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/echasnovski/mini.test.git",
    mini_test_path,
  })
  if vim.v.shell_error ~= 0 then
    error("failed to install mini.test:\n" .. output)
  end
end
if vim.fn.isdirectory(mini_test_path) == 1 then
  local head = vim.fn.systemlist({ "git", "-C", mini_test_path, "rev-parse", "HEAD" })[1]
  if head ~= mini_test_commit then
    if offline then
      error(("mini.test is at %s, expected %s; rerun without --offline once"):format(tostring(head), mini_test_commit))
    end
    local fetch = vim.fn.system({
      "git",
      "-C",
      mini_test_path,
      "fetch",
      "--depth=1",
      "origin",
      mini_test_commit,
    })
    if vim.v.shell_error ~= 0 then
      error("failed to fetch pinned mini.test commit:\n" .. fetch)
    end
    local checkout = vim.fn.system({ "git", "-C", mini_test_path, "checkout", "--detach", mini_test_commit })
    if vim.v.shell_error ~= 0 then
      error("failed to checkout pinned mini.test commit:\n" .. checkout)
    end
  end
  vim.opt.rtp:prepend(mini_test_path)
else
  error("mini.test was not installed in " .. mini_test_path)
end

vim.opt.rtp:prepend(cwd)
package.path = table.concat({
  cwd .. "/tests/?.lua",
  cwd .. "/?.lua",
  package.path,
}, ";")

local function collect_files()
  if #args == 0 then
    return vim.fn.globpath("tests", "**/*_spec.lua", true, true)
  end

  local files = {}
  for _, arg in ipairs(args) do
    if vim.fn.isdirectory(arg) == 1 then
      vim.list_extend(files, vim.fn.globpath(arg, "**/*_spec.lua", true, true))
    else
      table.insert(files, arg)
    end
  end
  return files
end

local MiniTest = require("mini.test")
local reporter = MiniTest.gen_reporter.stdout({ group_depth = 1, quit_on_finish = false })
local reporter_finish = reporter.finish
reporter.finish = function(...)
  reporter_finish(...)
  local failed = false
  for _, case in ipairs(MiniTest.current.all_cases or {}) do
    if type(case.exec) == "table" and type(case.exec.fails) == "table" and #case.exec.fails > 0 then
      failed = true
      break
    end
  end
  os.exit(failed and 1 or 0)
end

MiniTest.setup({
  collect = {
    emulate_busted = true,
    find_files = collect_files,
    filter_cases = function(case)
      if not filter_pattern or filter_pattern == "" then
        return true
      end
      return table.concat(case.desc or {}, " "):find(filter_pattern) ~= nil
    end,
  },
  execute = {
    reporter = reporter,
  },
})

_G.assert = require("luassert")

-- MiniTest's default executor schedules each case. Running plugin setup
-- and filesystem-heavy integration paths from scheduled callbacks has
-- exposed Neovim/macOS hangs in the past, which led to global vim.fs
-- shims. Keep collection/reporting from MiniTest, but execute cases
-- directly so tests use the real Neovim APIs.
local function callable(fn, ...)
  if type(fn) == "function" then
    return fn(...)
  end
  local mt = type(fn) == "table" and getmetatable(fn) or nil
  if mt and type(mt.__call) == "function" then
    return fn(...)
  end
end

local function final_state(case)
  local pass_fail = #case.exec.fails == 0 and "Pass" or "Fail"
  local with_notes = #case.exec.notes == 0 and "" or " with notes"
  return pass_fail .. with_notes
end

local function execute_sync(cases, opts)
  opts = opts or {}
  local reporter = opts.reporter
  MiniTest.current.all_cases = cases

  if #cases == 0 then
    print("(mini.test) No cases to execute.")
    os.exit(0)
  end

  callable(reporter and reporter.start, cases)

  for case_num, case in ipairs(cases) do
    case.exec = { fails = {}, notes = {} }
    MiniTest.current.case = case

    local function run_step(fn, state)
      case.exec.state = state
      local ok, err = xpcall(fn, function(e)
        return debug.traceback(tostring(e), 2)
      end)
      if not ok then
        table.insert(case.exec.fails, err)
      end
      return ok
    end

    for i, hook in ipairs(case.hooks.pre or {}) do
      run_step(hook, ("Executing 'pre' hook #%d"):format(i))
    end

    if #case.exec.fails == 0 then
      run_step(function()
        case.test(unpack(case.args or {}))
      end, "Executing test")
    else
      table.insert(case.exec.notes, "Skip case due to error(s) in hooks.")
    end

    for i, hook in ipairs(case.hooks.post or {}) do
      run_step(hook, ("Executing 'post' hook #%d"):format(i))
    end

    case.exec.state = final_state(case)
    callable(reporter and reporter.update, case_num)
  end

  callable(reporter and reporter.finish)
end

execute_sync(MiniTest.collect(), { reporter = reporter })
