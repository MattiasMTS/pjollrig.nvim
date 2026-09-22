-- pjollrig.nvim: review panel — an owned scratch-buffer window.
--
-- Auto-opens on session start as a plain `pjollrig://panel` buffer
-- (filetype `pjollrig-panel`), so j/k/search/marks all behave like any
-- normal buffer and the GLOBAL quickfix list stays free for the user
-- during reviews. Placement comes from `review.panel.position`: a
-- full-width "bottom" split (default), a full-height "left"/"right"
-- column, or a centered "float" (which takes focus; `q` closes it).
--
-- Two views share the window as Pierre-style TABS — `Files 12 │
-- Comments 5` in the winbar, active tab emphasized, `N/M viewed`
-- progress right-aligned — switched with `L` (next) / `H` (previous),
-- wrapping. The Files tab renders one row per pair — `<icon> [M] path
-- +12 −4  · N comments` — with a per-file diffstat and live comment
-- counts (a baseline-less `doc` pair renders a dim `[·]` and no
-- diffstat); the OPEN pair's line is marked with a `▸ ` overlay, a
-- full-line `PjollrigPanelCurrent` background, and a bold filename;
-- VIEWED pairs (`v`, or auto-marked by next/prev) get a `✓ ` lead and
-- dim. The tab has two LAYOUTS — `t` toggles them for the session,
-- `review.panel.layout` picks the default: "flat" lists full paths,
-- one row per pair; "tree" groups the same pairs by directory (Pierre
-- style): `▾/▸` directory rows carry rolled-up diffstat/comment counts
-- and a viewed indicator (`✓` all viewed, `●` otherwise), nest by two
-- spaces per level with single-child chains collapsed into one row,
-- and toggle collapse with <CR>/za (`v` marks the subtree viewed);
-- file rows keep the flat shape with basename labels. File rows behave
-- IDENTICALLY in both layouts: <CR> drills into a commented pair's
-- comments (or opens the pair when it has none) and `o` always opens
-- the pair. <Esc> returns to files from the comments view (clearing
-- any drill-down scope); switching tabs also clears the scope.
--
-- Outside a review session, `:PjollrigList` opens the same panel in
-- PROJECT mode (M.list): a single `Comments N · project` tab listing
-- every project comment — same rows, same dd/ce/u/<C-r> maps, <CR>
-- jumps to the file in the previous window, `q` closes in any
-- placement. H/L are not mapped (one tab; the native motions stay)
-- unless a registered tab opted into project mode.
--
-- The tab bar is EXTENSIBLE: `M.register_tab(spec)` (re-exported as
-- `require("pjollrig").register_review_tab`) appends a custom tab
-- after the builtin Files/Comments pair in the H/L cycle. The builtins
-- stay hardcoded; registered tabs render their rows through the same
-- set_lines+extmark pass and store row `data` in line_data under
-- `kind = "custom:<name>"`. The registry mirrors sources.lua/sinks:
-- validated spec table and `_reset_tabs()` test seam.
--
-- All rendering goes through one idempotent `render()` from
-- review.state() + the store: buffer lines plus extmarks in the
-- panel's namespaces, rebuilt wholesale on every refresh — except when
-- the rebuilt rows come out identical, where the write is skipped.
-- Per-row locators live in a module-local `line_data` table (files
-- view: the pair index; comments view: record id + uri + line), which
-- replaces the quickfix `user_data` the previous implementation rode
-- on.

local M = {}

local uv = vim.uv

local PANEL_BUFNAME = "pjollrig://panel"
local PANEL_FILETYPE = "pjollrig-panel"

-- Content extmarks (icon/status/count/resolved spans) and the
-- current-pair marks live in separate namespaces so a pair switch can
-- re-mark the current line without rebuilding — or re-listing — the
-- whole view.
local ns = vim.api.nvim_create_namespace("pjollrig.review.panel")
local ns_current = vim.api.nvim_create_namespace("pjollrig.review.panel.current")

---"files", "comments", or a registered tab's name.
---@type string
local current_view = "files"

---URI scoping the comments view to a single file (set by drill-down
---from the files view); nil means ALL session comments.
---@type string|nil
local file_filter = nil

---Files-tab layout: flat pair rows or the directory tree. Session-
---scoped like `collapsed`: seeded from `review.panel.layout` on first
---use, flipped by `t`, survives refreshes/tab switches/toggle
---hide-reopen, reset by close() (session stop).
---@type "flat"|"tree"|nil
local layout = nil

---The Files tab's layout for this session, seeding it from the config
---default on first use.
---@return "flat"|"tree"
local function current_layout()
  if not layout then
    local review_cfg = require("pjollrig.config").get().review or {}
    local cfg = type(review_cfg.panel) == "table" and review_cfg.panel or {}
    layout = cfg.layout == "tree" and "tree" or "flat"
  end
  return layout
end

---True while the panel shows PROJECT comments (`:PjollrigList` outside
---a review session) instead of a session's views. Project mode has a
---single Comments tab and no session state to render from.
local project_mode = false

---Project root captured when the project-mode panel opened — resolved
---from the INVOKING buffer, because later refreshes may run with the
---panel scratch buffer current, where root resolution has nothing to
---walk from. Passed as `_root` on every project-mode list().
---@type string|nil
local project_root = nil

---Collapsed directory rows in the tree view, keyed by the directory
---node's full path. Session-scoped: survives refreshes and toggle
---hide/reopen, reset by close() (session stop).
---@type table<string, true>
local collapsed = {}

---@type integer|nil winid of the panel window
local panel_winid = nil

---@type integer|nil bufnr of the panel scratch buffer
local panel_bufnr = nil

---@type integer|nil autocmd group for live refresh + lifecycle
local augroup = nil

---Per-row locators for the CURRENT render, 1-indexed by buffer line.
---Files view rows carry `pair_index` (+ the byte span of the path for
---the bold current-file mark); comments view rows carry the record
---locator (`id`, `scope`, `project_root`) and jump target (`uri`,
---`line`).
---@type table[]
local line_data = {}

---Lines + view key of the previous render. A refresh that rebuilds
---identical rows (event bursts, mutations on files outside the view)
---skips the buffer rewrite and extmark rebuild. Reset by `hide()` —
---the buffer is recreated on reopen, so nothing rendered survives.
---@type string[]|nil
local last_lines = nil
---View key: "comments", or "files:" plus the layout that rendered.
---@type string|nil
local last_view = nil

---Coalesces `User Pjollrig*` bursts into ONE refresh: a consuming send
---emits PjollrigDeleted PER RECORD, and refreshing inline would run a
---full render per event. The first event of a synchronous burst
---schedules the refresh (same event-loop tick — no timer delay, no
---added latency); the rest find the flag set and no-op. Mirrors
---init.lua's `viewport_refresh_pending`.
local refresh_pending = false

-- ------------------------------------------------------------------
-- Spinner ticker state. ONE shared ~100ms uv timer (see sync_spinner
-- below, defined after refresh) drives every animation the panel has:
-- the winbar spinner next to a busy tab's title and the per-tick row
-- re-render of the current tab while it reports animated(). The timer
-- runs ONLY while some available tab needs frames and the panel window
-- exists — sync_spinner (called from every render) starts it, and the
-- tick itself, hide(), or the next render stop it once nothing spins.
-- ------------------------------------------------------------------

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 100

---@type uv.uv_timer_t|nil live only while something needs frames
local spinner_timer = nil
---Current frame index, advanced per tick (frozen while the timer is
---stopped — harmless, since nothing renders frames then).
local spinner_index = 1
---Comment count of the LAST render, so a winbar-only spinner tick can
---repaint the tab bar without re-listing the store.
local last_comment_count = 0
---Forward declaration: defined with the ticker below (it needs
---refresh/update_winbar), called from render() and M.prefetch().
local sync_spinner

-- ------------------------------------------------------------------
-- Tab registry (see M.register_tab below). Registered tabs append
-- after the builtin Files/Comments pair in the H/L cycle, in
-- registration order; availability is evaluated per render/switch.
-- ------------------------------------------------------------------

---@class pjollrig.PanelTabCtx
---@field session pjollrig.ReviewSession|nil the active review session (nil in project mode)
---@field bufnr integer|nil panel buffer
---@field width integer panel window width (0 while closed)
---@field refresh fun() re-render the open panel; safe from vim.schedule, no-op once the panel is closed
---@field spinner_frame string current spinner frame; advances per ticker tick while anything is busy/animated

---@class pjollrig.PanelRow
---@field text string rendered buffer line
---@field spans? {[1]: integer, [2]: integer, [3]: string}[] byte-range highlights {col, end_col, hl}
---@field data? table lands in the row's line_data entry with kind = "custom:"..name

