-- Continuous, read-only review. Display rows never become stored coordinates.
local M = {}
local ns = vim.api.nvim_create_namespace("pjollrig_review_all")
local comments_ns = vim.api.nvim_create_namespace("pjollrig_review_all_comments")
local active

local function clean(text)
  return (tostring(text):gsub("%c", " "))
end

local function read(path, loaded)
  if not path then
    return {}
  end
  local buf = vim.fn.bufnr(path)
  if loaded and buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return #lines == 1 and lines[1] == "" and {} or lines
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

-- Keep disk and editor snapshots distinct, but read an unloaded file once.
local function read_source(path)
  local disk = read(path, false)
  local buf = vim.fn.bufnr(path)
  local working = buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and read(path, true) or disk
  return working, disk
end

local function binary(lines)
  for _, line in ipairs(lines or {}) do
    -- readfile represents embedded NUL bytes as newlines inside a list item.
    if line:find("[\n%z]") then
      return true
    end
  end
  return false
end

local function append(model, section, text, row)
  row = row or {}
  row.file = section.index
  model.lines[#model.lines + 1] = text
  model.rows[#model.rows + 1] = row
  return #model.lines
end

local function add_file(model, pair, index, cfg)
  local section = { index = index, pair = pair, new_rows = {}, old_rows = {}, hunks = {} }
  model.sections[index] = section
  section.header = append(model, section, "", { kind = "header", fold = ">1" })
  local left = pair.status == "A" and {} or read(pair.left, false)
  local right, disk = {}, {}
  if pair.status ~= "D" then
    right, disk = read_source(pair.right)
  end
  section.snapshot, section.disk_snapshot = right, disk
  local added, removed = 0, 0
  local function code(kind, old_line, new_line, text)
    local prefix = ("%6s %6s %s "):format(old_line or "", new_line or "", kind)
    local row = append(model, section, prefix .. text, {
      kind = kind,
      old_line = old_line,
      new_line = new_line,
      prefix = #prefix,
      fold = 1,
    })
    if new_line then
      section.new_rows[new_line] = row
    end
    if old_line then
      section.old_rows[old_line] = row
    end
    return row
  end
  if not left or not right then
    append(model, section, "  Cannot read this file; refresh after it becomes available.", { fold = 1 })
  elseif binary(left) or binary(right) then
    append(model, section, "  Binary file", { fold = 1 })
    section.snapshot = nil
  else
    local hunks = pair.status == "doc" and {} or require("pjollrig.review.inline").hunks(left, right)
    local old, new = 1, 1
    for _, hunk in ipairs(hunks) do
      local before = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
      while new <= before do
        code(" ", old, new, right[new])
        old, new = old + 1, new + 1
      end
      local first = #model.lines + 1
      for i = 0, hunk.old_count - 1 do
        code("-", hunk.old_start + i, nil, left[hunk.old_start + i])
      end
      for i = 0, hunk.new_count - 1 do
        code("+", nil, hunk.new_start + i, right[hunk.new_start + i])
      end
      removed, added = removed + hunk.old_count, added + hunk.new_count
      old = hunk.old_start + hunk.old_count + (hunk.old_count == 0 and 1 or 0)
      new = hunk.new_start + hunk.new_count + (hunk.new_count == 0 and 1 or 0)
      local h = { first = first, last = #model.lines }
      section.hunks[#section.hunks + 1] = h
      model.hunks[#model.hunks + 1] = first
    end
    while new <= #right do
      code(" ", pair.status ~= "doc" and old or nil, new, right[new])
      old, new = old + 1, new + 1
    end
    if #model.lines == section.header then
      append(model, section, "  No text changes", { fold = 1 })
    end
    -- Keep context around each hunk; unchanged runs become nested folds.
    if cfg.fold_unchanged and pair.status ~= "doc" then
      local keep = {}
      for _, hunk in ipairs(section.hunks) do
        for row = math.max(section.header + 1, hunk.first - cfg.context), math.min(#model.lines, hunk.last + cfg.context) do
          keep[row] = true
        end
      end
      local folding = false
      for row = section.header + 1, #model.lines do
        if model.rows[row].kind == " " and not keep[row] then
          model.rows[row].fold = folding and 2 or ">2"
          folding = true
        else
          folding = false
        end
      end
    end
  end
  model.lines[section.header] = ("%s  [%s]  +%d -%d"):format(clean(pair.path), pair.status, added, removed)
  section.last = #model.lines
  append(model, section, "", { fold = 0 })
end

function M.is_active(buf)
  return active ~= nil and active.buf == buf and vim.api.nvim_buf_is_valid(buf)
end

-- Cheap hover eligibility; comment_target still validates the full selection.
function M.commentable_line(buf, line)
  local row = M.is_active(buf) and active.ready and active.rows[line]
  return not not (row and row.new_line)
end

function M.root(buf)
  return M.is_active(buf) and active.session.root or nil
end

function M.foldexpr()
  local row = active and active.rows[vim.v.lnum]
  return row and row.fold or 0
end

function M.foldtext()
  if not active then
    return ""
  end
  local row = active.rows[vim.v.foldstart]
  if row and row.kind == "header" then
    return active.lines[vim.v.foldstart] .. "  (closed)"
  end
  return ("       ... %d unchanged lines ..."):format(vim.v.foldend - vim.v.foldstart + 1)
end

local function cursor_changed()
  local a = active
  if not a or not a.ready or vim.api.nvim_get_current_buf() ~= a.buf then
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local row = a.rows[line]
  if not row then
    return
  end
  local section = a.sections[row.file]
  if a.session.index ~= row.file then
    a.session.index = row.file
    require("pjollrig.review.panel").sync_index(row.file)
  end
  local hunk_index = 0
  for i, hunk in ipairs(section.hunks) do
    if hunk.first <= line then
      hunk_index = i
    end
  end
  local text = ("%s  |  File %d/%d  |  Hunk %d/%d  |  gf: source  R: refresh"):format(
    clean(section.pair.path),
    row.file,
    #a.sections,
    hunk_index,
    #section.hunks
  )
  vim.wo.winbar = text:gsub("%%", "%%%%")
end

local function jump(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.cmd("normal! zv")
  vim.cmd("normal! zz")
  cursor_changed()
end

function M.jump_file(index, line)
  local a = active
  if not a then
    return
  end
  a.target = { index, line }
  if not a.ready then
    return
  end
  local section = a.sections[index]
  local rows = section.pair.status == "D" and section.old_rows or section.new_rows
  jump((line and rows[line]) or (section.hunks[1] and section.hunks[1].first) or section.header)
end

function M.jump_hunk(forward)
  if not active or not active.ready or #active.hunks == 0 then
    return
  end
  local current = vim.api.nvim_win_get_cursor(0)[1]
  if forward then
    for _, row in ipairs(active.hunks) do
      if row > current then
        return jump(row)
      end
    end
    jump(active.hunks[1])
  else
    for i = #active.hunks, 1, -1 do
      if active.hunks[i] < current then
        return jump(active.hunks[i])
      end
    end
    jump(active.hunks[#active.hunks])
  end
end

function M.refresh_comments()
  local a = active
  if not a or not a.ready then
    return
  end
  vim.api.nvim_buf_clear_namespace(a.buf, comments_ns, 0, -1)
  a.comment_rows = {}
  local records = require("pjollrig").list({ uris = a.session.uri_set }, { root = a.session.root, sync = false })
  for _, record in ipairs(records) do
    local section = a.sections[a.session.uri_index[record.uri]]
    local line = record.range and record.range.start and record.range.start[1] + 1
    local rows = section and (section.pair.status == "D" and section.old_rows or section.new_rows)
    local row = line and rows and rows[line]
    if row then
      local lines = {}
      for i, text in ipairs(vim.split(record.body, "\n", { plain = true })) do
        local prefix = i == 1 and (record.resolved and "  [resolved] " or "  Comment: ") or "    "
        lines[#lines + 1] = { { prefix .. clean(text), "Comment" } }
      end
      vim.api.nvim_buf_set_extmark(a.buf, comments_ns, row - 1, 0, { virt_lines = lines })
      a.comment_rows[#a.comment_rows + 1] = row
    end
  end
  table.sort(a.comment_rows)
end

function M.jump_comment(forward, count)
  if not active or not active.ready then
    return false
  end
  M.refresh_comments()
  local current = vim.api.nvim_win_get_cursor(0)[1]
  local rows = active.comment_rows
  local step = forward and 1 or -1
  local i = forward and 1 or #rows
  while rows[i] do
    local row = rows[i]
    if (forward and row > current) or (not forward and row < current) then
      count = count - 1
      if count == 0 then
        jump(row)
        return true
      end
    end
    i = i + step
  end
  return false
end

-- Resolve once BEFORE opening the comment editor. The returned guard checks
-- the same snapshot again on submit; moving the review cursor cannot retarget it.
function M.comment_target(buf, range)
  local a = active
  if not M.is_active(buf) or not a.ready then
    return nil, "review is still loading"
  end
  local first, last = a.rows[range.start[1] + 1], a.rows[range.end_[1] + 1]
  if not first or not last or not first.new_line or not last.new_line then
    return nil, "choose working-side code lines to comment on"
  end
  for i = range.start[1] + 1, range.end_[1] + 1 do
    local row = a.rows[i]
    if not row or row.file ~= first.file or not row.new_line then
      return nil, "a comment selection must stay within working-side lines of one file"
    end
  end
  local section = a.sections[first.file]
  local source, source_name, identity
  local adapter = require("pjollrig.adapter")
  local function valid()
    if active ~= a or not a.ready then
      return false
    end
    if source then
      if not vim.api.nvim_buf_is_loaded(source) or vim.api.nvim_buf_get_name(source) ~= source_name then
        return false
      end
      local current = adapter.identify(source)
      if
        not current
        or not current.is_writable
        or current.uri ~= identity.uri
        or current.scope ~= identity.scope
        or current.project_root ~= identity.project_root
      then
        return false
      end
    end
    local working, disk = read_source(section.pair.right)
    return vim.deep_equal(section.snapshot, working) and vim.deep_equal(section.disk_snapshot, disk)
  end
  if not valid() then
    return nil, "source changed; press R to refresh the review before commenting"
  end
  source = vim.fn.bufadd(section.pair.right)
  vim.fn.bufload(source)
  source_name = vim.api.nvim_buf_get_name(source)
  identity = adapter.identify(source)
  if not identity or not identity.is_writable or not valid() then
    return nil, "source changed or is not commentable; refresh the review"
  end
  return {
    buf = source,
    range = {
      start = { first.new_line - 1, math.max(0, (range.start[2] or 0) - first.prefix) },
      end_ = { last.new_line - 1, math.max(0, (range.end_[2] or 0) - last.prefix) },
    },
    valid = valid,
  }
end

local function source()
  local a = active
  local row = a and a.ready and a.rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row then
    return
  end
  local section = a.sections[row.file]
  if not row.new_line and row.old_line then
    vim.notify("pjollrig: removed lines have no working-side location", vim.log.levels.INFO)
    return
  end
  if section.pair.status == "D" then
    vim.notify("pjollrig: this file was deleted", vim.log.levels.INFO)
    return
  end
  local saved = a.windows[vim.api.nvim_get_current_win()] or a.default_options
  vim.cmd.tabedit(vim.fn.fnameescape(section.pair.right))
  for name, value in pairs(saved or {}) do
    vim.api.nvim_set_option_value(name, value, { win = 0, scope = "local" })
  end
  vim.api.nvim_win_set_cursor(0, { math.min(row.new_line or 1, vim.api.nvim_buf_line_count(0)), 0 })
end

function M.refresh()
  local a = active
  if not a then
    return
  end
  if a.ready and vim.api.nvim_get_current_buf() == a.buf then
    local row = a.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row then
      a.target = { row.file, row.new_line or row.old_line }
    end
  end
  a.ready = false
  a.build = (a.build or 0) + 1
  local version = a.build
  local model = { lines = {}, rows = {}, sections = {}, hunks = {} }
  local index = 1
  local cfg = require("pjollrig.config").get().review
  local function step()
    if active ~= a or a.build ~= version or not vim.api.nvim_buf_is_valid(a.buf) then
      return
    end
    local started = vim.uv.hrtime()
    repeat
      add_file(model, a.session.files[index], index, cfg)
      index = index + 1
    until index > #a.session.files or vim.uv.hrtime() - started > 8000000
    if index <= #a.session.files then
      vim.schedule(step)
      return
    end
    a.lines, a.rows, a.sections, a.hunks = model.lines, model.rows, model.sections, model.hunks
    vim.bo[a.buf].modifiable = true
    vim.api.nvim_buf_set_lines(a.buf, 0, -1, false, a.lines)
    vim.bo[a.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(a.buf, ns, 0, -1)
    local highlights = { header = "Title", ["+"] = "DiffAdd", ["-"] = "DiffDelete" }
    for row, entry in ipairs(a.rows) do
      local hl = highlights[entry.kind]
      if hl then
        vim.api.nvim_buf_set_extmark(a.buf, ns, row - 1, 0, { line_hl_group = hl })
      end
    end
    a.ready = true
    M.refresh_comments()
    for win in pairs(a.windows) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == a.buf then
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zx")
          M.jump_file(unpack(a.target or { a.session.index }))
        end)
      end
    end
  end
  vim.schedule(step)
end

function M.open(session)
  if not active then
    local buf = require("pjollrig.ui.float").create_scratch_buf({ filetype = "pjollrig-review-all" })
    vim.bo[buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(buf, "pjollrig://review/all/" .. session.generation)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading all files…" })
    vim.bo[buf].modifiable = false
    active = { buf = buf, session = session, windows = {}, rows = {} }
    _G.__pjollrig_all_foldexpr = M.foldexpr
    _G.__pjollrig_all_foldtext = M.foldtext
    local group = vim.api.nvim_create_augroup("PjollrigReviewAll", { clear = true })
    active.group = group
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = cursor_changed })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = {
        "PjollrigAdded",
        "PjollrigEdited",
        "PjollrigDeleted",
        "PjollrigRestored",
        "PjollrigResolved",
        "PjollrigSynced",
      },
      callback = function()
        local a = active
        if not a or a.comments_pending then
          return
        end
        a.comments_pending = true
        vim.schedule(function()
          if active == a then
            a.comments_pending = false
            M.refresh_comments()
          end
        end)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function()
        M.clear()
      end,
    })
    for key, callback in pairs({
      ["]h"] = function()
        M.jump_hunk(true)
      end,
      ["[h"] = function()
        M.jump_hunk(false)
      end,
      gf = source,
      R = M.refresh,
    }) do
      vim.keymap.set("n", key, callback, { buffer = buf, silent = true, desc = "Pjollrig all-files review: " .. key })
    end
    M.refresh()
  end
  local a = active
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, a.buf)
  if not a.windows[win] then
    local saved = {}
    for _, name in ipairs({
      "foldmethod",
      "foldexpr",
      "foldtext",
      "foldlevel",
      "foldenable",
      "number",
      "relativenumber",
      "wrap",
      "winbar",
    }) do
      saved[name] = vim.wo[win][name]
    end
    a.windows[win] = saved
    a.default_options = a.default_options or saved
  end
  for name, value in pairs({
    foldmethod = "expr",
    foldexpr = "v:lua.__pjollrig_all_foldexpr()",
    foldtext = "v:lua.__pjollrig_all_foldtext()",
    foldlevel = 1,
    foldenable = true,
    number = false,
    relativenumber = false,
  }) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  return a.buf
end

function M.clear()
  local a = active
  if not a then
    return
  end
  active = nil
  vim.api.nvim_del_augroup_by_id(a.group)
  -- :split / :tab split can clone the surface without going through open().
  -- Restore their fold callbacks before removing the shared Lua functions.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == a.buf and not a.windows[win] then
      a.windows[win] = a.default_options or {}
    end
  end
  for win, saved in pairs(a.windows) do
    if vim.api.nvim_win_is_valid(win) then
      for name, value in pairs(saved) do
        vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
      end
    end
  end
  _G.__pjollrig_all_foldexpr, _G.__pjollrig_all_foldtext = nil, nil
  if vim.api.nvim_buf_is_valid(a.buf) then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(a.buf) then
        vim.api.nvim_buf_delete(a.buf, { force = true })
      end
    end)
  end
end

return M
