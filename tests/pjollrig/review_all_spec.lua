local H = require("helpers")
local review = require("pjollrig.review")
local all = require("pjollrig.review.all")
local ctx, buf

local function pair(name, before, after, status)
  local left = ctx.artifact_root .. "/base/" .. name
  vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
  vim.fn.writefile(before, left)
  return { left = left, right = H.write_project_file(ctx, name, after), path = name, status = status or "M" }
end

local function drain()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert.is_true(vim.wait(2000, function()
    return done
  end))
end

local function start(files)
  assert.is_true(review.start({ files = files, label = "all files" }))
  buf = vim.api.nvim_get_current_buf()
  assert.is_true(vim.wait(3000, function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "Loading all files…"
  end))
end

local function row(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(text, 1, true) then
      return i
    end
  end
  error("missing review row: " .. text)
end

local function at(text)
  vim.api.nvim_win_set_cursor(0, { row(text), 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "mx", false)
end

local function comments()
  return require("pjollrig").list(nil, { root = ctx.root })
end

describe("all-files review", function()
  before_each(function()
    ctx = H.setup({ review = { file_mode = "all" } })
  end)
  after_each(function()
    review.stop()
    drain()
    H.teardown(ctx)
  end)

  it("stacks files with original line numbers and keeps one review buffer", function()
    local a = pair("a.lua", { "one", "old", "three" }, { "one", "new", "three" })
    local b = pair("b.lua", {}, { "added" }, "A")
    start({ a, b })
    assert.are.equal("pjollrig-review-all", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(row("a.lua") < row("b.lua"))
    assert.is_truthy(vim.api.nvim_buf_get_lines(buf, row("+ new") - 1, row("+ new"), false)[1]:match("2 %+ new$"))
    review.open_pair(2)
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(row("+ added"), vim.api.nvim_win_get_cursor(0)[1])
    assert.is_truthy(vim.wo.winbar:find("b.lua", 1, true))
  end)

  it("uses one highlight range per changed run without spilling into context or the next file", function()
    start({
      pair("a.lua", { "context", "old-a", "old-b", "tail" }, { "context", "new-a", "new-b", "tail" }),
      pair("b.lua", {}, { "added-a", "added-b", "added-c" }, "A"),
    })
    local spans = {}
    local marks =
      vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().pjollrig_review_all, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      spans[#spans + 1] = { mark[2] + 1, mark[4].end_row + 1, mark[4].line_hl_group }
    end
    assert.are.same({
      { row("a.lua"), row("a.lua"), "Title" },
      { row("- old-a"), row("- old-b"), "DiffDelete" },
      { row("+ new-a"), row("+ new-b"), "DiffAdd" },
      { row("b.lua"), row("b.lua"), "Title" },
      { row("+ added-a"), row("+ added-c"), "DiffAdd" },
    }, spans)
  end)

  it("moves across hunks and file boundaries with wrap", function()
    start({ pair("a.lua", { "old-a" }, { "new-a" }), pair("b.lua", { "old-b" }, { "new-b" }) })
    assert.are.equal(row("- old-a"), vim.api.nvim_win_get_cursor(0)[1])
    press("]h")
    assert.are.equal(row("- old-b"), vim.api.nvim_win_get_cursor(0)[1])
    assert.are.equal(2, review.state().index)
    press("]h")
    assert.are.equal(row("- old-a"), vim.api.nvim_win_get_cursor(0)[1])
    press("[h")
    assert.are.equal(row("- old-b"), vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("maps added and context comments to real URI, range and excerpt", function()
    local a = pair("a.lua", { "one", "old", "three" }, { "one", "new", "three" })
    start({ a, pair("b.lua", {}, { "first", "second" }, "A") })
    at("+ new")
    require("pjollrig").add({ body = "check this" })
    local saved = comments()[1]
    assert.are.equal(require("pjollrig.uri").for_path(a.right), saved.uri)
    assert.are.same({ start = { 1, 0 }, end_ = { 1, 0 } }, saved.range)
    assert.are.equal("new", saved.meta.excerpt)
    assert.are.equal("project", saved.scope)
    at("+ second")
    require("pjollrig").add({ body = "other file" })
    assert.are.equal(2, #comments())
    -- Synthetic extmarks are never editable-source anchors or persisted positions.
    require("pjollrig").list()
    assert.are.same({ start = { 1, 0 }, end_ = { 1, 0 } }, comments()[1].range)
    drain()
    local marks = vim.api.nvim_buf_get_extmarks(
      buf,
      vim.api.nvim_get_namespaces().pjollrig_review_all_comments,
      0,
      -1,
      { details = true }
    )
    assert.are.equal(2, #marks)
  end)

  it("maps visual byte columns and multiline working-side ranges", function()
    local a = pair("a.lua", {}, { "alpha", "beta", "gamma" }, "A")
    start({ a })
    local first, last = row("+ alpha"), row("+ beta")
    local line = vim.api.nvim_buf_get_lines(buf, first - 1, first, false)[1]
    local prefix = line:find("alpha", 1, true) - 1
    require("pjollrig").add({
      body = "range",
      range = { start = { first - 1, prefix + 1 }, end_ = { last - 1, prefix + 3 } },
    })
    assert.are.same({ start = { 0, 1 }, end_ = { 1, 3 } }, comments()[1].range)
  end)

  it("rejects headers, deleted lines and selections spanning files or sides", function()
    start({ pair("a.lua", { "old" }, { "new" }), pair("b.lua", {}, { "added" }, "A") })
    for _, text in ipairs({ "a.lua", "- old" }) do
      at(text)
      require("pjollrig").add({ body = "invalid" })
    end
    require("pjollrig").add({ body = "invalid", range = { row("+ new"), row("+ added") } })
    require("pjollrig").add({ body = "invalid", range = { row("- old"), row("+ new") } })
    assert.are.equal(0, #comments())
  end)

  it("rejects stale source content and accepts it after refresh", function()
    local a = pair("a.lua", { "old" }, { "new" })
    start({ a })
    at("+ new")
    vim.fn.writefile({ "changed" }, a.right)
    require("pjollrig").add({ body = "stale" })
    assert.are.equal(0, #comments())
    all.refresh()
    drain()
    at("+ changed")
    require("pjollrig").add({ body = "fresh" })
    assert.are.equal(1, #comments())
  end)

  it("captures the source before a prompt and rejects later edits", function()
    local a = pair("a.lua", {}, { "new-a" }, "A")
    start({ a, pair("b.lua", {}, { "new-b" }, "A") })
    local ui, callback = require("pjollrig.ui"), nil
    local original = ui.prompt
    ui.prompt = function(_, cb)
      callback = cb
    end
    at("+ new-a")
    require("pjollrig").add()
    ui.prompt = original
    at("+ new-b")
    callback("belongs to a")
    assert.are.equal(require("pjollrig.uri").for_path(a.right), comments()[1].uri)
    at("+ new-a")
    ui.prompt = function(_, cb)
      callback = cb
    end
    require("pjollrig").add()
    ui.prompt = original
    vim.api.nvim_buf_set_lines(vim.fn.bufnr(a.right), 0, -1, false, { "changed" })
    callback("stale")
    assert.are.equal(1, #comments())
  end)

  it("handles pure deletions, additions at EOF and unchanged coordinates", function()
    start({ pair("a.lua", { "gone", "one", "two", "gone-too" }, { "one", "two", "end" }) })
    local target = assert(all.comment_target(buf, { start = { row("  one") - 1, 0 }, end_ = { row("  two") - 1, 0 } }))
    assert.are.same({ start = { 0, 0 }, end_ = { 1, 0 } }, target.range)
    local final = assert(all.comment_target(buf, { start = { row("+ end") - 1, 0 }, end_ = { row("+ end") - 1, 0 } }))
    assert.are.equal(2, final.range.start[1])
  end)

  it("shows deleted, binary, empty and document files without invalid mappings", function()
    local doc = pair("notes.md", {}, { "document" }, "doc")
    doc.left = nil
    local binary = pair("image.bin", {}, {}, "A")
    local file = assert(io.open(binary.right, "wb"))
    file:write("a\0b")
    file:close()
    start({ pair("deleted.lua", { "removed" }, {}, "D"), binary, pair("empty.lua", {}, {}, "A"), doc })
    assert.is_truthy(row("- removed"))
    assert.is_truthy(row("Binary file"))
    assert.is_truthy(row("No text changes"))
    at("document")
    require("pjollrig").add({ body = "doc comment" })
    assert.are.equal(1, #comments())
    assert.are.equal(0, comments()[1].range.start[1])
  end)

  it("folds file sections and opens them on explicit navigation", function()
    start({ pair("a.lua", { "a", "b" }, { "A", "b" }), pair("b.lua", {}, { "second" }, "A") })
    at("a.lua")
    press("za")
    assert.are.equal(row("a.lua"), vim.fn.foldclosed(row("+ A")))
    review.open_pair(1)
    assert.are.equal(-1, vim.fn.foldclosed(row("+ A")))
  end)

  it("switches back to the preferred per-file mode and cleans up", function()
    start({ pair("a.lua", { "old" }, { "new" }) })
    assert.are.equal("single", review.set_file_mode("single"))
    assert.is_true(vim.wo.diff)
    drain()
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_nil(_G.__pjollrig_all_foldexpr)
    review.set_file_mode("all")
    assert.is_true(all.is_active(vim.api.nvim_get_current_buf()))
  end)

  it("opens the real source with gf without replacing the review", function()
    local a = pair("a.lua", {}, { "first", "second" }, "A")
    start({ a })
    local review_tab = vim.api.nvim_get_current_tabpage()
    at("+ second")
    press("gf")
    assert.are.equal(a.right, vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(vim.bo.modifiable)
    vim.api.nvim_set_current_tabpage(review_tab)
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
  end)

  it("stops safely while a build is pending", function()
    assert.is_true(review.start({ files = { pair("a.lua", {}, { "new" }, "A") } }))
    local pending = vim.api.nvim_get_current_buf()
    review.stop()
    drain()
    assert.is_false(vim.api.nvim_buf_is_valid(pending))
    assert.is_nil(_G.__pjollrig_all_foldexpr)
  end)

  it("uses the Files panel as an outline even for files with comments", function()
    start({ pair("a.lua", {}, { "first" }, "A"), pair("b.lua", {}, { "second" }, "A") })
    at("+ second")
    require("pjollrig").add({ body = "existing comment" })
    drain()
    review.open_pair(1)
    local panel = require("pjollrig.review.panel")
    vim.api.nvim_set_current_win(panel.winid())
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("<CR>")
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(row("+ second"), vim.api.nvim_win_get_cursor(0)[1])
    panel.open_comments()
    vim.api.nvim_set_current_win(panel.winid())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press("<CR>")
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(row("+ second"), vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("exports only real file coordinates and updates comment annotations", function()
    local a = pair("a.lua", {}, { "first", "second" }, "A")
    start({ a })
    at("+ second")
    require("pjollrig").add({ body = "send me" })
    -- Opt out of the default auto-clear: the delete below exercises the
    -- annotation cleanup on a record that must still exist.
    local calls = H.register_fake_sink("capture", { clear_on_success = false })
    assert.is_true(review.finish({ sink = "capture" }))
    assert.are.equal(1, #calls)
    assert.are.equal(require("pjollrig.uri").for_path(a.right), calls[1].comments[1].uri)
    assert.are.equal(1, calls[1].comments[1].range.start[1])
    local id = comments()[1].id
    require("pjollrig").delete(id)
    local marks =
      vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().pjollrig_review_all_comments, 0, -1, {})
    assert.are.equal(0, #marks)
  end)

  it("rejects disk edits even when a loaded source buffer still has old text", function()
    local a = pair("a.lua", {}, { "original" }, "A")
    start({ a })
    at("+ original")
    require("pjollrig").add({ body = "first" })
    vim.fn.writefile({ "external change" }, a.right)
    require("pjollrig").add({ body = "stale" })
    assert.are.equal(1, #comments())
  end)

  it("opens the source without leaking review fold expressions or number options", function()
    start({ pair("a.lua", {}, { "code" }, "A") })
    at("+ code")
    press("gf")
    assert.are_not.equal("v:lua.__pjollrig_all_foldexpr()", vim.wo.foldexpr)
    review.stop()
    drain()
    assert.is_nil(_G.__pjollrig_all_foldexpr)
    -- Redraw/evaluate folds after teardown: no dangling Lua callback.
    vim.cmd("normal! zx")
  end)

  it("folds unchanged context while retaining file-level folds", function()
    require("pjollrig.config").get().review.fold_unchanged = true
    require("pjollrig.config").get().review.context = 1
    local before, after = {}, {}
    for i = 1, 30 do
      before[i], after[i] = "line " .. i, "line " .. i
    end
    after[15] = "changed middle"
    start({ pair("a.lua", before, after) })
    assert.is_true(vim.fn.foldclosed(row("line 2")) > 0)
    assert.are.equal(-1, vim.fn.foldclosed(row("+ changed middle")))
    assert.are.equal(-1, vim.fn.foldclosed(row("line 14")))
    at("a.lua")
    press("za")
    assert.are.equal(row("a.lua"), vim.fn.foldclosed(row("+ changed middle")))
  end)

  it("coalesces annotation event bursts and cancels a queued update on stop", function()
    start({ pair("a.lua", {}, { "code" }, "A") })
    drain()
    local original, calls = all.refresh_comments, 0
    all.refresh_comments = function()
      calls = calls + 1
      return original()
    end
    for _ = 1, 20 do
      vim.api.nvim_exec_autocmds("User", { pattern = "PjollrigDeleted" })
    end
    drain()
    local after_burst = calls
    vim.api.nvim_exec_autocmds("User", { pattern = "PjollrigDeleted" })
    review.stop()
    drain()
    all.refresh_comments = original
    assert.are.equal(1, after_burst)
    assert.are.equal(after_burst, calls)
  end)

  it("reads an unloaded source only once when rebuilding", function()
    local a = pair("a.lua", {}, { "code" }, "A")
    start({ a })
    drain()
    local original, reads = vim.fn.readfile, 0
    vim.fn.readfile = function(path, ...)
      if path == a.right then
        reads = reads + 1
      end
      return original(path, ...)
    end
    all.refresh()
    drain()
    vim.fn.readfile = original
    assert.are.equal(1, reads)
  end)

  it("does not persist a pending comment after review teardown", function()
    start({ pair("a.lua", {}, { "code" }, "A") })
    at("+ code")
    local ui, callback = require("pjollrig.ui"), nil
    local original = ui.prompt
    ui.prompt = function(_, cb)
      callback = cb
    end
    require("pjollrig").add()
    ui.prompt = original
    review.stop()
    callback("late comment")
    assert.are.equal(0, #comments())
  end)

  it("recovers from a wiped review buffer", function()
    start({ pair("a.lua", {}, { "code" }, "A") })
    vim.api.nvim_buf_delete(buf, { force = true })
    review.open_pair(1)
    buf = vim.api.nvim_get_current_buf()
    drain()
    assert.is_true(all.is_active(buf))
    at("+ code")
    require("pjollrig").add({ body = "after recovery" })
    assert.are.equal(1, #comments())
  end)

  for _, action in ipairs({ "rename", "wipe" }) do
    it("rejects a pending comment when the captured source buffer is changed: " .. action, function()
      local a = pair("a.lua", {}, { "code" }, "A")
      start({ a })
      at("+ code")
      local ui, callback = require("pjollrig.ui"), nil
      local original = ui.prompt
      ui.prompt = function(_, cb)
        callback = cb
      end
      require("pjollrig").add()
      ui.prompt = original
      local source = vim.fn.bufnr(a.right)
      if action == "rename" then
        vim.api.nvim_buf_set_name(source, ctx.root .. "/renamed.lua")
      else
        vim.api.nvim_buf_delete(source, { force = true })
      end
      callback("must not follow the buffer")
      assert.are.equal(0, #comments())
    end)
  end

  it("clears fold callbacks from a cloned review window in another tab", function()
    start({ pair("a.lua", {}, { "code" }, "A") })
    vim.cmd("tab split")
    local clone = vim.api.nvim_get_current_win()
    review.stop()
    assert.are_not.equal("v:lua.__pjollrig_all_foldexpr()", vim.wo[clone].foldexpr)
    vim.api.nvim_win_call(clone, function()
      vim.cmd("normal! zx")
    end)
    drain()
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("registers and validates the file-mode command", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    vim.cmd("PjollrigReviewFiles single")
    assert.are.equal("single", require("pjollrig.config").get().review.file_mode)
    vim.cmd("PjollrigReviewFiles")
    assert.are.equal("all", require("pjollrig.config").get().review.file_mode)
    local ok = pcall(require("pjollrig.config").setup, { review = { file_mode = "invalid" } })
    assert.is_false(ok)
  end)
end)