---@class pjollrig.PanelTab
---@field name string unique id; also the H/L cycle key
---@field title string|fun(ctx: pjollrig.PanelTabCtx): string winbar label, resolved per render (may embed a live count)
---@field available? fun(session: pjollrig.ReviewSession|nil): boolean gate per session (default: always available)
---@field project? boolean also offer the tab in project mode (default: false)
---@field build fun(ctx: pjollrig.PanelTabCtx): pjollrig.PanelRow[] rows for render
---@field keymaps? table<string, fun(row: table|nil, ctx: pjollrig.PanelTabCtx)> buffer-local maps active only while the tab is current
---@field on_show? fun(ctx: pjollrig.PanelTabCtx) called when the tab becomes current via H/L (lazy fetch hook)
---@field on_hide? fun(ctx: pjollrig.PanelTabCtx) called when H/L or <Esc> leaves the tab
---@field prefetch? boolean run on_show once at review-session open (gated by `review.panel.prefetch`), so the tab's data loads before its first show
---@field busy? fun(ctx: pjollrig.PanelTabCtx): boolean report in-flight work: the winbar renders `<title> <frame>` while true
---@field animated? fun(ctx: pjollrig.PanelTabCtx): boolean report animated rows: while the tab is CURRENT and this is true, the ticker re-renders its rows each tick so build() can draw fresh frames/elapsed

---@type pjollrig.PanelTab[] registration order = cycle order
local registered_tabs = {}

---lhs strings of the CURRENT registered tab's applied keymaps, so
---leaving the tab can remove exactly what entering it set.
---@type string[]
local active_tab_keys = {}

---Keys the panel maps for itself (H/L tab cycle, view-guarded maps,
---comment mutations, `q` close in float/project placements). A
---registered tab may not shadow them — validated at register time,
---keyed by termcode so spelling variants (`<esc>`) still match. `<CR>`
---is deliberately NOT reserved: custom rows need an activation key, so
---the panel's own <CR> map routes to the tab's handler instead.
local RESERVED_KEYS = {}
for _, lhs in ipairs({ "H", "L", "<Esc>", "q", "dd", "ce", "u", "<C-r>", "v", "t", "za", "o" }) do
  RESERVED_KEYS[vim.keycode(lhs)] = lhs
end

---@param name string
---@return pjollrig.PanelTab|nil
local function tab_by_name(name)
  for _, tab in ipairs(registered_tabs) do
    if tab.name == name then
      return tab
    end
  end
  return nil
end

---Is the tab offered right now? Project mode excludes registered tabs
---unless the spec opted in; `available(session)` gates per session and
---an erroring gate counts as unavailable.
---@param tab pjollrig.PanelTab
---@return boolean
local function tab_available(tab)
  if project_mode and tab.project ~= true then
    return false
  end
  if tab.available then
    local ok, avail = pcall(tab.available, require("pjollrig.review").state())
    return ok and avail == true
  end
  return true
end

---The H/L cycle: builtins first (hardcoded — Files/Comments in review
---mode, the single Comments tab in project mode), then the AVAILABLE
---registered tabs in registration order.
---@return string[]
local function tab_cycle()
  local cycle = project_mode and { "comments" } or { "files", "comments" }
  for _, tab in ipairs(registered_tabs) do
    if tab_available(tab) then
      cycle[#cycle + 1] = tab.name
    end
  end
  return cycle
end

---Any registered tab that can appear in project mode? Decides whether
---a project-mode panel maps H/L at all (availability is still checked
---per switch).
---@return boolean
local function has_project_tabs()
  for _, tab in ipairs(registered_tabs) do
    if tab.project == true then
      return true
    end
  end
  return false
end

---Per-call ctx handed to a registered tab's title/build/keymaps/hooks.
---`refresh` goes through M.refresh, which already no-ops while the
---panel is hidden — so a tab may safely call it from vim.schedule
---after an async fetch. It re-renders whatever tab is CURRENT (not
---necessarily the caller): simpler than tracking view ownership, and
---a re-render of another view is harmless.
---@return pjollrig.PanelTabCtx
local function tab_ctx()
  return {
    session = require("pjollrig.review").state(),
    bufnr = panel_bufnr,
    width = (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) and vim.api.nvim_win_get_width(panel_winid) or 0,
    spinner_frame = SPINNER_FRAMES[spinner_index],
    refresh = function()
      M.refresh()
    end,
  }
end

---A registered tab's winbar label: a function title is resolved per
---render (live counts), falling back to the tab name on error or a
---non-string result. Escaping happens at the winbar assembly site.
---@param tab pjollrig.PanelTab
---@return string
local function tab_title(tab)
  local title = tab.title
  if type(title) == "function" then
    local ok, result = pcall(title, tab_ctx())
    title = ok and result or nil
  end
  return type(title) == "string" and title or tab.name
end

---Does the tab report in-flight work right now? An erroring probe
---counts as not busy (same tolerance as tab_available).
---@param tab pjollrig.PanelTab
---@return boolean
local function tab_busy(tab)
  if not tab.busy then
    return false
  end
  local ok, busy = pcall(tab.busy, tab_ctx())
  return ok and busy == true
end

---Does the tab want its rows re-rendered per ticker tick?
---@param tab pjollrig.PanelTab
---@return boolean
local function tab_animated(tab)
  if not tab.animated then
    return false
  end
  local ok, animated = pcall(tab.animated, tab_ctx())
  return ok and animated == true
end

---The handler a tab declared for `lhs`, matched by termcode so spelling
---variants (`<cr>` vs `<CR>`) resolve to the same key.
---@param tab pjollrig.PanelTab
---@param lhs string
---@return fun(row: table|nil, ctx: pjollrig.PanelTabCtx)|nil
local function tab_keymap_for(tab, lhs)
  local want = vim.keycode(lhs)
  for declared, fn in pairs(tab.keymaps or {}) do
    if vim.keycode(declared) == want then
      return fn
    end
  end
  return nil
end

---Remove the keymaps the current registered tab applied. Safe when the
---panel buffer is already gone (maps died with it).
local function clear_tab_keymaps()
  if panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr) then
    for _, lhs in ipairs(active_tab_keys) do
      pcall(vim.keymap.del, "n", lhs, { buffer = panel_bufnr })
    end
  end
  active_tab_keys = {}
end

