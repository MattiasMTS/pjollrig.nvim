local H = require("helpers")

local ctx

---A pair with a long unchanged tail so fold behaviour is observable:
---line 2 is modified, line 3 of the baseline is deleted, then 20
---identical lines follow.
local function make_pair()
  local left = ctx.artifact_root .. "/left/big.lua"
  local right = ctx.root .. "/big.lua"
  local baseline = { "local a = 1", "local b = 2", "local gone = 3" }
  local current = { "local a = 1", "local b = 22" }
  for i = 1, 20 do
    table.insert(baseline, ("-- tail %d"):format(i))
    table.insert(current, ("-- tail %d"):format(i))
  end
  vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
  vim.fn.writefile(baseline, left)
  vim.fn.writefile(current, right)
  return { { left = left, right = right, status = "M", path = "big.lua" } }
end

---A single-file pair with explicit contents, for intra-line diff tests.
local function make_custom_pair(name, baseline, current)
  local left = ctx.artifact_root .. "/left/" .. name
  local right = ctx.root .. "/" .. name
  vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
  vim.fn.writefile(baseline, left)
  vim.fn.writefile(current, right)
  return { { left = left, right = right, status = "M", path = name } }
end

local function inline_marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, require("pjollrig.review.inline").ns, 0, -1, { details = true })
end

---Every PjollrigDiffWordAdded span mark in the buffer, as {row, col, end_col}.
local function word_marks(bufnr)
  local marks = {}
  for _, mark in ipairs(inline_marks(bufnr)) do
    if mark[4].hl_group == "PjollrigDiffWordAdded" then
      table.insert(marks, { row = mark[2], col = mark[3], end_col = mark[4].end_col })
    end
  end
  return marks
end

---The single non-panel window of the session tab.
local function file_window()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(winid)].filetype ~= "pjollrig-panel" then
      return winid
    end
  end
end

