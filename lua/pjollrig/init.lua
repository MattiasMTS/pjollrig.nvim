-- Comments on any buffer: identity, add/edit/delete/resolve, list/loclist, paint, re-anchor.
-- A record is {path, side, rev?, lnum, end_lnum, line, body, created_at, resolved?, deleted?, sent_to?},
-- stored per root (see store.lua). GitHub threads never enter the store (github.lua keeps them in memory).
local M = {}
local api, uv = vim.api, vim.uv
local store = require("pjollrig.store")
local ns = api.nvim_create_namespace("pjollrig")
local marks, snaps = {}, {} -- marks[buf][record id] = {id = extmark id, dim = bool}; snaps[buf] = disk lines

M.config = { sinks = {} }
function M.setup(opts) -- stored by reference: sinks read live values at send time
  M.config = opts or {}
  M.config.sinks = M.config.sinks or {}
end

function M.name(side, root, rev, path)
  return ("pjollrig://%s%s//%s:%s"):format(side, root, rev, path)
end

function M.git_root(path) -- realpath of the repo containing path
  local root = path and vim.fs.root(path, ".git")
  return root and uv.fs_realpath(root)
end

local function repo_file(name)
  local real = name ~= "" and uv.fs_realpath(name) or nil
  return M.git_root(real), real
end

