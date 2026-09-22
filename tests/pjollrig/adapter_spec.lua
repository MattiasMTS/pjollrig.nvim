-- Exercises `pjollrig.adapter` — temp-prefix detection, diff-pair
-- resolution, and `identify()` round-trips.

local adapter
local uri_mod
local tmp_state
local tmp_root

---Return a subdirectory under the test's current working directory so
---tests can create "working-tree" files that do NOT sit under a temp
---prefix (the adapter's heuristic rejects /tmp, /var/folders/..., and
---their /private/... aliases). `vim.fn.tempname()` on macOS always
---lives under `/var/folders/...`, which would make a working-tree
---buffer look like a reference side to the heuristic.
local function project_subdir(name)
  local base = vim.fs.normalize(vim.fn.fnamemodify(vim.uv.cwd() .. "/" .. name, ":p"))
  vim.fn.mkdir(base, "p")
  return base
end

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = project_subdir(".pjollrig-test-root-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6)))
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  require("pjollrig.store")._reset()
  require("pjollrig").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      canonicalize_symlinks = false,
      poll_interval_ms = 0,
    },
  })
  adapter = require("pjollrig.adapter")
  uri_mod = require("pjollrig.uri")
end

local function teardown_env()
  require("pjollrig.store")._reset()
  -- Reset to a single window with a nameless scratch so the next test
  -- doesn't inherit diff windows from the previous one.
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "enew!")
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
end