describe("pjollrig review unified mode", function()
  before_each(function()
    -- fold_unchanged defaults to false; the fold tests below opt in.
    ctx = H.setup({ review = { diff_mode = "unified", fold_unchanged = true } })
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("opens one window on the real worktree file, with no diff mode", function()
    local R = require("pjollrig.review")
    local files = make_pair()
    assert.is_true(R.start({ files = files, label = "unified" }))

    local wins = vim.api.nvim_tabpage_list_wins(0)
    -- 2 windows: the file + the panel (split mode would be 3).
    assert.are.equal(2, #wins)

    local winid = file_window()
    local bufnr = vim.api.nvim_win_get_buf(winid)
    assert.is_false(vim.wo[winid].diff)
    -- The buffer IS the worktree file, so it stays writable and comments
    -- anchor without any diff→file line translation.
    assert.are.equal(files[1].right, vim.api.nvim_buf_get_name(bufnr))
    assert.is_true(vim.bo[bufnr].modifiable)
    assert.is_true(require("pjollrig.review.inline").is_active(bufnr))
  end)

  it("highlights added lines and draws removed lines as virtual text", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    local bufnr = vim.api.nvim_win_get_buf(file_window())

    local added_rows, removed = {}, {}
    for _, mark in ipairs(inline_marks(bufnr)) do
      local row, details = mark[2], mark[4]
      if details.line_hl_group == "PjollrigDiffAdd" then
        added_rows[row] = true
      end
      for _, virt_line in ipairs(details.virt_lines or {}) do
        -- chunk 1 is the gutter marker, chunk 2 the baseline text.
        assert.are.equal("PjollrigDiffDeleteSign", virt_line[1][2])
        assert.are.equal("PjollrigDiffDelete", virt_line[2][2])
        removed[virt_line[2][1]] = { row = row, above = details.virt_lines_above == true }
      end
    end

    -- Row 1 (0-indexed) is `local b = 22`, the modified line.
    assert.is_true(added_rows[1], "modified line is not highlighted as added")
    assert.is_nil(added_rows[0], "unchanged line 1 must not be highlighted")
    -- The replaced baseline line renders directly above its replacement;
    -- the outright-deleted line renders below the line it followed. Both
    -- anchor on row 1, so assert placement rather than extmark order.
    assert.are.same({ row = 1, above = true }, removed["local b = 2"])
    assert.are.same({ row = 1, above = false }, removed["local gone = 3"])
  end)

  it("emphasizes only the changed span of a modified line", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    local bufnr = vim.api.nvim_win_get_buf(file_window())

    -- `local b = 2` → `local b = 22`: only the appended `2` differs, so
    -- the word mark covers byte cols 11..12 of row 1 — not the whole line.
    assert.are.same({ { row = 1, col = 11, end_col = 12 } }, word_marks(bufnr))
  end)

  it("puts no word-span mark on pure added lines", function()
    local R = require("pjollrig.review")
    local files = make_custom_pair("added.lua", { "local a = 1" }, { "local a = 1", "local added = true" })
    assert.is_true(R.start({ files = files, label = "unified" }))
    local bufnr = vim.api.nvim_win_get_buf(file_window())

    local added_rows = {}
    for _, mark in ipairs(inline_marks(bufnr)) do
      if mark[4].line_hl_group == "PjollrigDiffAdd" then
        added_rows[mark[2]] = true
      end
    end
    assert.is_true(added_rows[1], "pure added line lost its line highlight")
    assert.are.same({}, word_marks(bufnr))
  end)

  it("splits the removed virtual line around the changed span", function()
    local R = require("pjollrig.review")
    local files = make_custom_pair("word.lua", { "return alpha" }, { "return omega" })
    assert.is_true(R.start({ files = files, label = "unified" }))
    local bufnr = vim.api.nvim_win_get_buf(file_window())

    local virt_lines
    for _, mark in ipairs(inline_marks(bufnr)) do
      virt_lines = virt_lines or mark[4].virt_lines
    end
    assert.is_truthy(virt_lines, "removed line was not drawn")
    -- Common prefix "return " and suffix "a" trim away; "alph" is the
    -- differing middle and carries the emphasis chunk.
    local chunks = virt_lines[1]
    assert.are.same({ "return ", "PjollrigDiffDelete" }, { chunks[2][1], chunks[2][2] })
    assert.are.same({ "alph", "PjollrigDiffWordRemoved" }, { chunks[3][1], chunks[3][2] })
    assert.are.same({ "a", "PjollrigDiffDelete" }, { chunks[4][1], chunks[4][2] })
    -- The worktree side gets the matching span over "omeg".
    assert.are.same({ { row = 0, col = 7, end_col = 11 } }, word_marks(bufnr))
  end)

  it("skips word-level emphasis for very long lines", function()
    local R = require("pjollrig.review")
    local long = string.rep("x", 600)
    local files = make_custom_pair("long.lua", { long .. "a" }, { long .. "b" })
    assert.is_true(R.start({ files = files, label = "unified" }))
    local bufnr = vim.api.nvim_win_get_buf(file_window())

    assert.are.same({}, word_marks(bufnr))
    for _, mark in ipairs(inline_marks(bufnr)) do
      for _, virt_line in ipairs(mark[4].virt_lines or {}) do
        -- Sign + one whole-line chunk: the removed line stays unsplit.
        assert.are.equal(2, #virt_line)
      end
    end
  end)

  it("keeps comments anchored to real worktree line numbers", function()
    local R = require("pjollrig.review")
    local files = make_pair()
    assert.is_true(R.start({ files = files, label = "unified" }))

    vim.api.nvim_set_current_win(file_window())
    -- Comment on line 2, the modified line.
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local ui = require("pjollrig.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("on the changed line")
    end
    require("pjollrig").add()
    ui.prompt = original_prompt

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    -- Stored 0-indexed against the worktree file, NOT against a
    -- synthetic diff buffer: row 1 == file line 2.
    assert.are.equal(1, records[1].range.start[1])
    assert.are.equal(files[1].right, vim.uri_to_fname(records[1].uri))
  end)

  it("folds the unchanged tail and leaves the hunk visible", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    vim.api.nvim_set_current_win(file_window())

    assert.are.equal("expr", vim.wo.foldmethod)
    -- Lines 1-2 are the hunk plus context; the tail collapses.
    assert.are.equal(-1, vim.fn.foldclosed(1))
    assert.are.equal(-1, vim.fn.foldclosed(2))
    assert.is_true(vim.fn.foldclosed(20) > 0, "unchanged tail did not fold")
  end)

  it("renders the fold line as an unmodified-lines bar", function()
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "unified", fold_unchanged = true, context = 0 },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    vim.api.nvim_set_current_win(file_window())

    -- With zero context only line 2 stays out; lines 3..22 fold as one
    -- 20-line block whose fold line reads like Pierre's bar.
    assert.is_true(vim.fn.foldclosed(3) > 0, "unchanged tail did not fold")
    local text = vim.fn.foldtextresult(3)
    assert.is_truthy(text:find("20 unmodified lines ▸", 1, true), "unexpected fold text: " .. text)
  end)

  it("arms the foldexpr through an eagerly-resolved global", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    vim.api.nvim_set_current_win(file_window())

    -- 'foldexpr' is evaluated per line on every fold recompute; going
    -- through v:lua.require'...' paid a package.loaded lookup per line.
    assert.are.equal("v:lua.__pjollrig_inline_foldexpr(v:lnum)", vim.wo.foldexpr)
    assert.are.equal("function", type(_G.__pjollrig_inline_foldexpr))
    assert.are.equal("function", type(_G.__pjollrig_inline_foldtext))
    -- Same fold behavior as before the indirection change.
    assert.is_true(vim.fn.foldclosed(20) > 0, "unchanged tail did not fold")

    R.stop()
    assert.is_nil(_G.__pjollrig_inline_foldexpr)
    assert.is_nil(_G.__pjollrig_inline_foldtext)
  end)

  it("does not fold when review.context is disabled by fold_unchanged", function()
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "unified", fold_unchanged = false },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    vim.api.nvim_set_current_win(file_window())

    assert.are_not.equal("expr", vim.wo.foldmethod)
    assert.are.equal(-1, vim.fn.foldclosed(20))
  end)

  it("does not fold by default (fold_unchanged defaults to false)", function()
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "unified" },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    vim.api.nvim_set_current_win(file_window())

    assert.are_not.equal("expr", vim.wo.foldmethod)
    assert.are.equal(-1, vim.fn.foldclosed(20))
  end)

  it("split mode drops the native diff folds by default", function()
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "split" },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "split" }))

    local diff_wins = 0
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[winid].diff then
        diff_wins = diff_wins + 1
        assert.is_false(vim.wo[winid].foldenable)
      end
    end
    assert.are.equal(2, diff_wins)
  end)

  it("split mode upgrades the default inline:simple diffopt for the session", function()
    local saved = vim.o.diffopt
    vim.o.diffopt = saved:gsub("inline:%w+", "inline:simple")
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "split" },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "split" }))
    assert.is_truthy(vim.o.diffopt:find("inline:word", 1, true))
    R.stop()
    assert.is_truthy(vim.o.diffopt:find("inline:simple", 1, true))
    vim.o.diffopt = saved
  end)

  it("split mode respects a user-chosen inline diffopt variant", function()
    local saved = vim.o.diffopt
    vim.o.diffopt = saved:gsub("inline:%w+", "inline:char")
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "split" },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "split" }))
    assert.is_truthy(vim.o.diffopt:find("inline:char", 1, true))
    R.stop()
    vim.o.diffopt = saved
  end)

  it("split mode keeps native diff folds when fold_unchanged is on", function()
    require("pjollrig").setup({
      store = { dir = ctx.state .. "/", format = "json", canonicalize_symlinks = false, poll_interval_ms = 0 },
      review = { diff_mode = "split", fold_unchanged = true },
    })
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "split" }))

    local folding_wins = 0
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[winid].diff and vim.wo[winid].foldenable then
        folding_wins = folding_wins + 1
      end
    end
    assert.are.equal(2, folding_wins)
  end)

  it("maps ]h / [h to walk hunks and unmaps them on stop", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    vim.api.nvim_set_current_win(file_window())
    local bufnr = vim.api.nvim_get_current_buf()

    local function buf_map(lhs)
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if map.lhs == lhs then
          return map
        end
      end
    end
    assert.is_truthy(buf_map("]h"), "]h not mapped")
    assert.is_truthy(buf_map("[h"), "[h not mapped")

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("pjollrig.review.inline").next_hunk()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])

    R.stop()
    assert.is_nil(buf_map("]h"), "]h leaked past stop()")
  end)

  it("repaints on next()/prev() and drops the previous file's paint", function()
    local R = require("pjollrig.review")
    local files = make_pair()
    local second_left = ctx.artifact_root .. "/left/other.lua"
    local second_right = ctx.root .. "/other.lua"
    vim.fn.writefile({ "return 1" }, second_left)
    vim.fn.writefile({ "return 2" }, second_right)
    table.insert(files, { left = second_left, right = second_right, status = "M", path = "other.lua" })

    assert.is_true(R.start({ files = files, label = "unified" }))
    local first = vim.fn.bufnr(files[1].right)
    assert.is_true(#inline_marks(first) > 0)

    R.next()
    local second = vim.api.nvim_win_get_buf(file_window())
    assert.are.equal(files[2].right, vim.api.nvim_buf_get_name(second))
    assert.is_true(#inline_marks(second) > 0, "second file was not painted")
    -- The first file is off screen; its paint (and hunk maps) must go too.
    assert.are.equal(0, #inline_marks(first), "first file kept its paint")
    assert.is_false(require("pjollrig.review.inline").is_active(first))
  end)

  it("stop() removes the inline paint from the worktree buffer", function()
    local R = require("pjollrig.review")
    local files = make_pair()
    assert.is_true(R.start({ files = files, label = "unified" }))
    local bufnr = vim.fn.bufnr(files[1].right)
    assert.is_true(#inline_marks(bufnr) > 0)

    R.stop()
    assert.are.equal(0, #inline_marks(bufnr))
    assert.is_false(require("pjollrig.review.inline").is_active(bufnr))
  end)

  it("set_diff_mode flips the live session between unified and split", function()
    local R = require("pjollrig.review")
    assert.is_true(R.start({ files = make_pair(), label = "unified" }))
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))

    assert.are.equal("split", R.set_diff_mode())
    -- Split mode: baseline + worktree + panel.
    assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
    local bufnr = vim.fn.bufnr(R.state().files[1].right)
    assert.are.equal(0, #inline_marks(bufnr), "inline paint survived the switch to split")

    assert.are.equal("unified", R.set_diff_mode())
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_true(#inline_marks(vim.fn.bufnr(R.state().files[1].right)) > 0)
  end)

  it("rejects an unknown diff mode without changing the current one", function()
    local R = require("pjollrig.review")
    local mode, err = R.set_diff_mode("sideways")
    assert.is_nil(mode)
    assert.is_truthy(err:find("split", 1, true))
    assert.are.equal("unified", require("pjollrig.config").get().review.diff_mode)
  end)
end)
