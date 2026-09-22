-- pjollrig.nvim: review session core.
--
-- Opens baseline-vs-worktree file pairs as diffs, one active session at
-- a time. Per-file modes use real worktree buffers; the all-files view
-- maps display rows back to source buffers before creating comments.
--
--   * `review.diff_mode = "split"` (default) — plain `:diffsplit`:
--     read-only staged baseline on the left, worktree file on the right.
--   * `review.diff_mode = "unified"` — a single window showing the
--     worktree file with the diff painted onto it (see `review/inline.lua`).
--
-- `:PjollrigReviewDiffMode` flips between them, re-rendering the pair
-- that is currently open.
--
-- A pair with `status = "doc"` has NO baseline (`left` is nil): a
-- document — a plan or report — reviewed for its own sake.
-- It opens plain in one window with prose wrapping, in either diff
-- mode, and carries no diffstat.

local M = {}

local uv = vim.uv

---@class pjollrig.ReviewSession
---@field files {left: string|nil, right: string, status: string, path: string}[] empty while `resolving`; `left` is nil for `status = "doc"`
---@field label string
---@field sink string|nil
---@field ctx table|nil sink dispatch context (finish() passes it to the sink)
---@field resolving boolean|nil true between begin() and attach(): the shell is open, the resolver is still staging
---@field generation integer monotonic session counter; a stale resolve callback whose generation no longer matches must not attach
---@field index integer
---@field tab integer
---@field root string|nil project root the worktree files live under (cached by start)
---@field uris string[] pair_path URI per file, index-aligned with `files` (cached by start)
---@field uri_set table<string, true> membership set over `uris` (list()/send() filter)
---@field uri_index table<string, integer> URI -> first pair index (panel jumps)
---@field stage_dirs string[]|nil staging dirs the session OWNS; deleted by stop()
---@field mapped_bufs table<integer, true>|nil
---@field diffstat {added: integer, removed: integer}[]|nil per-pair line counts, filled lazily by M.diffstat()
---@field viewed table<integer, true> pair index -> viewed; auto-marked by next/prev, toggled by the panel's `v`
---@field winbar_wins table<integer, true> windows whose winbar the session set (cleared on pair switch and stop)
---@field breadcrumb_win integer|nil window carrying the OPEN pair's breadcrumb, so the deferred diffstat fill can repaint it with the counts

---@type pjollrig.ReviewSession|nil
local session = nil

---Bumped by every begin(); stamped onto the session. The async resolve
---callback compares its captured value against the LIVE session so a
---resolve outliving its session (stopped, or superseded by a newer
---`:PjollrigReview`) can never attach — outstanding subprocess handles
---are simply orphaned (vim.system offers no cross-callback kill here
---worth the plumbing) and their staged output is deleted when the
---stale callback finally lands.
local generation = 0

local function protect_left(bufnr)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
end

---@return pjollrig.ReviewConfig
local function review_config()
  return require("pjollrig.config").get().review or {}
end