---Register a custom panel tab. Appended after the builtins in the H/L
---cycle; takes effect on the panel's next render when one is open.
---Errors on an invalid spec, a duplicate name, or a keymap over a
---reserved panel key (see RESERVED_KEYS; `<CR>` is allowed).
---@param spec pjollrig.PanelTab
function M.register_tab(spec)
  vim.validate("spec", spec, "table")
  vim.validate("spec.name", spec.name, "string")
  vim.validate("spec.title", spec.title, { "string", "function" })
  vim.validate("spec.build", spec.build, "function")
  vim.validate("spec.available", spec.available, "function", true)
  vim.validate("spec.project", spec.project, "boolean", true)
  vim.validate("spec.keymaps", spec.keymaps, "table", true)
  vim.validate("spec.on_show", spec.on_show, "function", true)
  vim.validate("spec.on_hide", spec.on_hide, "function", true)
  vim.validate("spec.prefetch", spec.prefetch, "boolean", true)
  vim.validate("spec.busy", spec.busy, "function", true)
  vim.validate("spec.animated", spec.animated, "function", true)
  if spec.name == "files" or spec.name == "comments" or tab_by_name(spec.name) then
    error(("pjollrig: panel tab %q is already registered"):format(spec.name))
  end
  for lhs, fn in pairs(spec.keymaps or {}) do
    vim.validate("spec.keymaps key", lhs, "string")
    vim.validate(("spec.keymaps[%q]"):format(lhs), fn, "function")
    local reserved = RESERVED_KEYS[vim.keycode(lhs)]
    if reserved then
      error(("pjollrig: panel tab %q may not override the reserved panel key %q"):format(spec.name, reserved))
    end
  end
  registered_tabs[#registered_tabs + 1] = spec
end

---Internal: exposed for tests. Drops every registered tab; a view left
---pointing at one falls back to the mode's builtin view.
function M._reset_tabs()
  registered_tabs = {}
  clear_tab_keymaps()
  if current_view ~= "files" and current_view ~= "comments" then
    current_view = project_mode and "comments" or "files"
  end
end

-- The session's project root, URI array/set, and uri -> pair-index map
-- all come pre-computed on review.state() (session cache built once in
-- review.start): list() resolves the store root from the CURRENT
-- buffer, and the panel's scratch buffer falls back to cwd — which can
-- miss the reviewed project entirely — so every list() call here
-- passes the cached root as `opts.root` and filters on the cached uri
-- set.

---@param name string
---@return table
local function get_highlight(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

---Define the panel's highlight groups. The current-line surface is a
---PjollrigCardBg-style tint — Normal bg nudged 8% toward Normal fg via
---`ui/color.lua`'s `blend` — recomputed here on every panel open and on
---ColorScheme (the panel augroup re-runs this; render.lua's own
---ColorScheme wiring only covers the card palette). Transparent themes
---(no Normal bg) have nothing to blend from and borrow CursorLine so
---the current pair still stands out. Status/count/resolved groups are
---`default` links, so user overrides win.
local function setup_highlights()
  local normal = get_highlight("Normal")
  if type(normal.bg) == "number" then
    local toward = type(normal.fg) == "number" and normal.fg or normal.bg
    local bg = require("pjollrig.ui.color").blend(normal.bg, toward, 0.08)
    vim.api.nvim_set_hl(0, "PjollrigPanelCurrent", { bg = bg })
  else
    vim.api.nvim_set_hl(0, "PjollrigPanelCurrent", { link = "CursorLine" })
  end
  -- Bold-only group: layered over the path span on the current line,
  -- it combines with (never covers) the line background above.
  vim.api.nvim_set_hl(0, "PjollrigPanelCurrentFile", { bold = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelStatusA", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelStatusD", { link = "DiagnosticError", default = true })
  -- `doc` pairs have no change to color: their `[·]` dims like the tails.
  vim.api.nvim_set_hl(0, "PjollrigPanelStatusDoc", { link = "Comment", default = true })
  -- M (and any other status) stays default text on purpose — most of a
  -- review is modifications, and coloring all of them is noise.
  vim.api.nvim_set_hl(0, "PjollrigPanelAdded", { link = "Added", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelRemoved", { link = "Removed", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelCount", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelResolved", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelViewed", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelDir", { link = "Directory", default = true })
  -- Winbar tab bar: inactive tabs dim like the other muted panel text;
  -- the active tab borrows Title — the stock bold/accent combo — so it
  -- reads emphasized on any palette. Both are default links.
  vim.api.nvim_set_hl(0, "PjollrigPanelTab", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PjollrigPanelTabActive", { link = "Title", default = true })
end

---Winbars run through the statusline engine: literal `%` in dynamic
---text must double or it becomes a statusline item.
---@param text string
---@return string
local function winbar_escape(text)
  return (text:gsub("%%", "%%%%"))
end

---@class pjollrig.review.panel.Row
---@field text string rendered buffer line
---@field spans {[1]: integer, [2]: integer, [3]: string}[] byte-range highlights
---@field data table locator stored into `line_data`

---Spans for a VIEWED row: keep the diffstat (+/−) spans colored —
---Pierre keeps them visible — and dim everything around them with
---`PjollrigPanelViewed` segments (which replace the icon/status/count
---spans, so no two foreground marks compete on the same bytes).
---@param spans {[1]: integer, [2]: integer, [3]: string}[] built left-to-right
---@param text_len integer row byte length
---@return {[1]: integer, [2]: integer, [3]: string}[]
local function viewed_spans(spans, text_len)
  local out = {}
  local pos = 0
  for _, span in ipairs(spans) do
    if span[3] == "PjollrigPanelAdded" or span[3] == "PjollrigPanelRemoved" then
      if span[1] > pos then
        out[#out + 1] = { pos, span[1], "PjollrigPanelViewed" }
      end
      out[#out + 1] = span
      pos = span[2]
    end
  end
  if pos < text_len then
    out[#out + 1] = { pos, text_len, "PjollrigPanelViewed" }
  end
  return out
end

---Shared per-render inputs for pair/dir rows: live comment counts (ONE
---list() call per render), icon availability, the cached session
---diffstat, and viewed marks. nil without a session.
---@return table|nil
local function pair_row_ctx()
  local review = require("pjollrig.review")
  local state = review.state()
  if not state then
    return nil
  end

  local counts = {}
  -- `sync = false`: the panel is a read-only surface rendering right
  -- after a mutation, whose path already synced extmark positions —
  -- skip the editor-wide position sweep on every render (all the
  -- session-view list() call sites here pass it).
  local records = require("pjollrig").list({ uris = state.uri_set }, { sync = false, root = state.root })
  for _, record in ipairs(records) do
    counts[record.uri] = (counts[record.uri] or 0) + 1
  end

  local icons = require("pjollrig.ui.icons")
  return {
    state = state,
    counts = counts,
    -- Session comment total for the winbar's Comments tab — derived
    -- from the SAME list() call as the per-file counts.
    comment_total = #records,
    icons = icons,
    with_icons = icons.enabled(),
    -- Per-pair {added, removed} counts, computed once per session on the
    -- first render and cached on the session (see review.diffstat) —
    -- deliberately NOT refreshed when the worktree side changes mid-review.
    diffstat = review.diffstat() or {},
    viewed = state.viewed or {},
  }
end

---Append the `  +A −R` diffstat segment, zero components omitted (A/D
---pairs naturally show one side; an all-zero stat renders nothing).
---@param parts string[]
---@param spans {[1]: integer, [2]: integer, [3]: string}[]
---@param col integer current row byte length
---@param added integer
---@param removed integer
---@return integer col after the segment
local function append_stat(parts, spans, col, added, removed)
  if added <= 0 and removed <= 0 then
    return col
  end
  parts[#parts + 1] = "  "
  col = col + 2
  if added > 0 then
    local text = ("+%d"):format(added)
    parts[#parts + 1] = text
    spans[#spans + 1] = { col, col + #text, "PjollrigPanelAdded" }
    col = col + #text
    if removed > 0 then
      parts[#parts + 1] = " "
      col = col + 1
    end
  end
  if removed > 0 then
    local text = ("\u{2212}%d"):format(removed)
    parts[#parts + 1] = text
    spans[#spans + 1] = { col, col + #text, "PjollrigPanelRemoved" }
    col = col + #text
  end
  return col
end

---Append the dim `  · N comments` tail.
---@return integer col after the segment
local function append_count(parts, spans, col, count)
  local text = ("  \u{00B7} %d comments"):format(count)
  parts[#parts + 1] = text
  spans[#spans + 1] = { col, col + #text, "PjollrigPanelCount" }
  return col + #text
end

---One pair row: `<indent><lead><icon> [S] label  +A −R  · N comments`.
---The flat layout renders the full pair path with no indent; the tree
---layout indents by nesting depth and labels with the basename. The
---two-cell lead reserves the current-pair marker column (`▸ ` overlays
---it on the open pair) so columns never shift; viewed pairs render a
---`✓ ` lead (same two cells) and dim.
---@param idx integer pair index
---@param label string rendered path text
---@param indent string leading spaces ("" in the flat layout)
---@param ctx table from pair_row_ctx
---@return pjollrig.review.panel.Row
local function pair_row(idx, label, indent, ctx)
  local pair = ctx.state.files[idx]
  local is_viewed = ctx.viewed[idx] == true
  local lead = is_viewed and "\u{2713} " or "  "
  local parts = { indent, lead }
  local spans = {}
  local col = #indent + #lead
  if ctx.with_icons then
    -- One glyph + one space (a blank cell when the provider yields
    -- nothing) keeps the column aligned; the provider's highlight
    -- group rides along as an extmark — the old quickfix substrate
    -- could carry the glyph but never its color.
    local icon, icon_hl = ctx.icons.file_icon(pair.path)
    local glyph = icon or " "
    parts[#parts + 1] = glyph .. " "
    if icon and icon_hl then
      spans[#spans + 1] = { col, col + #glyph, icon_hl }
    end
    col = col + #glyph + 1
  end
  -- A `doc` pair keeps the three-cell column with a dim `[·]`.
  local is_doc = pair.status == "doc"
  local status = is_doc and "[\u{00B7}]" or ("[%s]"):format(pair.status)
  local status_hl = pair.status == "A" and "PjollrigPanelStatusA"
    or pair.status == "D" and "PjollrigPanelStatusD"
    or is_doc and "PjollrigPanelStatusDoc"
    or nil
  parts[#parts + 1] = status .. " "
  if status_hl then
    spans[#spans + 1] = { col, col + #status, status_hl }
  end
  col = col + #status + 1
  local path_start = col
  parts[#parts + 1] = label
  col = col + #label
  local stat = ctx.diffstat[idx] or {}
  col = append_stat(parts, spans, col, stat.added or 0, stat.removed or 0)
  append_count(parts, spans, col, ctx.counts[ctx.state.uris[idx]] or 0)
  local text = table.concat(parts)
  if is_viewed then
    spans = viewed_spans(spans, #text)
  end
  return {
    text = text,
    spans = spans,
    data = {
      kind = "file",
      pair_index = idx,
      path_start = path_start,
      path_end = path_start + #label,
      lead_col = #indent,
    },
  }
end

---Files view rows: one per session pair, full path, no indent.
---@return pjollrig.review.panel.Row[] rows, integer comment_total
local function build_file_rows()
  local ctx = pair_row_ctx()
  if not ctx then
    return {}, 0
  end
  local rows = {}
  for idx, pair in ipairs(ctx.state.files) do
    rows[#rows + 1] = pair_row(idx, pair.path, "", ctx)
  end
  return rows, ctx.comment_total
end

---@class pjollrig.review.panel.DirNode
---@field name string row label; single-child chains collapse into "a/b"
---@field path string full directory path — the collapse-state key
---@field dirs pjollrig.review.panel.DirNode[] child dirs, first-seen order
---@field files integer[] pair indexes directly in this directory

---Group the session pairs by directory (pair.path split on "/").
---Chains of single-child directories holding no files of their own
---collapse into one node ("lua" → "pjollrig" renders as one
---`lua/pjollrig` row) — Pierre does this to keep trees shallow.
---@param files {path: string}[]
---@return pjollrig.review.panel.DirNode root
local function build_tree(files)
  local root = { name = "", path = "", dirs = {}, files = {} }
  local by_path = {}
  for idx, pair in ipairs(files) do
    local node = root
    local parts = vim.split(pair.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      local path = node.path == "" and parts[i] or (node.path .. "/" .. parts[i])
      local child = by_path[path]
      if not child then
        child = { name = parts[i], path = path, dirs = {}, files = {} }
        by_path[path] = child
        node.dirs[#node.dirs + 1] = child
      end
      node = child
    end
    node.files[#node.files + 1] = idx
  end
  local function collapse_chains(node)
    for _, child in ipairs(node.dirs) do
      while #child.dirs == 1 and #child.files == 0 do
        local only = child.dirs[1]
        child.name = child.name .. "/" .. only.name
        child.path = only.path
        child.dirs = only.dirs
        child.files = only.files
      end
      collapse_chains(child)
    end
  end
  collapse_chains(root)
  return root
end

---Recursive subtree totals for one directory node: summed diffstat,
---summed comment counts, and whether EVERY file inside is viewed.
---@return integer added, integer removed, integer comments, boolean all_viewed
local function dir_rollup(node, ctx)
  local added, removed, comments = 0, 0, 0
  local all_viewed = true
  for _, idx in ipairs(node.files) do
    local stat = ctx.diffstat[idx]
    if stat then
      added = added + stat.added
      removed = removed + stat.removed
    end
    comments = comments + (ctx.counts[ctx.state.uris[idx]] or 0)
    if not ctx.viewed[idx] then
      all_viewed = false
    end
  end
  for _, child in ipairs(node.dirs) do
    local a, r, c, v = dir_rollup(child, ctx)
    added, removed, comments = added + a, removed + r, comments + c
    if not v then
      all_viewed = false
    end
  end
  return added, removed, comments, all_viewed
end

---One directory row: `<indent>▾ name  +A −R  · N comments  ●` with a
---`▸` disclosure when collapsed and a `✓` indicator once every file in
---the subtree is viewed.
---@return pjollrig.review.panel.Row
local function dir_row(node, depth, is_collapsed, ctx)
  local added, removed, comments, all_viewed = dir_rollup(node, ctx)
  local indent = ("  "):rep(depth)
  local glyph = is_collapsed and "\u{25B8}" or "\u{25BE}"
  local parts = { indent, glyph, " ", node.name }
  local col = #indent + #glyph + 1 + #node.name
  local spans = { { #indent, col, "PjollrigPanelDir" } }
  col = append_stat(parts, spans, col, added, removed)
  col = append_count(parts, spans, col, comments)
  local mark = all_viewed and "\u{2713}" or "\u{25CF}"
  parts[#parts + 1] = "  " .. mark
  spans[#spans + 1] = { col + 2, col + 2 + #mark, "PjollrigPanelViewed" }
  return {
    text = table.concat(parts),
    spans = spans,
    data = { kind = "dir", dir = node.path },
  }
end

---Tree layout rows: the node's own files first (basename labels), then
---its child directories, depth-first, skipping the subtrees of
---collapsed directories (their rows still show the full rollup).
local function append_tree_rows(node, depth, rows, ctx)
  local indent = ("  "):rep(depth)
  for _, idx in ipairs(node.files) do
    local path = ctx.state.files[idx].path
    rows[#rows + 1] = pair_row(idx, path:match("[^/]+$") or path, indent, ctx)
  end
  for _, child in ipairs(node.dirs) do
    local is_collapsed = collapsed[child.path] == true
    rows[#rows + 1] = dir_row(child, depth, is_collapsed, ctx)
    if not is_collapsed then
      append_tree_rows(child, depth + 1, rows, ctx)
    end
  end
end

---@return pjollrig.review.panel.Row[] rows, integer comment_total
local function build_tree_rows()
  local ctx = pair_row_ctx()
  if not ctx then
    return {}, 0
  end
  local rows = {}
  append_tree_rows(build_tree(ctx.state.files), 0, rows, ctx)
  return rows, ctx.comment_total
end

---Comments view rows, one per record in canonical `uri → line → id`
---order: `[✓ ][x] path:lnum  first body line`. Resolved records keep
---the existing conventions — `[x]` for locally-resolved, a `✓` prefix
---for legacy imported resolved threads (meta.github.resolved)
---— and both render dimmed.
---@param records? table[] pre-fetched records for the CURRENT filter
---(uri-scoped when `file_filter` is set); fetched here when nil.
---@return pjollrig.review.panel.Row[] rows, integer comment_total
local function build_comment_rows(records)
  local state = require("pjollrig.review").state()
  if not records then
    if project_mode then
      -- Project mode lists EVERY project comment. It keeps the
      -- editor-wide position sync (the default): this is a user-invoked
      -- view over live buffers, so row line numbers must follow moved
      -- extmarks — the review views pass `sync = false` only because
      -- their renders always trail an already-synced mutation.
      records = require("pjollrig").list(nil, { root = project_root })
    else
      local uris = file_filter and { [file_filter] = true } or (state and state.uri_set or {})
      records = require("pjollrig").list({ uris = uris }, { sync = false, root = state and state.root or nil })
    end
  end
  local range = require("pjollrig.range")
  local str = require("pjollrig.str")

  -- `pjollrig.list()` already returns a fresh array sorted by
  -- `range.compare` — the canonical order — so the records are used
  -- as-is.
  local rows = {}
  for _, record in ipairs(records) do
    local meta = type(record.meta) == "table" and record.meta or nil
    local gh = meta and type(meta.github) == "table" and meta.github or nil
    local gh_resolved = gh ~= nil and gh.resolved == true

    -- Display path: the session pair's relative path when the record
    -- maps to one (uri -> pair index straight off the session cache);
    -- in project mode the path relative to the project root; else the
    -- file's tail.
    local label
    local pair_index = state and state.uri_index and state.uri_index[record.uri] or nil
    if pair_index and state.files[pair_index] then
      label = state.files[pair_index].path
    else
      local path = require("pjollrig.uri").to_path(record.uri)
      if path and project_root and path:sub(1, #project_root + 1) == project_root .. "/" then
        label = path:sub(#project_root + 2)
      else
        label = path and vim.fn.fnamemodify(path, ":t") or record.uri
      end
    end

    local sl = range.start_line(record)
    local el = range.end_line(record)
    local loc = (el and el > sl) and ("%s:%d-%d"):format(label, sl, el) or ("%s:%d"):format(label, sl)
    local marker = record.resolved and "[x]" or "[ ]"
    local first = vim.split(record.body or "", "\n", { plain = true })[1] or ""
    local prefix = gh_resolved and "\u{2713} " or ""
    local text = ("%s%s %s  %s"):format(prefix, marker, loc, str.truncate(first, 160))
    local spans = {}
    if gh_resolved or record.resolved then
      spans[#spans + 1] = { 0, #text, "PjollrigPanelResolved" }
    end
    rows[#rows + 1] = {
      text = text,
      spans = spans,
      data = {
        kind = "comment",
        id = record.id,
        scope = record.scope,
        project_root = record.project_root,
        uri = record.uri,
        line = sl,
      },
    }
  end
  return rows, #records
end

---1-indexed panel row rendering the given pair, or nil when the row is
---not on screen (tree layout: hidden inside a collapsed directory). In
---the flat layout the row number equals the pair index; the scan keeps
---one code path for both layouts.
---@param pair_index integer
---@return integer|nil
local function pair_row_number(pair_index)
  for row, data in ipairs(line_data) do
    if data.pair_index == pair_index then
      return row
    end
  end
  return nil
end

---Mark the OPEN pair's row (Files tab, either layout): a `▸ ` overlay on
---the row's lead column, a full-line `PjollrigPanelCurrent` background,
---and a bold filename. Lives in its own namespace so a pair switch
---re-marks without a re-render (and without re-querying the store).
---No row is marked when the pair is hidden in a collapsed directory.
local function apply_current_marks()
  if not (panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(panel_bufnr, ns_current, 0, -1)
  if current_view ~= "files" then
    return
  end
  local state = require("pjollrig.review").state()
  local index = state and state.index
  local row = index and pair_row_number(index)
  if not row then
    return
  end
  local data = line_data[row]
  pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns_current, row - 1, data.lead_col or 0, {
    line_hl_group = "PjollrigPanelCurrent",
    virt_text = { { "\u{25B8} ", "PjollrigPanelCurrent" } },
    virt_text_pos = "overlay",
  })
  pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns_current, row - 1, data.path_start, {
    end_col = data.path_end,
    hl_group = "PjollrigPanelCurrentFile",
  })
end

---The panel winbar: a Pierre-style tab bar — `Files 12 │ Comments 5`,
---active tab in `PjollrigPanelTabActive` — with the `3/12 viewed`
---progress right-aligned via `%=`. Registered tabs follow the builtins
---with their `title` resolved per render (escaped like everything else
---dynamic). Project mode shows `Comments N · project` plus any
---project-capable registered tabs. The winbar is the panel's only
---title surface, and it is native and cheap.
---@param comment_count? integer comments listed by the current render
local function update_winbar(comment_count)
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  local state = require("pjollrig.review").state()
  if not project_mode and not state then
    return
  end
  -- While a resolve is in flight the Files tab is the busy one: its
  -- count is unknown, so the title carries the spinner frame instead
  -- (the same busy convention registered tabs get).
  local resolving = state ~= nil and state.resolving == true
  local labels = {
    files = state and (resolving and ("Files %s"):format(SPINNER_FRAMES[spinner_index]) or ("Files %d"):format(
      #state.files
    )) or "Files",
    comments = ("Comments %d"):format(comment_count or 0),
  }
  local parts = {}
  for _, view in ipairs(tab_cycle()) do
    local hl = view == current_view and "PjollrigPanelTabActive" or "PjollrigPanelTab"
    local label = labels[view]
    if not label then
      local tab = tab_by_name(view)
      label = tab and tab_title(tab) or view
      -- Busy tabs spin in the tab bar: `<title> <frame>`, the frame
      -- advanced by the shared ticker (see sync_spinner). The spinner
      -- rides the winbar only — busy never rebuilds rows.
      if tab and tab_busy(tab) then
        label = label .. " " .. SPINNER_FRAMES[spinner_index]
      end
    end
    parts[#parts + 1] = ("%%#%s#%s"):format(hl, winbar_escape(label))
  end
  local bar = table.concat(parts, "%#PjollrigPanelTab# \u{2502} ")
  if project_mode then
    vim.wo[panel_winid].winbar = bar .. "%#PjollrigPanelTab# \u{00B7} project"
    return
  end
  local progress
  if resolving then
    progress = "resolving\u{2026}"
  else
    local viewed = 0
    for _ in pairs(state.viewed or {}) do
      viewed = viewed + 1
    end
    progress = ("%d/%d viewed"):format(viewed, #state.files)
  end
  -- `%*` after `%=` resets to the plain WinBar highlight for the
  -- right-aligned progress.
  vim.wo[panel_winid].winbar = bar .. "%=%*" .. winbar_escape(progress)
end

---Comment total for the winbar while a REGISTERED tab renders: the
---builtin views derive it from the list() call that built their rows;
---a custom tab has no such call, so query the store directly (same
---filters as build_comment_rows).
---@return integer
local function session_comment_count()
  if project_mode then
    return #require("pjollrig").list(nil, { root = project_root })
  end
  local state = require("pjollrig.review").state()
  if not state then
    return 0
  end
  return #require("pjollrig").list({ uris = state.uri_set }, { sync = false, root = state.root })
end

---Rows for a REGISTERED tab: spec.build(ctx) through the same
---set_lines+extmark pass as the builtin views. Row `data` lands in
---line_data under `kind = "custom:<name>"` (copied, so a build may
---reuse its tables). A failing build renders an empty tab with a
---notification instead of breaking the panel's event-driven refreshes.
---@param tab pjollrig.PanelTab
---@return pjollrig.review.panel.Row[]
local function build_tab_rows(tab)
  local ok, result = pcall(tab.build, tab_ctx())
  if not ok then
    vim.notify(("pjollrig: panel tab %q build failed: %s"):format(tab.name, result), vim.log.levels.ERROR)
    return {}
  end
  local rows = {}
  for _, row in ipairs(type(result) == "table" and result or {}) do
    local data = { kind = "custom:" .. tab.name }
    for k, v in pairs(type(row.data) == "table" and row.data or {}) do
      if k ~= "kind" then
        data[k] = v
      end
    end
    rows[#rows + 1] = { text = tostring(row.text or ""), spans = row.spans or {}, data = data }
  end
  return rows
end

---Rebuild the panel buffer from state: lines, content extmarks, and
---`line_data`, then the current-pair marks. Idempotent; never moves
---the cursor or focus.
---@param comment_records? table[] pre-fetched records for a comments
---view render (see build_comment_rows); ignored in other views.
local function render(comment_records)
  if not (panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  -- A registered tab that vanished (unregistered) or became
  -- unavailable while current falls back to the mode's builtin view,
  -- keeping the winbar (built from the availability-filtered cycle)
  -- and the rendered rows in agreement.
  local custom = tab_by_name(current_view)
  if current_view ~= "files" and current_view ~= "comments" and not (custom and tab_available(custom)) then
    clear_tab_keymaps()
    current_view = project_mode and "comments" or "files"
    custom = nil
  end
  local state = require("pjollrig.review").state()
  local resolving = state ~= nil and state.resolving == true
  local rows, comment_count
  local view_key = current_view
  if custom then
    view_key = "custom:" .. custom.name
    rows = build_tab_rows(custom)
    comment_count = session_comment_count()
  elseif current_view == "files" then
    view_key = "files:" .. current_layout()
    if resolving then
      -- The resolve is still staging (review shell open, no pairs
      -- yet): one placeholder row, animated by the shared ticker.
      local text = ("%s resolving %s\u{2026}"):format(SPINNER_FRAMES[spinner_index], state.label)
      rows = { { text = text, spans = { { 0, #text, "PjollrigPanelCount" } }, data = { kind = "resolving" } } }
      comment_count = 0
    elseif current_layout() == "tree" then
      rows, comment_count = build_tree_rows()
    else
      rows, comment_count = build_file_rows()
    end
  else
    rows, comment_count = build_comment_rows(comment_records)
  end
  -- After the row build: the tab bar's Comments count derives from the
  -- same list() call that produced the rows. The count is kept for the
  -- ticker's winbar-only repaints, and the ticker itself is started or
  -- stopped to match what this render revealed (a fetch beginning or
  -- ending, animation gaining/losing its subject).
  last_comment_count = comment_count or 0
  update_winbar(comment_count)
  sync_spinner()

  local lines = {}
  line_data = {}
  for i, row in ipairs(rows) do
    lines[i] = row.text
    line_data[i] = row.data
  end

  -- Same view, identical lines: the content extmark spans derive from
  -- the row text, so only the current-pair marks can differ — re-apply
  -- those and skip the buffer rewrite + extmark rebuild.
  if last_view == view_key and vim.deep_equal(last_lines, lines) then
    apply_current_marks()
    return
  end
  last_view = view_key
  last_lines = lines

  vim.bo[panel_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(panel_bufnr, 0, -1, false, lines)
  vim.bo[panel_bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(panel_bufnr, ns, 0, -1)
  for i, row in ipairs(rows) do
    for _, span in ipairs(row.spans) do
      pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns, i - 1, span[1], {
        end_col = span[2],
        hl_group = span[3],
      })
    end
  end
  apply_current_marks()
end

---Re-render the current view, preserving the panel cursor position
---(clamped to the new line count) across the rebuild.
---@param comment_records? table[] see build_comment_rows
local function refresh(comment_records)
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  local saved = vim.api.nvim_win_get_cursor(panel_winid)
  render(comment_records)
  local max_row = math.max(1, #line_data)
  pcall(vim.api.nvim_win_set_cursor, panel_winid, { math.min(saved[1], max_row), saved[2] })
end

-- ------------------------------------------------------------------
-- Spinner ticker (state and forward declaration near the top). One
-- timer serves every tab; each tick advances the frame and does the
-- CHEAPEST repaint that shows it: a full row refresh only when the
-- current tab is animated, otherwise just the winbar (busy titles).
-- ------------------------------------------------------------------

local function stop_spinner()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

---Is the review session mid-resolve (shell open, resolver staging)?
---The panel is that state's surface: the Files tab shows the animated
---placeholder row and the winbar the busy Files title.
---@return boolean
local function session_resolving()
  local state = require("pjollrig.review").state()
  return state ~= nil and state.resolving == true
end

---Does anything need frames right now? True while the panel window is
---up and the session is resolving, some available registered tab
---reports busy(), or the CURRENT tab reports animated(). This is the
---ticker's run condition — checked per tick, so the timer stops itself
---the moment everything settles.
---@return boolean
local function spinner_needed()
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return false
  end
  if session_resolving() then
    return true
  end
  for _, tab in ipairs(registered_tabs) do
    if tab_available(tab) and (tab_busy(tab) or (tab.name == current_view and tab_animated(tab))) then
      return true
    end
  end
  return false
end

local function spinner_tick()
  if not spinner_needed() then
    stop_spinner()
    return
  end
  spinner_index = spinner_index % #SPINNER_FRAMES + 1
  local tab = tab_by_name(current_view)
  if (tab and tab_animated(tab)) or (session_resolving() and current_view == "files") then
    -- Animated rows: a full refresh so build() draws the fresh frame
    -- and recomputes anything time-derived (elapsed counters). The
    -- resolving placeholder is a single animated row, same deal.
    refresh()
  else
    -- Busy titles only: resetting the winbar is cheap and never
    -- rebuilds rows.
    update_winbar(last_comment_count)
  end
end

---Start the ticker when spinner_needed(), stop it otherwise. Called
---from every render and from M.prefetch (fetches kicked off before any
---render notices them); hide() stops the timer directly, so it can
---never outlive the panel window.
function sync_spinner()
  if not spinner_needed() then
    stop_spinner()
    return
  end
  if spinner_timer then
    return
  end
  spinner_timer = uv.new_timer()
  if spinner_timer then
    spinner_timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, vim.schedule_wrap(spinner_tick))
  end
end

---Locator under the cursor. Keymaps are buffer-local to the panel, so
---the cursor row indexes straight into the current render's line_data.
---@return table|nil
local function data_at_cursor()
  return line_data[vim.api.nvim_win_get_cursor(0)[1]]
end

---Pair index under the cursor (files view).
---@return integer|nil
local function pair_index_at_cursor()
  local data = data_at_cursor()
  if type(data) == "table" and type(data.pair_index) == "number" then
    return data.pair_index
  end
  return nil
end

---Comment locator (uri + line) under the cursor (comments view).
---@return {uri: string, line: integer}|nil
local function comment_at_cursor()
  local data = data_at_cursor()
  if type(data) == "table" and type(data.uri) == "string" and data.uri ~= "" then
    return { uri = data.uri, line = tonumber(data.line) or 1 }
  end
  return nil
end

---Record locator (id + scope + project root) under the cursor
---(comments view).
---@return {id: string, scope?: string, project_root?: string}|nil
local function record_locator_at_cursor()
  local data = data_at_cursor()
  if type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
    return { id = data.id, scope = data.scope, project_root = data.project_root }
  end
  return nil
end

---Apply a registered tab's keymaps to the panel buffer (entering the
---tab). Each handler receives the line_data entry under the cursor and
---a fresh ctx. `<CR>` is skipped: the panel's own <CR> map routes to
---the tab handler, so entering/leaving never has to restore the base
---map that a set/del pair would destroy.
---@param tab pjollrig.PanelTab|nil
local function apply_tab_keymaps(tab)
  clear_tab_keymaps()
  if not (tab and tab.keymaps and panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  for lhs, fn in pairs(tab.keymaps) do
    if vim.keycode(lhs) ~= vim.keycode("<CR>") then
      vim.keymap.set("n", lhs, function()
        fn(data_at_cursor(), tab_ctx())
      end, {
        buffer = panel_bufnr,
        nowait = true,
        silent = true,
        desc = ("Pjollrig panel tab %s: %s"):format(tab.name, lhs),
      })
      active_tab_keys[#active_tab_keys + 1] = lhs
    end
  end
end

---Switch the panel to `view` ("files", "comments", or a registered
---tab's name), running the registered-tab lifecycle: the old tab's
---keymaps are removed and its on_hide fires; the new tab's on_show
---fires BEFORE the render (the lazy-fetch hook) and its keymaps are
---applied. Clears any comments-view drill-down scope.
---@param view string
local function set_view(view)
  local old = tab_by_name(current_view)
  if old then
    clear_tab_keymaps()
    if old.on_hide then
      pcall(old.on_hide, tab_ctx())
    end
  end
  current_view = view
  file_filter = nil
  local new = tab_by_name(view)
  if new then
    if new.on_show then
      pcall(new.on_show, tab_ctx())
    end
    apply_tab_keymaps(new)
  end
  refresh()
end

---Jump to the comment under the cursor in a comments view: resolve its
---uri to the owning session pair, rebuild that pair's diff via
---review.open_pair, then put the cursor on the comment's line in the
---commentable window (right side; the single left window for D pairs).
---The panel stays open; focus moves to the jump target.
local function jump_to_comment()
  local comment = comment_at_cursor()
  if not comment then
    return
  end
  local review = require("pjollrig.review")
  local state = review.state()
  if not state then
    return
  end
  local pair_index = state.uri_index[comment.uri]
  if not pair_index then
    vim.notify("pjollrig: comment does not match any file in this review", vim.log.levels.WARN)
    return
  end
  review.open_pair(pair_index)
  local all = require("pjollrig.review.all")
  if all.is_active(vim.api.nvim_get_current_buf()) then
    all.jump_file(pair_index, comment.line)
    return
  end
  -- review.open_pair leaves focus in the commentable window (right side;
  -- the left buffer for D pairs).
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local line = math.min(math.max(comment.line, 1), vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
end

---Jump to the comment under the cursor in the PROJECT-mode panel:
---open its file in the previous window (the one `:PjollrigList` was
---invoked from) and put the cursor on the comment's line. Falls back
---to the first non-panel window in the tab, then to a fresh split.
---The panel stays open; focus moves to the jump target.
local function jump_to_project_comment()
  local comment = comment_at_cursor()
  if not comment then
    return
  end
  local uri_mod = require("pjollrig.uri")
  local path = uri_mod.to_path(comment.uri)
  local target_bufnr = not path and uri_mod.bufnr_for_uri(comment.uri) or nil
  if not path and not target_bufnr then
    vim.notify("pjollrig: comment's buffer is no longer available", vim.log.levels.WARN)
    return
  end
  local winid = vim.fn.win_getid(vim.fn.winnr("#"))
  if winid == 0 or winid == panel_winid or not vim.api.nvim_win_is_valid(winid) then
    winid = nil
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if candidate ~= panel_winid and vim.api.nvim_win_get_config(candidate).relative == "" then
        winid = candidate
        break
      end
    end
  end
  if not winid then
    local ok, new_win =
      pcall(vim.api.nvim_open_win, vim.api.nvim_create_buf(false, true), true, { split = "above", win = -1 })
    winid = ok and new_win or nil
  end
  if not winid then
    return
  end
  vim.api.nvim_set_current_win(winid)
  if path then
    vim.cmd.edit(vim.fn.fnameescape(path))
  else
    vim.api.nvim_win_set_buf(winid, target_bufnr)
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local line = math.min(math.max(comment.line, 1), vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
end

---Feed `lhs` back through as an unmapped key — the fallthrough for
---maps that only act in one view.
---@param lhs string
local function feed_default(lhs)
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

---Flip one tree directory row between collapsed and expanded.
---@param dir_path string
local function toggle_dir(dir_path)
  if collapsed[dir_path] then
    collapsed[dir_path] = nil
  else
    collapsed[dir_path] = true
  end
  refresh()
end

---Pair indexes living under a directory row's subtree. Prefix-matching
---pair.path covers collapsed-chain nodes ("lua/pjollrig") without
---re-walking the tree.
---@param dir_path string
---@param state pjollrig.ReviewSession
---@return integer[]
local function subtree_pair_indexes(dir_path, state)
  local prefix = dir_path .. "/"
  local out = {}
  for idx, pair in ipairs(state.files) do
    if pair.path:sub(1, #prefix) == prefix then
      out[#out + 1] = idx
    end
  end
  return out
end

---Expand every collapsed ancestor directory of the given pair so its
---tree row becomes visible. Returns true when any state changed (the
---caller re-renders). Clearing a prefix that is not a rendered node
---(chain-collapse swallows intermediates) is harmless.
---@param pair_index integer
---@return boolean changed
local function expand_to(pair_index)
  local state = require("pjollrig.review").state()
  local pair = state and state.files[pair_index]
  if not pair then
    return false
  end
  local changed = false
  local prefix
  local parts = vim.split(pair.path, "/", { plain = true })
  for i = 1, #parts - 1 do
    prefix = prefix and (prefix .. "/" .. parts[i]) or parts[i]
    if collapsed[prefix] then
      collapsed[prefix] = nil
      changed = true
    end
  end
  return changed
end

local function setup_panel_keymaps(bufnr)
  local map_opts = { buffer = bufnr, nowait = true, silent = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("keep", { desc = desc }, map_opts))
  end

  -- <CR> on a Files-tab file row drills into the pair's comments when
  -- it has any, otherwise opens the pair — IDENTICAL in the flat and
  -- tree layouts (the flat behavior is canonical); a tree directory
  -- row toggles its collapse instead. In comments view it jumps to the
  -- comment through review.open_pair (never a raw window jump, which could
  -- stomp a diff window's buffer); in project mode there is no session
  -- to route through, so the jump opens the file in the previous
  -- window. On a REGISTERED tab it routes to the tab's own <CR>
  -- keymap when declared, else no-ops (custom rows have no default
  -- activation).
  map("<CR>", function()
    local tab = tab_by_name(current_view)
    if tab then
      local fn = tab_keymap_for(tab, "<CR>")
      if fn then
        fn(data_at_cursor(), tab_ctx())
      end
    elseif project_mode then
      jump_to_project_comment()
    elseif current_view == "files" then
      local data = data_at_cursor()
      if type(data) ~= "table" then
        return
      end
      if data.kind == "dir" then
        toggle_dir(data.dir)
        return
      end
      local idx = data.pair_index
      if not idx then
        return
      end
      local state = require("pjollrig.review").state()
      local pair = state and state.files[idx]
      if pair and require("pjollrig.config").get().review.file_mode ~= "all" then
        local uri = state.uris[idx]
        local records = require("pjollrig").list({ uris = { [uri] = true } }, { sync = false, root = state.root })
        if #records > 0 then
          current_view = "comments"
          file_filter = uri
          -- The drill-down check above already fetched exactly the
          -- records this scoped view shows; render them instead of
          -- re-listing.
          refresh(records)
          return
        end
      end
      require("pjollrig.review").open_pair(idx)
    else
      jump_to_comment()
    end
  end, "Pjollrig review: drill into comments, toggle directory, or open pair")

  -- `o` on any pair row (either Files layout) always opens the pair —
  -- the escape hatch when <CR> would drill into comments instead.
  -- Falls through outside the Files tab (comments and registered tabs).
  map("o", function()
    if current_view ~= "files" then
      feed_default("o")
      return
    end
    local idx = pair_index_at_cursor()
    if idx then
      require("pjollrig.review").open_pair(idx)
    end
  end, "Pjollrig review: open pair (skip drill-down)")

  -- `za` mirrors <CR> on tree directory rows — the native fold-toggle
  -- key. Falls through to the default `za` everywhere else (directory
  -- rows only exist in the Files tab's tree layout).
  map("za", function()
    local data = current_view == "files" and data_at_cursor() or nil
    if type(data) == "table" and data.kind == "dir" then
      toggle_dir(data.dir)
    else
      feed_default("za")
    end
  end, "Pjollrig review: toggle directory collapse")

  -- <Esc> in the comments view — or on a registered tab — returns to
  -- the Files tab (clearing any file filter, keeping its layout); in
  -- the Files tab — and in project mode, which has no Files tab — it
  -- falls through to the default behavior.
  map("<Esc>", function()
    if not project_mode and current_view ~= "files" then
      set_view("files")
    else
      feed_default("<Esc>")
    end
  end, "Pjollrig review: back to files view")

  -- `v` toggles viewed state (next/prev also auto-mark the pair they
  -- leave; `v` is the manual toggle/un-mark): a pair row toggles that
  -- pair; a tree directory row toggles its whole subtree — any unviewed
  -- file marks everything viewed, an all-viewed subtree un-marks. Falls
  -- through to the default `v` (visual mode) outside the Files tab.
  map("v", function()
    if current_view ~= "files" then
      feed_default("v")
      return
    end
    local data = data_at_cursor()
    if type(data) ~= "table" then
      return
    end
    local review = require("pjollrig.review")
    local state = review.state()
    if not state then
      return
    end
    if data.kind == "dir" then
      local indexes = subtree_pair_indexes(data.dir, state)
      local target = false
      for _, idx in ipairs(indexes) do
        if not state.viewed[idx] then
          target = true
          break
        end
      end
      for _, idx in ipairs(indexes) do
        review.set_viewed(idx, target)
      end
    elseif data.pair_index then
      review.set_viewed(data.pair_index, not state.viewed[data.pair_index])
    end
  end, "Pjollrig review: toggle viewed for the file or directory under cursor")

  -- L/H switch the panel tabs — builtins first, then the AVAILABLE
  -- registered tabs — wrapping in both directions. Switching always
  -- clears a drill-down scope, so the Comments tab lists ALL session
  -- comments. Project mode maps H/L only when a registered tab opted
  -- into it (spec.project); with none, the single Comments tab keeps
  -- the native H/L motions — and a mapped H/L still falls through
  -- whenever availability leaves a single tab in the cycle.
  local function switch_tab(step, lhs)
    local cycle = tab_cycle()
    if #cycle < 2 then
      feed_default(lhs)
      return
    end
    local index = 1
    for i, view in ipairs(cycle) do
      if view == current_view then
        index = i
        break
      end
    end
    set_view(cycle[(index - 1 + step) % #cycle + 1])
  end
  if not project_mode or has_project_tabs() then
    map("L", function()
      switch_tab(1, "L")
    end, "Pjollrig review: next panel tab")
    map("H", function()
      switch_tab(-1, "H")
    end, "Pjollrig review: previous panel tab")
  end
  if not project_mode then
    -- `t` flips the Files tab between its flat and tree layouts; the
    -- new layout sticks for the session. Falls through to the default
    -- `t` (till-motion) in the other views; project mode has no Files
    -- tab, so the key stays unmapped there.
    map("t", function()
      if current_view ~= "files" then
        feed_default("t")
        return
      end
      layout = current_layout() == "tree" and "flat" or "tree"
      refresh()
    end, "Pjollrig panel: toggle tree layout")
  end

  -- Comment mutations, previously inherited from the quickfix keymap
  -- module: same keys, same opt-out flag, but the locator now comes
  -- from line_data instead of qf user_data. No-ops on file rows.
  if vim.g.pjollrig_no_default_keymaps == 1 then
    return
  end

  map("dd", function()
    local locator = record_locator_at_cursor()
    if locator then
      require("pjollrig").delete(locator.id, locator)
    end
  end, "Pjollrig review: delete comment under cursor")

  map("ce", function()
    local locator = record_locator_at_cursor()
    if locator then
      require("pjollrig").edit(locator.id, locator)
    end
  end, "Pjollrig review: edit comment under cursor")

  map("u", function()
    require("pjollrig").undo_delete()
  end, "Pjollrig review: undo last comment deletion")

  map("<C-r>", function()
    require("pjollrig").redo_delete()
  end, "Pjollrig review: redo last undone deletion")
end

---Close the panel window and drop its augroup + buffer state, KEEPING
---the view/filter state so a later reopen (toggle) restores the panel
---exactly where it was. Idempotent — safe when the window is already
---gone (e.g. called from its own WinClosed).
local function hide()
  -- The ticker dies with the window — nothing left to animate, and a
  -- timer surviving the panel would be a leak.
  stop_spinner()
  local win = panel_winid
  local buf = panel_bufnr
  panel_winid = nil
  panel_bufnr = nil
  line_data = {}
  last_lines = nil
  last_view = nil
  -- Tab keymaps die with the wiped buffer; only the bookkeeping resets
  -- (reopen re-applies them for the restored current view).
  active_tab_keys = {}
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  -- `bufhidden = wipe` wipes the buffer with its window; a buffer that
  -- never reached a window (open failure) still needs explicit deletion.
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---The configured panel placement: position plus optional size override.
---@return {position: "bottom"|"left"|"right"|"float", size?: integer}
local function panel_config()
  local review_cfg = require("pjollrig.config").get().review or {}
  local cfg = type(review_cfg.panel) == "table" and review_cfg.panel or {}
  return { position = cfg.position or "bottom", size = cfg.size }
end

---Window config for one placement. Splits mirror the shapes already in
---the codebase: "bottom" is the `:botright split` full-width strip,
---"left"/"right" the rail's full-height side column (`win = -1`, so
---"right" places OUTERMOST and coexists with the comments rail).
---"float" is a centered editor-relative window.
---@param position string
---@param size integer|nil
---@param file_count integer
---@return table win_opts, boolean enter
local function placement_win_opts(position, size, file_count)
  if position == "float" then
    local width = math.floor(vim.o.columns * 0.6)
    local height = math.floor(vim.o.lines * 0.4)
    return {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      border = "rounded",
      focusable = true,
    },
      true -- modal-ish: the float takes focus on open
  end
  if position == "left" or position == "right" then
    -- Same clamp as the comments rail: 30% of the screen in [30, 46].
    local width = size or math.min(46, math.max(30, math.floor(vim.o.columns * 0.3)))
    return { split = position, win = -1, width = width }, false
  end
  return { split = "below", win = -1, height = size or math.min(12, file_count + 2) }, false
end

---Create the panel buffer + window for the CURRENT view state and arm
---the live-refresh/lifecycle augroup. Splits open with `enter = false`
---(never steal focus); the float is modal-ish and takes focus, with a
---`q` map that closes it (toggle-hide — a session lives on). Project
---mode maps `q` in EVERY placement — the panel is the whole surface
---there, so closing it must not need `:q`.
---@param comment_records? table[] pre-fetched records: sizes the
---bottom split by row count and feeds the initial render (project mode).
local function open_window(comment_records)
  setup_highlights()

  -- A stale buffer holding the panel's name (e.g. left from an aborted
  -- open) would make `nvim_buf_set_name` fail with E95 — drop it.
  local stale = vim.fn.bufnr(PANEL_BUFNAME)
  if stale ~= -1 then
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  pcall(vim.api.nvim_buf_set_name, bufnr, PANEL_BUFNAME)
  vim.bo[bufnr].filetype = PANEL_FILETYPE

  local state = require("pjollrig.review").state()
  local cfg = panel_config()
  local row_count = comment_records and #comment_records or (state and #state.files) or 1
  local win_opts, enter = placement_win_opts(cfg.position, cfg.size, row_count)

  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, enter, win_opts)
  if not ok or not winid or not vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  if cfg.position == "bottom" then
    vim.wo[winid].winfixheight = true
  elseif cfg.position == "left" or cfg.position == "right" then
    vim.wo[winid].winfixwidth = true
  end
  vim.wo[winid].cursorline = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].wrap = false
  vim.wo[winid].list = false
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].spell = false

  panel_winid = winid
  panel_bufnr = bufnr
  setup_panel_keymaps(bufnr)
  -- A toggle-reopen restores the hidden view, which may be a
  -- registered tab: re-apply its keymaps to the fresh buffer.
  apply_tab_keymaps(tab_by_name(current_view))
  -- `q` closes the panel like a toggle: floats in review mode (reopen
  -- with :PjollrigToggle), and EVERY placement in project mode (reopen
  -- with :PjollrigList). <Esc> keeps its view-back meaning in every
  -- position, so the comments-view drill-down works unchanged.
  if cfg.position == "float" or project_mode then
    vim.keymap.set("n", "q", hide, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Pjollrig: close the comments panel",
    })
  end
  render(comment_records)

  augroup = vim.api.nvim_create_augroup("PjollrigReviewPanel", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = {
      "PjollrigAdded",
      "PjollrigDeleted",
      "PjollrigEdited",
      "PjollrigResolved",
      "PjollrigRestored",
      "PjollrigSynced",
    },
    callback = function()
      -- Refresh every view: files for live counts, comments so dd/ce/u
      -- in a (scoped or project) comments view update the list in
      -- place; PjollrigSynced covers records changed by another Neovim
      -- session. The pending flag coalesces a synchronous event burst
      -- (a consuming send fires one PjollrigDeleted per record) into
      -- ONE scheduled refresh.
      if refresh_pending then
        return
      end
      refresh_pending = true
      vim.schedule(function()
        refresh_pending = false
        refresh()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = setup_highlights,
  })
  -- The user can close the panel window directly (:q, <C-w>c): tear
  -- down like a toggle-hide so no autocmd outlives the window. The
  -- window is still in the layout inside a WinClosed callback, hence
  -- the deferred validation.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(winid),
    callback = function()
      vim.schedule(function()
        if panel_winid == winid and not vim.api.nvim_win_is_valid(winid) then
          hide()
        end
      end)
    end,
  })
end

---Point the panel's Files tab at the given pair: re-mark the current
---line and move the panel window's cursor to that row, WITHOUT
---re-querying the store or stealing focus. The tree layout auto-expands
---collapsed ancestors first — Pierre keeps the active file visible —
---and only that expansion re-renders. No-op when the panel is hidden,
---showing a comments view (including a drill-down), or there is no
---session.
---@param pair_index integer
function M.sync_index(pair_index)
  if current_view ~= "files" then
    return
  end
  if not require("pjollrig.review").state() then
    return
  end
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  if current_layout() == "tree" and expand_to(pair_index) then
    render()
  end
  apply_current_marks()
  local row = pair_row_number(pair_index)
  if row then
    pcall(vim.api.nvim_win_set_cursor, panel_winid, { row, 0 })
  end
end

---Re-render the current view in place, preserving the panel cursor.
---For review-state changes that bypass the store-event path (viewed
---toggles). No-op while the panel is hidden.
function M.refresh()
  refresh()
end

---Eagerly run the on_show fetch of every AVAILABLE registered tab that
---opted in (spec.prefetch) — called once by review.start, right after
---the panel opens, so tab data is already loading before the user
---first switches to it. The hook gets the same ctx an on_show gets,
---WITHOUT the tab becoming current: ctx.refresh re-renders only the
---current view, so a prefetching tab repainting from its async
---callback is harmless. Gated by `review.panel.prefetch` (default
---true); no-op while the panel is closed.
function M.prefetch()
  local review_cfg = require("pjollrig.config").get().review or {}
  if (review_cfg.panel or {}).prefetch == false then
    return
  end
  if not (panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  for _, tab in ipairs(registered_tabs) do
    if tab.prefetch == true and tab.on_show and tab_available(tab) then
      pcall(tab.on_show, tab_ctx())
    end
  end
  -- The fetches just kicked off may already report busy; without this
  -- the ticker would only start on the next render.
  sync_spinner()
end

---Open the panel (files view) for the active session. Re-renders in
---place when the window already exists — re-fitting a bottom split's
---height to the session's file count, because review.begin opens the
---panel BEFORE the resolver knows how many pairs exist (0 files → the
---2-row minimum) and the attach re-open must grow it to the real
---count. No-op without a session.
function M.open()
  local state = require("pjollrig.review").state()
  if not state then
    return
  end
  -- Always start in files view; a session panel is never project mode.
  -- Forcing the view bypasses set_view, so drop any registered tab's
  -- keymaps directly (its hooks are for user-driven switches).
  clear_tab_keymaps()
  project_mode = false
  project_root = nil
  current_view = "files"
  file_filter = nil
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    local cfg = panel_config()
    if cfg.position == "bottom" then
      pcall(vim.api.nvim_win_set_height, panel_winid, cfg.size or math.min(12, #state.files + 2))
    elseif cfg.position == "float" then
      -- Modal-ish like open_window's enter=true: the attach re-open
      -- lands after open_pair focused a file window, and the float
      -- must end up focused exactly as a from-scratch open would.
      pcall(vim.api.nvim_set_current_win, panel_winid)
    end
    render()
    return
  end
  hide() -- clear any half-dead window/buffer state before recreating
  open_window()
end

---Open the panel focused on comments (`:PjollrigList`). Inside a
---review session: focus the panel on the Comments tab, opening it
---first when hidden. Outside a session: open the panel in PROJECT mode
---— a single Comments tab listing every project comment, refreshed on
---the same store events and closed with `q` in any placement.
function M.open_comments()
  -- Both branches force the Comments view past set_view: drop any
  -- registered tab's keymaps (its hooks are for user-driven switches).
  clear_tab_keymaps()
  local records
  if require("pjollrig.review").state() then
    project_mode = false
    project_root = nil
  else
    -- Resolve the records AND the root from the INVOKING buffer before
    -- any window changes: the fetched records size the panel and feed
    -- its first render, and the captured root keeps later refreshes
    -- rooted even when they run with the panel scratch buffer current.
    records = require("pjollrig").list()
    project_root = nil
    for _, record in ipairs(records) do
      if type(record.project_root) == "string" and record.project_root ~= "" then
        project_root = record.project_root
        break
      end
    end
    project_root = project_root or require("pjollrig.store").root()
    project_mode = true
  end
  current_view = "comments"
  file_filter = nil
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    refresh(records)
  else
    hide()
    open_window(records)
  end
  -- Both modes land focus in the panel: it is the surface the user
  -- asked for, and dd/ce/q act on the row under its cursor.
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    vim.api.nvim_set_current_win(panel_winid)
  end
end

---Show/hide the panel window without ending the session. Hiding drops
---the window, buffer, and autocmds; view and file-filter state survive
---so a second toggle reopens the panel exactly where it was. No-op
---without an active session.
---@return boolean toggled false when there is no session
function M.toggle()
  if not require("pjollrig.review").state() then
    return false
  end
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    hide()
    return true
  end
  open_window()
  return true
end

---Close the panel and reset ALL module state (view, project mode,
---files layout, and tree collapse state included) — the session-stop
---teardown. Idempotent.
function M.close()
  hide()
  current_view = "files"
  file_filter = nil
  project_mode = false
  project_root = nil
  layout = nil
  collapsed = {}
end

---True when the panel window is open.
---@return boolean
function M.is_open()
  return panel_winid ~= nil and vim.api.nvim_win_is_valid(panel_winid)
end

---The panel window id, or nil when closed. For tests/introspection.
---@return integer?
function M.winid()
  return panel_winid
end

---The panel buffer number, or nil when closed. For tests/introspection.
---@return integer?
function M.bufnr()
  return panel_bufnr
end

---Internal: exposed for tests — is the spinner ticker running?
---@return boolean
function M._spinner_active()
  return spinner_timer ~= nil
end

return M