---Buffer -> {root, path, side, rev?}. One mechanism for any tool:
---b:pjollrig (our BufReadCmd, or any plugin) > diff partner > repo file > plain file > memory.
---@return {root:string, path:string, side:"old"|"new", rev:string?}?, string?
function M.identity(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  if type(vim.b[buf].pjollrig) == "table" then
    return vim.b[buf].pjollrig
  end
  local bt, name = vim.bo[buf].buftype, api.nvim_buf_get_name(buf)
  local root, real = repo_file(name)
  if not root or name:match("^%a[%w+.-]*://") then -- unknown tool / non-repo file: generic diff-partner rule
    local win, partners = vim.fn.bufwinid(buf), {}
    local wins = win > 0 and vim.wo[win].diff and api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(win)) or {}
    for _, w in ipairs(wins) do
      local pb = api.nvim_win_get_buf(w)
      local proot, preal = repo_file(api.nvim_buf_get_name(pb))
      if pb ~= buf and vim.wo[w].diff and proot and vim.bo[pb].buftype == "" then
        partners[#partners + 1] = { root = proot, path = vim.fs.relpath(proot, preal), side = "old" } -- rev unknown
      end
    end
    if #partners == 1 then
      return partners[1]
    end
  end
  if name:match("/git%-blob%-") or name:match("/git%-difftool%.") then -- never file under a vanishing temp path
    return nil, "git difftool temp file without a repo partner; use :Pjollrig review"
  end
  if real and bt == "" then -- repo file, or a plain file filed under its directory
    root = root or vim.fs.dirname(real)
    return { root = root, path = vim.fs.relpath(root, real), side = "new" }
  end
  return { root = "buffer:" .. buf, path = name ~= "" and name or "[No Name]", side = "new" } -- memory only
end

local function place(r, lines) -- stored row if its text still matches, else a unique text match, else nil (dim)
  if lines[r.lnum] == r.line then
    return r.lnum - 1
  end
  local hits = {}
  for i, l in ipairs(lines) do
    hits[#hits + 1] = l == r.line and i - 1 or nil
  end
  return #hits == 1 and hits[1] or nil
end

---Where a record is now, without writing: its mark in a loaded buffer (live: unsaved edits too), else its line
---placed in the file on disk. orphaned: neither finds the line (rewritten, deleted, ambiguous: the dimmed `?`),
---so lnum stays where that sign sits. Without a mark, pinned (rev) and unpinned old-side records stay put.
local function locate(r, at, disk)
  local m = at[r.id]
  if m then
    local pos = api.nvim_buf_get_extmark_by_id(m.buf, ns, m.id, { details = true })
    if pos[1] and not pos[3].invalid then
      return pos[1] + 1, m.dim
    end
    return r.lnum, true
  end
  if r.rev or r.side == "old" or r.root:sub(1, 1) ~= "/" then
    return r.lnum, false
  end
  local f = r.root .. "/" .. r.path
  if disk[f] == nil then -- one read per file per list
    local ok, lines = pcall(vim.fn.readfile, f)
    disk[f] = ok and lines or false
  end
  local row = disk[f] and place(r, disk[f])
  return row and row + 1 or r.lnum, not row
end

---Unresolved records of the current root plus in-memory roots (o.all: resolved too), sorted. lnum/end_lnum are
---where each comment is now (see locate), not the stored ones; orphaned marks a comment whose line is gone.
function M.list(o)
  o = o or {}
  local a = M.identity(0)
  local cwd = uv.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
  local roots = { (a and a.root:sub(1, 1) == "/" and a.root) or M.git_root(cwd) or cwd }
  vim.list_extend(roots, vim.tbl_keys(store.mem))
  local out, at, disk = {}, {}, {}
  for buf, bm in pairs(marks) do
    for rid, m in pairs(api.nvim_buf_is_loaded(buf) and bm or {}) do
      at[rid] = { buf = buf, id = m.id, dim = m.dim }
    end
  end
  for _, root in ipairs(roots) do
    for _, r in pairs(store.load(root)) do
      if not r.deleted and (o.all or not r.resolved) and r.body then
        r = vim.tbl_extend("force", r, { root = root })
        local lnum, orphaned = locate(r, at, disk)
        r.lnum, r.end_lnum, r.orphaned = lnum, lnum + (r.end_lnum or r.lnum) - r.lnum, orphaned or nil
        out[#out + 1] = r
      end
    end
  end
  local function key(r)
    return ("%s\0%010d\0%s"):format(r.path, r.lnum, r.id)
  end
  table.sort(out, function(x, y)
    return key(x) < key(y)
  end)
  return out
end

local function label(r) -- list/picker text: first body line; [?]: its line is gone (the dimmed sign)
  return (r.resolved and "[resolved] " or "") .. (r.orphaned and "[?] " or "") .. r.body:match("[^\n]*")
end

local function matches(r, a)
  return r.path == a.path and r.rev == a.rev and (r.rev or r.side == a.side) and not r.deleted and not r.resolved
end

local function deco(r, dim)
  local hl = dim and "Comment" or "DiagnosticInfo"
  return {
    sign_text = dim and "?" or "▌",
    sign_hl_group = hl,
    priority = 8,
    invalidate = true,
    virt_text = { { " " .. r.body:match("[^\n]*"), dim and "Comment" or "DiagnosticVirtualTextInfo" } },
    virt_text_pos = "eol",
  }
end

---Incremental paint: keeps live marks (they track unsaved edits), drops gone ones, places new ones. Never writes.
function M.paint(buf)
  local a = api.nvim_buf_is_loaded(buf) and M.identity(buf)
  if not a then
    return
  end
  local recs, bm, lines = store.load(a.root), marks[buf] or {}, nil
  marks[buf] = bm
  for rid, m in pairs(bm) do
    if not (recs[rid] and matches(recs[rid], a)) then
      api.nvim_buf_del_extmark(buf, ns, m.id)
      bm[rid] = nil
    end
  end
  for rid, r in pairs(recs) do
    if matches(r, a) and r.body then
      local m = bm[rid]
      local pos = m and api.nvim_buf_get_extmark_by_id(buf, ns, m.id, { details = true }) or {}
      if not pos[1] then
        lines = lines or api.nvim_buf_get_lines(buf, 0, -1, false)
        local row = place(r, lines)
        m = { dim = not row }
        pos = { row or math.max(0, math.min(r.lnum, #lines) - 1) }
        if not snaps[buf] then -- snapshot when the first mark lands (RV-M1): disk text, not unsaved edits
          local ok, disk = pcall(vim.fn.readfile, api.nvim_buf_get_name(buf))
          snaps[buf] = vim.bo[buf].modified and ok and disk or lines
        end
      end
      if not (pos[3] and pos[3].invalid) then
        m.id = api.nvim_buf_set_extmark(buf, ns, pos[1], 0, vim.tbl_extend("force", deco(r, m.dim), { id = m.id }))
      end
      bm[rid] = m
    end
  end
  local gh = package.loaded["pjollrig.github"]
  if gh then
    gh.paint(buf, a)
  end
end

local function mapper(old, new) -- f(row0) -> new row0, or nil when that line itself changed
  local hunks =
    vim.text.diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { result_type = "indices" })
  return function(row)
    local l, delta = row + 1, 0
    for _, h in ipairs(hunks) do
      local sa, ca, _, cb = unpack(h)
      if ca > 0 and l >= sa and l < sa + ca then
        return nil
      end
      if (ca == 0 and sa < l) or (ca > 0 and sa + ca <= l) then
        delta = delta + cb - ca
      end
    end
    return l + delta - 1
  end
end

---BufReadPost (first load, :e!, checktime). Extmarks keep their absolute rows across a reload, so map each
---through diff(snapshot, new) — but only trust a row whose snapshot text is the record's line; otherwise
---drop the mark and let paint re-place it (stored lnum / unique match / dim). Never persist on mismatch.
function M.on_read(buf)
  local bm, snap = marks[buf], snaps[buf]
  local new = api.nvim_buf_get_lines(buf, 0, -1, false)
  local a = bm and snap and next(bm) and M.identity(buf)
  if a then
    local recs, map, patches = store.load(a.root), mapper(snap, new), {}
    for rid, m in pairs(bm) do
      local r, pos = recs[rid], api.nvim_buf_get_extmark_by_id(buf, ns, m.id, {})
      local trusted = r and not m.dim and pos[1] and snap[pos[1] + 1] == r.line
      local row = trusted and map(pos[1])
      if row and new[row + 1] == r.line then
        api.nvim_buf_set_extmark(buf, ns, row, 0, vim.tbl_extend("force", deco(r, false), { id = m.id }))
        if row + 1 ~= r.lnum then
          patches[#patches + 1] = { rid, { lnum = row + 1, end_lnum = row + 1 + r.end_lnum - r.lnum } }
        end
      elseif trusted then -- the commented line itself was rewritten: dim in place, never guess
        m.dim = true
        row = math.max(0, math.min(pos[1], #new - 1))
        api.nvim_buf_set_extmark(buf, ns, row, 0, vim.tbl_extend("force", deco(r, true), { id = m.id }))
      else
        api.nvim_buf_del_extmark(buf, ns, m.id)
        bm[rid] = nil
      end
    end
    if #patches > 0 then -- buffer == disk now; every nvim computes the same idempotent patch
      store.patch(a.root, patches)
    end
  end
  snaps[buf] = bm and next(bm) and new or nil
  M.paint(buf)
end

---BufWritePost: persist the positions of live, trusted marks; the written text is the new snapshot.
function M.sync(buf)
  local bm, a = marks[buf], marks[buf] and M.identity(buf)
  if not (a and next(bm)) then
    return
  end
  local recs, lines, patches = store.load(a.root), api.nvim_buf_get_lines(buf, 0, -1, false), {}
  for rid, m in pairs(bm) do
    local r, pos = recs[rid], api.nvim_buf_get_extmark_by_id(buf, ns, m.id, { details = true })
    local row = pos[1] and not m.dim and not pos[3].invalid and pos[1]
    local l = row and row + 1
    if r and l and (l ~= r.lnum or lines[l] ~= r.line) then
      patches[#patches + 1] = { rid, { lnum = l, end_lnum = l + r.end_lnum - r.lnum, line = lines[l] } }
    end
  end
  if #patches > 0 then
    store.patch(a.root, patches)
  end
  snaps[buf] = lines
end

---@param o? {body?: string, line1?: integer, line2?: integer}
function M.add(o)
  o = o or {}
  local buf = api.nvim_get_current_buf()
  local a, why = M.identity(buf)
  if not a then
    return vim.notify("pjollrig: " .. why, vim.log.levels.WARN)
  end
  local l1 = o.line1 or api.nvim_win_get_cursor(0)[1]
  local id
  local function save(body)
    if id then -- editor :w again: same record
      store.patch(a.root, { { id, { body = body, resolved = false } } })
      return M.paint(buf)
    end
    id = store.id()
    local rec = { path = a.path, side = a.side, rev = a.rev, lnum = l1, end_lnum = o.line2 or l1, body = body }
    rec.line, rec.created_at = api.nvim_buf_get_lines(buf, l1 - 1, l1, false)[1] or "", os.time()
    store.patch(a.root, { { id, rec } })
    M.paint(buf)
    local data = vim.tbl_extend("force", rec, { id = id, root = a.root })
    api.nvim_exec_autocmds("User", { pattern = "PjollrigAdded", data = data })
  end
  if o.body then
    return save(o.body)
  end
  require("pjollrig.editor").open("", save)
end

---Records to act on, as a list: in a location list, rows o.line1..o.line2 (default: the cursor row), found by
---the {root, id} they carry, so GitHub rows (none) stay read-only; else the mark under the cursor; else a pick.
local function target(all, o, cb)
  local buf, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]
  if vim.fn.win_gettype() == "loclist" then
    local items, recs = vim.fn.getloclist(0), {}
    for i = o and o.line1 or row, o and o.line2 or row do
      local u = (items[i] or {}).user_data
      local k = type(u) == "table" and u.pjollrig
      local r = k and store.load(k.root)[k.id]
      if r and not r.deleted then
        recs[#recs + 1] = vim.tbl_extend("force", r, { root = k.root })
      end
    end
    if #recs == 0 then
      return vim.notify("pjollrig: no comment on this row")
    end
    return cb(recs)
  end
  local a = M.identity(buf)
  for rid, m in pairs(a and marks[buf] or {}) do
    local r = store.load(a.root)[rid]
    if r and api.nvim_buf_get_extmark_by_id(buf, ns, m.id, {})[1] == row - 1 then
      return cb({ vim.tbl_extend("force", r, { root = a.root }) })
    end
  end
  local recs = M.list({ all = all })
  if #recs == 0 then
    return vim.notify("pjollrig: no comments")
  end
  vim.ui.select(recs, {
    prompt = "pjollrig",
    format_item = function(r)
      return ("%s:%d %s"):format(r.path, r.lnum, label(r))
    end,
  }, function(r)
    if r then
      cb({ r })
    end
  end)
end

M._undo = {} -- batches of {root, id, fields}: what each edit/delete/resolve overwrote, newest last

local function write(changes) -- {root, id, fields}[]: one store.patch (one write) per root, then repaint
  local by = {}
  for _, c in ipairs(changes) do
    by[c[1]] = by[c[1]] or {}
    table.insert(by[c[1]], { c[2], c[3] })
  end
  for root, patches in pairs(by) do
    store.patch(root, patches)
  end
  M.refresh()
end

local function mutate(recs, fields)
  local changes, back = {}, {}
  for _, r in ipairs(recs) do
    local cur, prev = store.load(r.root)[r.id] or r, {}
    for k in pairs(fields) do
      prev[k] = cur[k] or false -- fields are never unset: an absent flag comes back as false
    end
    changes[#changes + 1], back[#back + 1] = { r.root, r.id, fields }, { r.root, r.id, prev }
  end
  table.insert(M._undo, back)
  write(changes)
end

function M.edit(o)
  target(false, o, function(recs)
    require("pjollrig.editor").open(recs[1].body, function(body)
      mutate({ recs[1] }, { body = body, resolved = false }) -- RV-m3: an edit un-hides a comment another nvim just sent
    end, "edit")
  end)
end

function M.delete(o)
  target(true, o, function(recs)
    mutate(recs, { deleted = true })
  end)
end

---Toggle. Over several rows: resolve them all, unless all already are (then un-resolve them all).
function M.resolve(o)
  target(true, o, function(recs)
    local any = vim.iter(recs):any(function(r)
      return not r.resolved
    end)
    mutate(recs, { resolved = any })
  end)
end

function M.undo() -- the last edit/delete/resolve, wherever it was made
  local back = table.remove(M._undo)
  if not back then
    return vim.notify("pjollrig: nothing to undo")
  end
  write(back)
end

local function title(all)
  return "pjollrig" .. (all and " (all)" or "")
end

---Location-list rows. Store rows carry {root, id} (user_data.pjollrig) for the list's own actions; GitHub rows
---don't. Rev-less old rows (foreign diff tools) have no file to jump to: they are text-only, labelled
---"(old, unpinned)" with the anchored line text.
local function rows(all)
  local items = {}
  for _, r in ipairs(M.list({ all = all })) do
    local text = label(r)
    local ud = { pjollrig = { root = r.root, id = r.id } }
    if r.side == "old" and not r.rev then
      items[#items + 1] = {
        text = ("%s:%d (old, unpinned) %s │ %s"):format(r.path, r.lnum, vim.trim(r.line), text),
        user_data = ud,
      }
    else
      local file = r.rev and M.name(r.side, r.root, r.rev, r.path)
        or r.root:sub(1, 1) == "/" and (r.root .. "/" .. r.path)
      local bufnr = not file and tonumber(r.root:match("^buffer:(%d+)")) or nil
      items[#items + 1] =
        { filename = file or nil, bufnr = bufnr, lnum = r.lnum, end_lnum = r.end_lnum, text = text, user_data = ud }
    end
  end
  local gh = package.loaded["pjollrig.github"]
  if gh then
    vim.list_extend(items, gh.items())
  end
  return items
end

---Rebuild every open pjollrig location list in place, keeping its cursor and current entry. Rows are built
---from the list's own window, so they come from the same root as when it was opened.
local function relist(wins)
  for _, w in ipairs(wins or api.nvim_list_wins()) do
    local ll = vim.fn.win_gettype(w) == "loclist" and vim.fn.getloclist(w, { title = 0, filewinid = 0, idx = 0 })
    if ll and (ll.title == title(false) or ll.title == title(true)) then
      local all = ll.title == title(true)
      local items = ll.filewinid > 0 and api.nvim_win_call(ll.filewinid, function()
        return rows(all)
      end) or rows(all)
      local cur = api.nvim_win_get_cursor(w)[1]
      local idx = #items > 0 and math.min(ll.idx, #items) or nil -- an idx on an empty list fails
      vim.fn.setloclist(w, {}, "r", { title = ll.title, items = items, idx = idx })
      api.nvim_win_set_cursor(w, { math.max(1, math.min(cur, #items)), 0 })
    end
  end
end

function M.refresh() -- after any change: repaint every window, rebuild open lists
  for _, w in ipairs(api.nvim_list_wins()) do
    M.paint(api.nvim_win_get_buf(w))
  end
  relist()
end

local group = api.nvim_create_augroup("pjollrig-list", {})

---The list's own maps: {count}r / {count}dd and visual r / d act on rows, ce edits, u undoes the last change.
---Stepping into the list rebuilds it: files may have changed since (an agent's edits, another nvim).
local function keys(buf)
  api.nvim_clear_autocmds({ group = group, buffer = buf })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      relist({ api.nvim_get_current_win() })
    end,
  })
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "pjollrig: " .. desc })
  end
  local function counted(fn)
    return function()
      local l = api.nvim_win_get_cursor(0)[1]
      fn({ line1 = l, line2 = l + vim.v.count1 - 1 })
    end
  end
  map("n", "r", counted(M.resolve), "toggle resolved")
  map("x", "r", ":Pjollrig resolve<CR>", "toggle resolved")
  map("n", "dd", counted(M.delete), "delete comment")
  map("x", "d", ":Pjollrig delete<CR>", "delete comments")
  map("n", "ce", M.edit, "edit comment")
  map("n", "u", M.undo, "undo")
end

---Fill the location list of the new-side window.
function M.loclist(all)
  local win = api.nvim_get_current_win()
  if vim.wo[win].diff and (M.identity(0) or {}).side == "old" then
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if vim.wo[w].diff and (M.identity(api.nvim_win_get_buf(w)) or {}).side == "new" then
        win = w
      end
    end
  end
  vim.fn.setloclist(win, {}, " ", { title = title(all), items = rows(all) })
  api.nvim_set_current_win(win) -- the list opens below the new side, and the cursor moves into it
  vim.cmd("lopen")
  keys(api.nvim_get_current_buf())
end

return M