---Windows the pair-switch teardown must never touch: the review panel
---(an owned `pjollrig-panel` scratch buffer) and any quickfix/loclist
---window the USER has open — the panel no longer lives in the quickfix
---list, so those are entirely the user's.
---@param winid integer
---@return boolean
local function is_preserved_window(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.bo[bufnr].buftype == "quickfix" or vim.bo[bufnr].filetype == "pjollrig-panel"
end

---Winbar text must survive the statusline engine: literal `%` doubles.
---@param text string
---@return string
local function winbar_escape(text)
  return (text:gsub("%%", "%%%%"))
end

---`path · S · +A −R` for the pair's commentable window, zero diffstat
---components omitted (matching the panel rows).
---@param pair {path: string, status: string}
---@param stat {added: integer, removed: integer}|nil
---@return string
local function breadcrumb(pair, stat)
  local parts = { pair.path, pair.status }
  local counts = {}
  if stat and stat.added > 0 then
    counts[#counts + 1] = ("+%d"):format(stat.added)
  end
  if stat and stat.removed > 0 then
    counts[#counts + 1] = ("\u{2212}%d"):format(stat.removed)
  end
  if #counts > 0 then
    parts[#parts + 1] = table.concat(counts, " ")
  end
  return winbar_escape(table.concat(parts, " \u{00B7} "))
end

---Set a window's winbar and remember it for teardown: winbars are
---window-local, but pair switches reuse one window (close_session_windows
---keeps the first) and `:only`/single-tab stop() leave a file window
---alive — those must not keep a stale breadcrumb.
---@param winid integer
---@param text string
local function set_winbar(winid, text)
  vim.wo[winid].winbar = text
  session.winbar_wins[winid] = true
end

---@param winbar_wins table<integer, true>|nil
local function clear_winbars(winbar_wins)
  for winid in pairs(winbar_wins or {}) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.wo[winid].winbar = ""
    end
  end
end

---Set the OPEN pair's breadcrumb winbar, remembering the window so the
---deferred diffstat fill (fill_diffstat) can repaint the counts onto a
---breadcrumb that rendered before they existed.
---@param winid integer
---@param pair {path: string, status: string}
---@param stat {added: integer, removed: integer}|nil
local function set_breadcrumb(winid, pair, stat)
  set_winbar(winid, breadcrumb(pair, stat))
  session.breadcrumb_win = winid
end

local function close_session_windows()
  -- Reduce the session tab windows to diff windows only (preserve the
  -- panel and any user quickfix). Unified paint is buffer-scoped, so it
  -- must be dropped explicitly — `diffoff!` knows nothing about it.
  if session then
    -- The surviving window is reused for the next pair; drop this
    -- pair's winbars so nothing stale outlives the switch.
    clear_winbars(session.winbar_wins)
    session.winbar_wins = {}
  end
  require("pjollrig.review.inline").clear_all()
  vim.cmd("silent! diffoff!")
  -- Close all non-preserved windows except the first one
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local first_file_win = nil
  for _, winid in ipairs(wins) do
    if not is_preserved_window(winid) then
      if not first_file_win then
        first_file_win = winid
      else
        pcall(vim.api.nvim_win_close, winid, false)
      end
    end
  end
  -- Focus the remaining file window. When none is left (e.g. `:only`
  -- from the panel), make a fresh one — a pair must never be edited
  -- into the panel or a quickfix window.
  if first_file_win and vim.api.nvim_win_is_valid(first_file_win) then
    vim.api.nvim_set_current_win(first_file_win)
  elseif is_preserved_window(vim.api.nvim_get_current_win()) then
    pcall(vim.api.nvim_open_win, vim.api.nvim_create_buf(false, true), true, { split = "above", win = -1 })
  end
end

-- Session-scoped file navigation: <Tab>/<S-Tab> cycle pairs. Buffer-local
-- so the global <Tab> (= <C-i> jumplist) is shadowed only inside review
-- buffers, and removed again in stop(). Left buffers are bufhidden=wipe;
-- right buffers are real files, so stop() must unmap them explicitly.
local function map_navigation(bufnr)
  if not session then
    return
  end
  vim.keymap.set("n", "<Tab>", function()
    require("pjollrig.review").next()
  end, { buffer = bufnr, desc = "Pjollrig review: next file (marks this one viewed; skips viewed files)" })
  vim.keymap.set("n", "<S-Tab>", function()
    require("pjollrig.review").prev()
  end, { buffer = bufnr, desc = "Pjollrig review: previous file (literal step back)" })
  session.mapped_bufs = session.mapped_bufs or {}
  session.mapped_bufs[bufnr] = true
end

local function unmap_navigation(mapped_bufs)
  for bufnr in pairs(mapped_bufs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.keymap.del, "n", "<Tab>", { buffer = bufnr })
      pcall(vim.keymap.del, "n", "<S-Tab>", { buffer = bufnr })
    end
  end
end

---Open the pair at `index` in the session tab: rebuild the diff layout
---(split or unified per `review.diff_mode`; `doc` pairs open plain in
---either mode), set the winbar breadcrumbs, and point the panel's files
---view at the pair. Out-of-range indexes wrap. No-op without a session.
---@param index integer
function M.open_pair(index)
  -- No pairs yet while a resolve is in flight (begin() opened only the
  -- shell): nothing to show, and the wrap math below needs #files >= 1.
  if not session or #session.files == 0 then
    return
  end
  if index < 1 then
    index = #session.files
  elseif index > #session.files then
    index = 1
  end
  session.index = index
  local pair = session.files[index]
  -- The review tab can die under the session (`:tabclose` instead of
  -- stop()): the session and its buffer-local <Tab> maps survive, and
  -- the dead handle used to throw 'Invalid tabpage id' here. Recreate
  -- the tab (panel included) rather than stopping, so the session and
  -- its pending comments stay alive. A TabClosed autocmd that stops the
  -- session would fight this recovery — an accidental close would kill
  -- the review and the VimLeavePre autoflush of its comments — so we
  -- recover lazily here instead.
  if not vim.api.nvim_tabpage_is_valid(session.tab) then
    vim.cmd.tabnew()
    session.tab = vim.api.nvim_get_current_tabpage()
    require("pjollrig.review.panel").open()
  end
  vim.api.nvim_set_current_tabpage(session.tab)
  local all = require("pjollrig.review.all")
  if review_config().file_mode == "all" then
    local win
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
      if all.is_active(vim.api.nvim_win_get_buf(candidate)) then
        win = candidate
        break
      end
    end
    if win then
      vim.api.nvim_set_current_win(win)
    else
      close_session_windows()
      map_navigation(all.open(session))
    end
    session.breadcrumb_win = nil
    all.jump_file(index)
    require("pjollrig.review.panel").sync_index(index)
    return
  end
  all.clear()
  close_session_windows()

  -- Winbar breadcrumb data: the cached per-pair diffstat (computed
  -- lazily once per session).
  local stat = (M.diffstat() or {})[index]

  if pair.status == "doc" then
    -- A document, not a diff: the file alone in the one window, wrapped
    -- for prose. The options go on with `:setlocal` scope — `vim.wo`
    -- has `:set` semantics for these and would also set the window's
    -- value for NEW buffers, leaking onto the next pair edited into the
    -- reused window. Local values travel with this buffer instead, so
    -- no restore is needed on switch or stop.
    vim.cmd.edit(vim.fn.fnameescape(pair.right))
    local win = vim.api.nvim_get_current_win()
    for _, name in ipairs({ "wrap", "linebreak", "breakindent" }) do
      vim.api.nvim_set_option_value(name, true, { win = win, scope = "local" })
    end
    map_navigation(vim.api.nvim_get_current_buf())
    set_breadcrumb(win, pair, nil)
    require("pjollrig.review.panel").sync_index(index)
    return
  end

  if pair.status == "D" then
    vim.cmd.edit(vim.fn.fnameescape(pair.left))
    protect_left(vim.api.nvim_get_current_buf())
    map_navigation(vim.api.nvim_get_current_buf())
    set_breadcrumb(vim.api.nvim_get_current_win(), pair, stat)
    vim.notify(("pjollrig: %s was deleted; comments here are file-level notes"):format(pair.path), vim.log.levels.INFO)
    require("pjollrig.review.panel").sync_index(index)
    return
  end

  local cfg = review_config()

  if cfg.diff_mode == "unified" then
    -- One window, the worktree file itself, with the baseline painted on
    -- as virtual lines. No second buffer means nothing to protect and no
    -- coordinate translation anywhere in the comment path.
    vim.cmd.edit(vim.fn.fnameescape(pair.right))
    local buf = vim.api.nvim_get_current_buf()
    local ok, err = require("pjollrig.review.inline").apply(buf, pair.left, {
      fold = cfg.fold_unchanged ~= false,
      context = cfg.context,
    })
    if not ok then
      vim.notify(err or "pjollrig: cannot render inline diff", vim.log.levels.WARN)
    end
    map_navigation(buf)
    set_breadcrumb(vim.api.nvim_get_current_win(), pair, stat)
    require("pjollrig.review.panel").sync_index(index)
    return
  end

  -- Plain diffsplit: Right first (focused), left split beside it.
  -- nvim.difftool support could be added later via open() hook if needed.
  vim.cmd.edit(vim.fn.fnameescape(pair.right))
  local right_buf = vim.api.nvim_get_current_buf()
  local right_win = vim.api.nvim_get_current_win()
  vim.cmd("leftabove vertical diffsplit " .. vim.fn.fnameescape(pair.left))
  local left_win = vim.api.nvim_get_current_win()
  protect_left(vim.api.nvim_get_current_buf())
  map_navigation(vim.api.nvim_get_current_buf())
  map_navigation(right_buf)
  set_breadcrumb(right_win, pair, stat)
  set_winbar(left_win, winbar_escape(pair.path .. " \u{00B7} baseline"))
  vim.cmd.wincmd("p") -- focus back on the right / worktree side
  if cfg.fold_unchanged == false then
    -- Native :diffsplit folds unchanged regions (foldmethod=diff); the
    -- default is the whole file visible, so drop the folds in both sides.
    vim.wo[left_win].foldenable = false
    vim.wo[vim.api.nvim_get_current_win()].foldenable = false
  end
  -- Keep the panel's files view pointing at the pair now on screen.
  require("pjollrig.review.panel").sync_index(index)
end

---Index of the nearest unviewed pair `dir` (+1/-1) steps away from the
---current one, wrapping. With every pair viewed, the plain neighbor —
---the bounded scan can never loop.
---@param dir integer
---@return integer
local function seek_unviewed(dir)
  local count = #session.files
  local index = session.index
  for _ = 1, count do
    index = (index - 1 + dir) % count + 1
    if not session.viewed[index] then
      return index
    end
  end
  return session.index + dir -- all viewed: plain cycle (M.open_pair wraps)
end

-- Only next() marks the pair the user navigates AWAY from as viewed and
-- skips already-viewed pairs — advancing is the completion gesture (the
-- panel's `v` un-marks). prev() is a literal step back: going back means
-- the user is NOT done, so it neither marks nor skips — otherwise
-- <Tab><S-Tab> would land on the bottom-most unviewed file instead of
-- the one just left.

---Open the nearest unviewed pair after the current one (wrapping),
---marking the pair navigated away from as viewed. With every pair
---viewed, plain-cycles forward. No-op without a session.
function M.next()
  if session then
    M.set_viewed(session.index, true)
    M.open_pair(seek_unviewed(1))
  end
end

---Open the previous pair, literally: one step back with wrap, no
---viewed-marking and no skipping. No-op without a session.
function M.prev()
  if session then
    M.open_pair(session.index - 1)
  end
end

---Mark or un-mark a pair as viewed (session-scoped; read back via
---`M.state().viewed`). Refreshes the panel so the row dims/undims and
---the progress count updates. No-op without a session or for an index
---outside the session's files.
---@param index integer
---@param viewed boolean
function M.set_viewed(index, viewed)
  if not session or not session.files[index] then
    return
  end
  session.viewed[index] = viewed and true or nil
  require("pjollrig.review.panel").refresh()
end

---@return pjollrig.ReviewSession|nil
function M.state()
  return session
end

---Path of the buffer a pair is reviewed — and commented — in: the
---worktree file (right side; a `doc` pair has nothing else), except
---for deletions, where only the staged baseline (left side) still
---exists to open and anchor comments to.
---@param pair {left: string|nil, right: string, status: string}
---@return string
function M.pair_path(pair)
  return pair.status == "D" and pair.left or pair.right
end

---File lines, or nil when the file is unreadable (job-staged files may
---vanish under a session).
---@param path string
---@return string[]|nil
local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and type(lines) == "table" then
    return lines
  end
  return nil
end

---Join file lines into diffable text. An empty file reads back as `{}`;
---collapsing it to "" keeps vim.diff from seeing a phantom blank line
---(the review/inline.lua join convention).
---@param lines string[]
---@return string
local function join_lines(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

---Added/removed line counts for one pair. `A` and `D` shortcut to the
---surviving side's line count; everything else diffs the two sides.
---An unreadable side counts as {0, 0} — the panel simply omits the stat.
---A `doc` pair has no baseline to count against: nil, and the panel row
---and breadcrumb omit the segment.
---@param pair {left: string|nil, right: string, status: string}
---@return {added: integer, removed: integer}|nil
local function pair_diffstat(pair)
  if pair.status == "doc" then
    return nil
  end
  if pair.status == "A" then
    local lines = read_lines(pair.right)
    return { added = lines and #lines or 0, removed = 0 }
  end
  if pair.status == "D" then
    local lines = read_lines(pair.left)
    return { added = 0, removed = lines and #lines or 0 }
  end
  local left = read_lines(pair.left)
  local right = read_lines(pair.right)
  if not left or not right then
    return { added = 0, removed = 0 }
  end
  local added, removed = 0, 0
  local hunks = vim.diff(join_lines(left), join_lines(right), { result_type = "indices" })
  for _, hunk in ipairs(hunks) do
    removed = removed + hunk[2]
    added = added + hunk[4]
  end
  return { added = added, removed = removed }
end

---Per-pair `{added, removed}` line counts.
---
---With explicit `files`, computes the stat for exactly those pairs — a
---plain function of the paths on disk that neither reads nor fills the
---session cache (and needs no session at all); the benchmark uses this
---form.
---
---Without arguments, the ACTIVE session's diffstat, index-aligned with
---`state().files` — or nil until the DEFERRED fill completes. The fill
---(kicked when the session's files attach, see fill_diffstat) computes
---the stat ONCE per session in chunked event-loop steps so the first
---panel render never pays 2×N file reads; rows simply omit the counts
---until the fill's one refresh. Pairs are immutable, so there is
---nothing to invalidate. The worktree side CAN change under a live
---session; the stat deliberately stays as-of-attach rather than
---re-reading every pair per render (the next :PjollrigReview
---recomputes).
---@param files? {left: string|nil, right: string, status: string}[] explicit pairs (bypasses the session cache)
---@return {added: integer, removed: integer}[]|nil stats nil for the argless form without a session or before the deferred fill lands; `doc` pairs leave their index nil
function M.diffstat(files)
  if files then
    local stats = {}
    for idx, pair in ipairs(files) do
      stats[idx] = pair_diffstat(pair)
    end
    return stats
  end
  if not session then
    return nil
  end
  return session.diffstat
end

---Pairs computed per deferred diffstat step: ~200 keeps one step under
---~10ms on the 2000-file benchmark repo (the whole sync pass is ~75ms).
local DIFFSTAT_CHUNK = 200

---Fill `s.diffstat` in chunked vim.schedule steps, then refresh the
---panel ONCE so the rows gain their `+A −R` counts. The cache lands
---atomically (M.diffstat() returns nil until every pair is computed).
---Guarded by session identity: a stopped or superseded session's loop
---halts on its next step.
---@param s pjollrig.ReviewSession
local function fill_diffstat(s)
  local stats = {}
  local index = 1
  local function step()
    if session ~= s then
      return
    end
    local last = math.min(index + DIFFSTAT_CHUNK - 1, #s.files)
    for i = index, last do
      stats[i] = pair_diffstat(s.files[i])
    end
    index = last + 1
    if index <= #s.files then
      vim.schedule(step)
      return
    end
    s.diffstat = stats
    require("pjollrig.review.panel").refresh()
    -- The open pair's breadcrumb rendered before the counts existed:
    -- repaint it now that they do (pair switches recompute it anyway).
    local win = s.breadcrumb_win
    local pair = s.files[s.index]
    if win and pair and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = breadcrumb(pair, stats[s.index])
    end
  end
  vim.schedule(step)
end

---Switch the diff rendering used by review sessions. With no argument,
---flips between "split" and "unified". The setting lives on the merged
---config, so it also becomes the default for later sessions in this
---Neovim instance; put `review.diff_mode` in `setup()` to make it permanent.
---@param mode? "split"|"unified"|"" nil/"" toggles
---@return string|nil mode, string|nil err
function M.set_diff_mode(mode)
  local cfg = require("pjollrig.config").get()
  cfg.review = cfg.review or {}
  if mode == nil or mode == "" then
    mode = cfg.review.diff_mode == "unified" and "split" or "unified"
  end
  if mode ~= "split" and mode ~= "unified" then
    local err = ('pjollrig: review mode must be "split" or "unified", got %q'):format(tostring(mode))
    vim.notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  -- The runtime-override channel: `config.get()` returns the live merged
  -- table, so writing here changes the default for later sessions too.
  cfg.review.diff_mode = mode
  if session then
    -- Re-render the pair on screen so the switch is visible immediately
    -- rather than at the next file.
    M.open_pair(session.index)
  end
  vim.notify(("pjollrig: review diff mode is %s"):format(mode), vim.log.levels.INFO)
  return mode
end

---Choose one file at a time or a continuous unified review of all files.
function M.set_file_mode(mode)
  local cfg = require("pjollrig.config").get().review
  if mode == nil or mode == "" then
    mode = cfg.file_mode == "all" and "single" or "all"
  end
  if mode ~= "all" and mode ~= "single" then
    local err = 'pjollrig: file mode must be "single" or "all"'
    vim.notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  cfg.file_mode = mode
  if session then
    M.open_pair(session.index)
  end
  return mode
end

---Session-derived query cache, computed ONCE per session: the URI of
---every commentable buffer (see M.pair_path — matching how
---adapter.identify keys records) and the project root the worktree
---files live under. `uri.for_path` costs an fs_realpath per file and
---`vim.fs.root` a marker walk; finish(), the VimLeavePre autoflush, and
---every panel refresh used to redo that work per call. `session.files`
---never changes after start, so the cache cannot go stale.
---
---The root matters because list() resolves the store root from the
---CURRENT buffer, falling back to cwd — which, from an unnamed buffer,
---the VimLeavePre autoflush, or a job-driven review of an external
---worktree, can miss the reviewed project entirely and silently drop
---the session's comments. It is passed as `opts.root` on every
---list/send call instead.
---@param s pjollrig.ReviewSession
local function build_session_cache(s)
  local uri_mod = require("pjollrig.uri")
  s.uris = {}
  s.uri_set = {}
  s.uri_index = {}
  for idx, pair in ipairs(s.files) do
    local uri = uri_mod.for_path(M.pair_path(pair))
    s.uris[idx] = uri
    s.uri_set[uri] = true
    if not s.uri_index[uri] then
      s.uri_index[uri] = idx
    end
  end
  local markers = require("pjollrig.config").get().store.root_markers
  for _, pair in ipairs(s.files) do
    local root = vim.fs.root(M.pair_path(pair), markers)
    if root then
      s.root = root
      break
    end
  end
end

---Open the review SHELL: a fresh tab plus the panel showing a
---resolving placeholder — no file pairs yet. The other half of
---start(): attach() below lands the resolved files into this session.
---Split out so `M.start_async` can put a surface on screen within one
---frame while its resolver still runs.
---@param label string
---@return integer generation
local function begin(label)
  if session then
    M.stop()
  end
  generation = generation + 1
  vim.cmd.tabnew()
  session = {
    files = {},
    label = label or "review",
    resolving = true,
    generation = generation,
    index = 0,
    tab = vim.api.nvim_get_current_tabpage(),
    uris = {},
    uri_set = {},
    uri_index = {},
    viewed = {},
    winbar_wins = {},
  }
  -- The panel is an owned scratch-buffer split (files/comments views);
  -- review mode never touches the quickfix stack. While resolving it
  -- renders the spinner placeholder row + busy winbar.
  require("pjollrig.review.panel").open()
  return generation
end

---Land a resolved job's files into the begin()-opened session: build
---the session cache, open the first pair, re-render the panel, kick
---custom tabs' prefetch hooks and the deferred diffstat fill.
---@param job {files: table[], label?: string, sink?: string, ctx?: table, stage_dirs?: string[]}
local function attach(job)
  session.files = job.files
  session.label = job.label or session.label
  session.sink = job.sink
  session.ctx = job.ctx
  session.stage_dirs = job.stage_dirs
  session.resolving = nil
  session.index = 1
  build_session_cache(session)
  -- Word-level diff emphasis in split mode: upgrade the stock
  -- `inline:simple` to `inline:word` for the session. A user who chose
  -- an inline variant themselves (char/word/none) keeps it — we only
  -- replace the 0.12 default, and restore it in stop().
  local diffopt = vim.o.diffopt
  if diffopt:find("inline:simple", 1, true) then
    session.saved_diffopt = diffopt
    vim.o.diffopt = diffopt:gsub("inline:simple", "inline:word")
  end
  M.open_pair(1)
  -- Re-render the (already open) panel now that the rows exist.
  require("pjollrig.review.panel").open()
  -- Opted-in custom tabs may prefetch after the first pair is on screen.
  require("pjollrig.review.panel").prefetch()
  -- Per-pair diffstat: deferred chunks + one refresh (see M.diffstat).
  fill_diffstat(session)
end

---Start a review session over explicit file pairs. `stage_dirs` lists
---staging directories the session OWNS: stop() deletes them (and wipes
---any buffer still pointing into them). Resolvers report only dirs they
---created themselves. Pure: returns instead of notifying (the command
---layer notifies). SYNCHRONOUS by contract — external drivers
---(start_from_job) and tests hand it pre-staged files; `:PjollrigReview`
---goes through M.start_async instead.
---@param opts {files: table[], label?: string, sink?: string, ctx?: table, stage_dirs?: string[]}
---@return boolean ok, string|nil err
function M.start(opts)
  opts = opts or {}
  if type(opts.files) ~= "table" or #opts.files == 0 then
    return false, "pjollrig: review has no files to show"
  end
  begin(opts.label)
  attach(opts)
  return true
end

---Delete the staging dirs a stopped session OWNED. Buffers first:
---deleted-file pairs or external jobs may open staged files as plain
---file buffers — wipe anything still pointing into a stage dir so no
---buffer is left naming a removed file. Comments recorded on those
---staged URIs live in the session-scope store and simply remain
---(session-scoped by design; finish() already ran or the user chose
---not to send).
---@param stage_dirs string[]|nil
local function cleanup_stage_dirs(stage_dirs)
  if type(stage_dirs) ~= "table" or #stage_dirs == 0 then
    return
  end
  local prefixes = {}
  for _, dir in ipairs(stage_dirs) do
    if type(dir) == "string" and dir ~= "" and dir ~= "/" then
      local norm = dir:gsub("/+$", "")
      prefixes[#prefixes + 1] = norm .. "/"
      -- Buffer names may carry the resolved path (macOS: /tmp and
      -- /var/folders are symlinks under /private).
      local real = uv.fs_realpath(norm)
      if real and real ~= norm then
        prefixes[#prefixes + 1] = real .. "/"
      end
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      for _, prefix in ipairs(prefixes) do
        if name:sub(1, #prefix) == prefix then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
          break
        end
      end
    end
  end
  for _, dir in ipairs(stage_dirs) do
    if type(dir) == "string" and dir ~= "" and dir ~= "/" then
      vim.fn.delete(dir, "rf")
    end
  end
end

---End the active session: close the panel and session tab, remove the
---buffer-local navigation maps, winbars, and inline paint, restore
---diffopt, and delete owned staging dirs. Pure: returns instead of
---notifying (the command layer notifies on false).
---@return boolean ok, string|nil err false when no session is active
function M.stop()
  if not session then
    return false, "pjollrig: no active review session"
  end
  require("pjollrig.review.panel").close()
  require("pjollrig.review.all").clear()
  local tab = session.tab
  local stage_dirs = session.stage_dirs
  -- Worktree buffers outlive the session tab, so the inline paint has to
  -- come off explicitly or the file keeps its diff highlights forever.
  require("pjollrig.review.inline").clear_all()
  unmap_navigation(session.mapped_bufs)
  -- Winbars come off while the windows are still valid: the tabclose
  -- below usually destroys them, but the single-tab branch (and any
  -- `:only`-surviving worktree window) reuses a session window.
  clear_winbars(session.winbar_wins)
  if session.saved_diffopt then
    vim.o.diffopt = session.saved_diffopt
  end
  session = nil
  if vim.api.nvim_tabpage_is_valid(tab) then
    local tab_count = #vim.api.nvim_list_tabpages()
    if tab_count > 1 then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("silent! diffoff!")
      vim.cmd("tabclose")
    else
      -- Single tab: close all windows and buffers to clean up
      vim.cmd("silent! diffoff!")
      vim.cmd("silent! only")
      vim.cmd("silent! enew")
    end
  end
  -- Owned staging dirs go LAST, after the tab/windows above are gone,
  -- so no window is left displaying a removed file. stop() is
  -- deliberately not wired to VimLeavePre: the autoflush there must
  -- finish its send first, and leaking dirs on a hard exit is the
  -- accepted trade (in-session stop/restart is what must not leak).
  cleanup_stage_dirs(stage_dirs)
  return true
end

---Start a review by resolving `fargs` ASYNCHRONOUSLY — the
---`:PjollrigReview` path. Returns within the caller's frame: the shell
---(tab + panel with a resolving spinner) opens immediately, and the
---resolver's callback attaches the file pairs when staging completes.
---
---Cancellation: `:PjollrigReviewStop` (or a second `:PjollrigReview`,
---which supersedes) during the resolve tears the shell down normally;
---the resolve keeps running unobserved and its late callback finds the
---generation stale, deletes the job's now-ownerless staging dirs, and
---does nothing else. A late resolver FAILURE on the live generation
---notifies ERROR and closes the shell (the stop() path).
---@param fargs string[] `:PjollrigReview` arguments
---@param opts? {cwd?: string, stage_dir?: string} resolver options (tests)
function M.start_async(fargs, opts)
  fargs = fargs or {}
  -- Placeholder label for the resolving shell; attach() replaces it
  -- with the resolver's real label.
  local label = #fargs > 0 and table.concat(fargs, " ") or "HEAD"
  local gen = begin(label)
  require("pjollrig.review.sources").resolve_async(fargs, opts or {}, function(job, err)
    local live = session ~= nil and session.resolving == true and session.generation == gen
    if not live then
      -- Stale resolve: the session was stopped or superseded while we
      -- staged. Nothing owns the job's staging dirs anymore — delete
      -- them instead of leaking (a caller-provided stage_dir is not in
      -- stage_dirs and stays the caller's, as always).
      if job then
        cleanup_stage_dirs(job.stage_dirs)
      end
      return
    end
    if not job then
      M.stop()
      vim.notify(err or "pjollrig: cannot resolve review", vim.log.levels.ERROR)
      return
    end
    attach(job)
  end)
end

---Count the session's pending comments without side effects. Records
---previously imported from GitHub are excluded: old stored imports
---must not be echoed back as new local feedback. The
---uris/root filters come from the session cache (see
---build_session_cache).
local function pending_comments()
  if not session then
    return {}
  end
  return require("pjollrig").list({ uris = session.uri_set, exclude_imported = true }, { root = session.root })
end

---Dispatch the session's pending comments to the configured sink
---(async, through pjollrig.send — dispatch failures notify from its
---callback). Pure up to that dispatch: the pre-flight failures below
---return instead of notifying; the command layer
---(`:PjollrigReviewFinish`) notifies on false, and
---the VimLeavePre autoflush pre-checks session/sink/pending so its
---direct call cannot fail.
---@param opts? {sink?: string} override the session's sink for this send
---@return boolean ok, string|nil err false when there is no session, no sink, or nothing to send
function M.finish(opts)
  opts = opts or {}
  if not session then
    return false, "pjollrig: no active review session"
  end
  local sink = opts.sink or session.sink
  if not sink then
    return false, "pjollrig: review session has no sink configured"
  end
  local comments = pending_comments()
  if #comments == 0 then
    return false, "pjollrig: review has no comments to send"
  end
  -- send() re-lists internally — its contract takes a filter, never
  -- pre-fetched records — so the pending_comments() gate above plus
  -- this call cost two list() passes. Avoiding that needs a
  -- records-accepting send() in init.lua; with the cached uris/root
  -- each pass is cheap, so the double list stays.
  require("pjollrig").send(
    sink,
    { uris = session.uri_set, exclude_imported = true },
    session.ctx,
    { root = session.root }
  )
  return true
end

---Start a review from a JSON job file written by an external driver
---(e.g. a coding-agent extension). Errors are returned AND notified so
---headless drivers see them on stderr.
---@param path string
---@return boolean ok, string|nil err
function M.start_from_job(path)
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    local err = ("pjollrig: cannot read job file %s"):format(path)
    vim.notify(err, vim.log.levels.ERROR)
    return false, err
  end
  local ok_decode, job = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(job) ~= "table" or type(job.files) ~= "table" then
    local err = ("pjollrig: invalid job file %s"):format(path)
    vim.notify(err, vim.log.levels.ERROR)
    return false, err
  end
  local ctx = nil
  local sink = nil
  if type(job.return_socket) == "string" and job.return_socket ~= "" then
    sink = "socket"
    ctx = { socket = job.return_socket, job = job.id, label = job.label }
  end
  local ok, err = M.start({
    files = job.files,
    label = job.label or "review",
    sink = sink,
    ctx = ctx,
    -- External drivers own their staged files: stop() deletes them only
    -- when the job opts in by listing them under `stage_dirs`.
    stage_dirs = type(job.stage_dirs) == "table" and job.stage_dirs or nil,
  })
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
  end
  return ok, err
end

---Milliseconds the VimLeavePre autoflush blocks waiting for the sink to
---settle. The socket sink writes its never-lose-comments submit.json
---fallback only when its ack timer fires, so the wait must outlive the
---configured `ack_timeout_ms` (plus margin for the scheduled fallback
---write) — a hard-coded 2500 lost comments for any timeout >= 2500. The
---historical 2500 stays as the floor. Exposed for tests.
---@return integer
function M._autoflush_wait_ms()
  local sinks_cfg = require("pjollrig.config").get().sinks or {}
  local socket_cfg = type(sinks_cfg.socket) == "table" and sinks_cfg.socket or {}
  local ack = tonumber(socket_cfg.ack_timeout_ms) or 2000
  return math.max(2500, ack + 500)
end

local augroup = vim.api.nvim_create_augroup("PjollrigReview", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    if session and session.sink and #pending_comments() > 0 then
      -- Block until the async sink settles or times out so the submit/fallback
      -- completes before nvim exits. The wait is derived from the socket
      -- sink's configured ack_timeout_ms: any shorter and nvim exits before
      -- the sink's submit.json fallback timer ever fires.
      local done = false
      local done_id = vim.api.nvim_create_autocmd("User", {
        pattern = "PjollrigSent",
        once = true,
        callback = function()
          done = true
        end,
      })
      M.finish()
      vim.wait(M._autoflush_wait_ms(), function()
        return done
      end, 50, false)
      pcall(vim.api.nvim_del_autocmd, done_id)
    end
  end,
})

return M