describe("pjollrig.adapter temp detection", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("resolve_diff_pair returns nil when fewer than 2 diff windows", function()
    vim.cmd.edit(tmp_root .. "/a.lua")
    local bufnr = vim.api.nvim_get_current_buf()
    local pair, err = adapter.resolve_diff_pair(bufnr)
    assert.is_nil(pair)
    assert.is_nil(err)
  end)

  it("resolve_diff_pair returns nil+err when both diff windows are real (non-temp)", function()
    -- Plain `nvim -d a.lua b.lua` — both non-temp, ambiguous per spec.
    vim.cmd.edit(tmp_root .. "/a.lua")
    vim.cmd.diffthis()
    vim.cmd.vsplit(tmp_root .. "/b.lua")
    vim.cmd.diffthis()

    local cur = vim.api.nvim_get_current_buf()
    local pair, err = adapter.resolve_diff_pair(cur)
    assert.is_nil(pair)
    assert.are.equal("ambiguous diff pair", err)
  end)

  it("resolve_diff_pair identifies the temp side when one buffer sits under /tmp", function()
    -- /tmp on macOS resolves through /private/tmp, so compose the
    -- reference path with fs.normalize to match the heuristic.
    local temp_dir = "/tmp/git-blob-pjollrig-test"
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/ref.lua"
    vim.fn.writefile({ "ref" }, temp_file)

    local working = tmp_root .. "/working.lua"
    vim.fn.writefile({ "working" }, working)

    vim.cmd.edit(working)
    local working_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()
    vim.cmd("vsplit " .. vim.fn.fnameescape(temp_file))
    local ref_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()

    local pair = adapter.resolve_diff_pair(ref_bufnr)
    assert.is_truthy(pair)
    assert.are.equal(working_bufnr, pair.working_bufnr)
    assert.are.equal(ref_bufnr, pair.reference_bufnr)
    assert.are.equal(uri_mod.for_bufnr(working_bufnr), pair.working_uri)

    pcall(vim.fn.delete, temp_dir, "rf")
  end)

  it("identify returns project identity on a plain file buffer", function()
    vim.cmd.edit(tmp_root .. "/note.lua")
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(err)
    assert.is_truthy(id)
    assert.are.equal("project", id.scope)
    assert.is_true(id.is_writable)
    assert.is_nil(id.diff_side)
    assert.are.equal(uri_mod.for_bufnr(bufnr), id.uri)
  end)

  it("maps codediff virtual buffers to the project file identity", function()
    local rel = "infra/terraform-gcp-core/sherlog.tf"
    local real = tmp_root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(real, ":h"), "p")
    vim.fn.writefile({ "resource x", "resource y" }, real)

    local codediff_url = ("codediff:///%s///fedfddb447cd91e8042810ce517e84c6701f55f0/%s"):format(tmp_root, rel)
    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(bufnr, codediff_url)
    vim.bo[bufnr].buftype = "nowrite"

    local id, err = adapter.identify(bufnr)
    assert.is_nil(err)
    assert.is_truthy(id)
    assert.are.equal("project", id.scope)
    assert.is_true(id.is_writable)
    assert.are.equal(vim.fs.normalize(tmp_root), vim.fs.normalize(id.project_root))
    assert.are.equal(uri_mod.for_path(real), id.uri)

    require("pjollrig").add({ body = "codediff note", range = { start = { 1, 0 }, end_ = { 1, 0 } } })
    local records = require("pjollrig.store").all(vim.fs.normalize(tmp_root))
    assert.are.equal(1, #records)
    local text = require("pjollrig.sinks.helpers").format_markdown_review(records)
    assert.is_truthy(text:find("## M1 " .. rel .. ":2", 1, true))
    assert.is_nil(text:find("codediff:", 1, true))
  end)

  it("identify returns writable session identity for an unnamed buffer", function()
    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(err)
    assert.is_truthy(id)
    assert.are.equal("session", id.scope)
    assert.is_true(id.is_writable)
    assert.is_true(id.ephemeral)
    assert.is_truthy(id.uri:match("^manicule://buffer/"))
    assert.are.equal(id.uri, require("pjollrig.uri").for_bufnr(bufnr))
  end)

  it("add works on unnamed buffers and keeps the record session-local", function()
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch line" })
    local bufnr = vim.api.nvim_get_current_buf()

    require("pjollrig").add({ body = "scratch note", range = { start = { 0, 0 }, end_ = { 0, 0 } } })

    local records = require("pjollrig.store").session_all()
    assert.are.equal(1, #records)
    assert.are.equal("scratch note", records[1].body)
    assert.are.equal(adapter.identify(bufnr).uri, records[1].uri)
    assert.is_true(records[1].meta.ephemeral)
  end)

  it("identify refuses add on the reference side of a git diff pair", function()
    local temp_dir = "/tmp/git-blob-pjollrig-test2"
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/ref.lua"
    vim.fn.writefile({ "ref" }, temp_file)

    local working = tmp_root .. "/working2.lua"
    vim.fn.writefile({ "working" }, working)

    vim.cmd.edit(working)
    local working_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()
    vim.cmd("vsplit " .. vim.fn.fnameescape(temp_file))
    local ref_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()

    local id = adapter.identify(ref_bufnr)
    assert.is_truthy(id)
    assert.are.equal("reference", id.diff_side)
    assert.is_false(id.is_writable)
    assert.is_truthy(id.reject_reason)
    -- URI anchors to the working-tree side, not the temp file.
    assert.are.equal(uri_mod.for_bufnr(working_bufnr), id.uri)

    -- And the working-tree side IS writable with diff_side = working.
    local wid = adapter.identify(working_bufnr)
    assert.is_truthy(wid)
    assert.are.equal("working", wid.diff_side)
    assert.is_true(wid.is_writable)

    pcall(vim.fn.delete, temp_dir, "rf")
  end)

  it("identify leaves an unrelated loaded buffer writable while a diff pair is open", function()
    -- Regression: resolve_diff_pair classifies the current tab's diff
    -- windows regardless of which bufnr is passed, so identify() must
    -- only apply the reference branch when bufnr is genuinely the
    -- working or reference participant. An ordinary project file buffer
    -- loaded alongside a difftool view must keep its own writable
    -- identity and its own URI — not get mislabeled as the reference
    -- side with the working file's URI.
    local temp_dir = "/tmp/git-blob-pjollrig-test3"
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/ref.lua"
    vim.fn.writefile({ "ref" }, temp_file)

    local working = tmp_root .. "/working3.lua"
    vim.fn.writefile({ "working" }, working)

    -- An unrelated, ordinary project file that is NOT part of the diff.
    local unrelated = tmp_root .. "/unrelated3.lua"
    vim.fn.writefile({ "unrelated" }, unrelated)
    -- Load it as a buffer (the all-loaded render sweeps call identify on
    -- every loaded buffer), but don't keep it in a diff window.
    local unrelated_bufnr = vim.fn.bufadd(unrelated)
    vim.fn.bufload(unrelated_bufnr)

    vim.cmd.edit(working)
    vim.cmd.diffthis()
    vim.cmd("vsplit " .. vim.fn.fnameescape(temp_file))
    vim.cmd.diffthis()

    -- A diff pair IS open in this tab; confirm the heuristic resolves it
    -- even when asked about the unrelated buffer (the pre-fix trap).
    local pair = adapter.resolve_diff_pair(unrelated_bufnr)
    assert.is_truthy(pair)

    local id = adapter.identify(unrelated_bufnr)
    assert.is_truthy(id)
    assert.is_true(id.is_writable)
    assert.are_not.equal("reference", id.diff_side)
    assert.is_nil(id.diff_side)
    -- URI must be the unrelated buffer's OWN uri, not the working_uri.
    assert.are.equal(uri_mod.for_bufnr(unrelated_bufnr), id.uri)
    assert.are_not.equal(pair.working_uri, id.uri)

    pcall(vim.fn.delete, temp_dir, "rf")
  end)

  it("identify returns session scope on an unrooted file buffer", function()
    -- Plain /tmp file with no project marker. persist_unrooted defaults
    -- to true in phase 3 so the identity is writable session.
    local tmpfile = "/tmp/pjollrig-unrooted-test-" .. tostring(os.time()) .. ".txt"
    vim.fn.writefile({ "hi" }, tmpfile)
    vim.cmd.edit(tmpfile)
    local bufnr = vim.api.nvim_get_current_buf()
    local id = adapter.identify(bufnr)
    assert.is_truthy(id)
    assert.are.equal("session", id.scope)
    assert.is_true(id.is_writable)
    assert.is_nil(id.project_root)
    pcall(vim.fn.delete, tmpfile)
  end)

  it("identify returns session scope on a terminal buffer", function()
    vim.cmd("enew")
    local job = vim.fn.termopen({ "/bin/sh", "-c", "exit 0" })
    local bufnr = vim.api.nvim_get_current_buf()
    local id = adapter.identify(bufnr)
    pcall(vim.fn.jobstop, job)
    assert.is_truthy(id)
    assert.are.equal("session", id.scope)
    assert.is_true(id.is_writable)
    assert.is_nil(id.diff_side)
    -- URI is a term:// URL (or similar non-file scheme).
    assert.is_false(uri_mod.is_file(id.uri))
  end)

  it("identify returns session scope on a help buffer", function()
    pcall(vim.cmd, "help")
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "help" then
      pending("help not available in headless mode")
      return
    end
    local id = adapter.identify(bufnr)
    assert.is_truthy(id)
    assert.are.equal("session", id.scope)
    assert.is_true(id.is_writable)
  end)

  it("identify rejects a quickfix buffer", function()
    vim.cmd("enew")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].buftype = "quickfix"
    local id = adapter.identify(bufnr)
    assert.is_truthy(id)
    assert.is_false(id.is_writable)
    assert.is_truthy(id.reject_reason)
  end)

  it("identify rejects a prompt buffer", function()
    vim.cmd("enew")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(bufnr, "pjollrig://prompt-test")
    vim.bo[bufnr].buftype = "prompt"
    local id = adapter.identify(bufnr)
    assert.is_truthy(id)
    assert.is_false(id.is_writable)
    assert.is_truthy(id.reject_reason)
  end)

  it("identify in plain nvim -d treats each buffer as its own identity", function()
    -- Both sides are real paths → no pair → each buffer returns a
    -- writable project identity.
    vim.cmd.edit(tmp_root .. "/left.lua")
    local left = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()
    vim.cmd.vsplit(tmp_root .. "/right.lua")
    local right = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()

    local lid = adapter.identify(left)
    local rid = adapter.identify(right)
    assert.is_truthy(lid)
    assert.is_truthy(rid)
    assert.is_true(lid.is_writable)
    assert.is_true(rid.is_writable)
    assert.is_nil(lid.diff_side)
    assert.is_nil(rid.diff_side)
    assert.are_not.equal(lid.uri, rid.uri)
  end)
end)
