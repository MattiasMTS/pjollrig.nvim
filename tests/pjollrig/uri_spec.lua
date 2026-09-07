-- Exercises the URI helpers: symlink canonicalisation (including the
-- realpath memo's rename invalidation) and ephemeral-buffer URIs.

local H = require("helpers")
local uv = vim.uv

local ctx

local function setup_env()
  -- The realpath memo only engages when canonicalisation is on (the
  -- shipped default); the shared helper turns it off, so opt back in.
  ctx = H.setup({ store = { canonicalize_symlinks = true } })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

describe("pjollrig.uri", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("canonicalises symlinks and re-resolves memoized realpaths after a rename", function()
    local uri_mod = require("pjollrig.uri")
    local t1 = H.write_project_file(ctx, "src/target1.lua", { "return 1" })
    local t2 = H.write_project_file(ctx, "src/target2.lua", { "return 2" })
    local ln = ctx.root .. "/src/link.lua"
    assert.is_truthy(uv.fs_symlink(t1, ln))

    -- Symlinks resolve to the real path; a repeat call (served from the
    -- memo) must return the identical URI.
    assert.are.equal(vim.uri_from_fname(t1), uri_mod.for_path(ln))
    assert.are.equal(vim.uri_from_fname(t1), uri_mod.for_path(ln))

    -- Retarget the symlink, then rename a buffer. BufFilePost clears the
    -- realpath memo wholesale, so the resolution after the rename must be
    -- fresh — never the stale pre-rename realpath.
    assert.is_truthy(uv.fs_unlink(ln))
    assert.is_truthy(uv.fs_symlink(t2, ln))
    local path = H.edit_project_file(ctx, "src/renamer.lua", { "local y = 1" })
    vim.cmd("file " .. vim.fn.fnameescape(path .. ".renamed"))
    vim.wait(100, function()
      return false
    end, 10)

    assert.are.equal(vim.uri_from_fname(t2), uri_mod.for_path(ln))
  end)

  it("keeps ephemeral URIs in a buffer variable and resolves them back", function()
    local uri_mod = require("pjollrig.uri")
    vim.cmd("enew")
    local bufnr = vim.api.nvim_get_current_buf()
    local uri = uri_mod.for_bufnr(bufnr)
    assert.is_true(uri_mod.is_ephemeral(uri))
    -- Stable across calls: stored in the buffer variable.
    assert.are.equal(uri, uri_mod.for_bufnr(bufnr))
    assert.are.equal(uri, vim.b[bufnr].pjollrig_ephemeral_uri)
    -- And resolvable back to the owning buffer.
    assert.are.equal(bufnr, uri_mod.bufnr_for_uri(uri))
    -- An ephemeral URI no buffer owns resolves to nothing.
    assert.is_nil(uri_mod.bufnr_for_uri("manicule://buffer/none/999"))
  end)
end)
