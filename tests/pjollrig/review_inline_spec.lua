local inline = require("pjollrig.review.inline")

describe("review inline diff computation", function()
  it("reports a modification as removed baseline lines plus new lines", function()
    local baseline = { "one", "two", "three", "four" }
    local current = { "one", "TWO", "three", "four" }
    local hunks = inline.hunks(baseline, current)

    assert.are.equal(1, #hunks)
    assert.are.equal(2, hunks[1].new_start)
    assert.are.equal(1, hunks[1].new_count)
    assert.are.same({ "two" }, hunks[1].removed)
  end)

  it("reports a pure addition with no removed lines", function()
    local baseline = { "one", "three" }
    local current = { "one", "two", "three" }
    local hunks = inline.hunks(baseline, current)

    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].old_count)
    assert.are.equal(2, hunks[1].new_start)
    assert.are.equal(1, hunks[1].new_count)
    assert.are.same({}, hunks[1].removed)
  end)

  it("reports a pure deletion with new_count 0 and the removed text", function()
    local baseline = { "one", "two", "three" }
    local current = { "one", "three" }
    local hunks = inline.hunks(baseline, current)

    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].new_count)
    -- `vim.diff` anchors a deletion after the surviving line before it.
    assert.are.equal(1, hunks[1].new_start)
    assert.are.same({ "two" }, hunks[1].removed)
  end)

  it("reports a deletion at the top of the file with new_start 0", function()
    local hunks = inline.hunks({ "zero", "one" }, { "one" })

    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].new_count)
    assert.are.equal(0, hunks[1].new_start)
    assert.are.same({ "zero" }, hunks[1].removed)
  end)

  it("returns no hunks for identical content", function()
    assert.are.same({}, inline.hunks({ "a", "b" }, { "a", "b" }))
  end)

  -- An added file's staged baseline is an empty file, which `readfile`
  -- returns as `{}` and a buffer reports as `{""}`. Both must diff as a
  -- clean all-add, with no phantom removed blank line.
  it("treats an empty baseline as an all-added file", function()
    for _, baseline in ipairs({ {}, { "" } }) do
      local hunks = inline.hunks(baseline, { "a", "b" })
      assert.are.equal(1, #hunks)
      assert.are.equal(0, hunks[1].old_count)
      assert.are.equal(1, hunks[1].new_start)
      assert.are.equal(2, hunks[1].new_count)
      assert.are.same({}, hunks[1].removed)
    end
  end)

  it("treats an emptied file as an all-removed file", function()
    local hunks = inline.hunks({ "a", "b" }, { "" })
    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].new_count)
    assert.are.same({ "a", "b" }, hunks[1].removed)
  end)
end)

describe("review inline fold rows", function()
  it("keeps the hunk plus context lines out of folds", function()
    local hunks = { { old_start = 10, old_count = 1, new_start = 10, new_count = 2, removed = { "x" } } }
    local keep = inline.keep_rows(hunks, 40, 3)

    for row = 7, 14 do
      assert.is_true(keep[row], ("row %d should stay visible"):format(row))
    end
    assert.is_nil(keep[6])
    assert.is_nil(keep[15])
  end)

  it("keeps the anchor line of a pure deletion so its virtual lines show", function()
    local hunks = { { old_start = 5, old_count = 2, new_start = 4, new_count = 0, removed = { "x", "y" } } }
    local keep = inline.keep_rows(hunks, 40, 1)

    assert.is_true(keep[3])
    assert.is_true(keep[4])
    assert.is_true(keep[5])
    assert.is_nil(keep[6])
  end)

  it("clamps context to the file bounds", function()
    local hunks = { { old_start = 1, old_count = 0, new_start = 1, new_count = 1, removed = {} } }
    local keep = inline.keep_rows(hunks, 2, 5)

    assert.is_true(keep[1])
    assert.is_true(keep[2])
    assert.is_nil(keep[0])
    assert.is_nil(keep[3])
  end)
end)

describe("review inline buffer lifecycle", function()
  it("drops a wiped buffer's state mid-session", function()
    local baseline = vim.fn.tempname()
    vim.fn.writefile({ "one", "two" }, baseline)
    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO" })
    assert.is_true(inline.apply(bufnr, baseline, { fold = false }))
    assert.is_true(inline.is_active(bufnr))

    -- Wiping the buffer directly (not via clear_all at session end) must
    -- reap its state entry, or a long session pins every dead buffer's
    -- hunk tables until it stops.
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_false(inline.is_active(bufnr))
    vim.fn.delete(baseline)
  end)
end)
