-- pjollrig.nvim
-- Public API surface. All heavy `require`s happen inside functions so
-- users with `cmd = {...}` in their lazy spec don't pay the cost on
-- startup.
--
-- Lifecycle events are emitted as native `User` autocmds — there is no
-- `M.on` helper. Subscribe via `vim.api.nvim_create_autocmd`:
--
--   vim.api.nvim_create_autocmd("User", {
--     pattern = "PjollrigAdded",
--     callback = function(ev) vim.print(ev.data) end,
--   })
--
-- Pattern catalog (see `ARCHITECTURE.md` and `doc/pjollrig.txt`):
--   PjollrigAdded     record
--   PjollrigEdited    record
--   PjollrigDeleted   { id, record }
--   PjollrigRestored  record (the restored snapshot)
--   PjollrigResolved  record (with resolved=true)
--   PjollrigSent      { sink, count, ok, err }
--   PjollrigSynced    { roots }
--   PjollrigOrphaned  { id, record }
--   PjollrigRenamed   { bufnr, old_uri, new_uri, record_count }
--
-- Rendering is owned by `lua/pjollrig/ui/render.lua`. `init.lua`
-- resolves records for the affected buffer on every mutation and
-- delegates to `render.reconcile(bufnr, records)`, which is idempotent.

local M = {}

local uv = vim.uv
local sync_timer

local delete_undo_stack = {} -- LIFO stack of pre-delete record snapshots
local delete_redo_stack = {} -- LIFO stack of undone deletions (redo branch)
local DELETE_UNDO_MAX = 100 -- bound both stacks to avoid unbounded memory

---Push `item` onto a LIFO stack and trim from the front so it never
---exceeds `DELETE_UNDO_MAX`. Shared by the delete / undo / redo paths so
---the bound is enforced identically everywhere.
---@param stack table
---@param item table
local function push_bounded(stack, item)
  table.insert(stack, item)
  if #stack > DELETE_UNDO_MAX then
    table.remove(stack, 1)
  end
end

-- Per-buffer "a viewport refresh is already scheduled" flag. A single
-- user action fires several viewport autocmds (WinScrolled + CursorMoved
-- [+ WinResized]); this collapses the burst to ONE scheduled refresh per
-- buffer with zero added latency (the schedule still runs on the same
-- event-loop tick — no timer delay).
---@type table<integer, boolean>
local viewport_refresh_pending = {}

---@class pjollrig.Config
---@field store? table
---@field sinks? table
---@field ui? pjollrig.UIConfig

local function emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return integer row, integer col
local function clamp_buffer_position(bufnr, row, col)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  row = math.max(0, math.min(row or 0, math.max(0, line_count - 1)))
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  col = math.max(0, math.min(col or 0, #line))
  return row, col
end

---Return the 0-indexed range currently in play for M.add.
---@param opts {range?: table}|nil
---@return {start: integer[], end_: integer[]}
local function resolve_range(opts)
  if opts and opts.range then
    local r = opts.range
    -- Support {l1, l2} (command-line style, 1-indexed) and full 0-indexed form.
    if r.start and r.end_ then
      return r
    end
    local l1, l2 = r[1], r[2] or r[1]
    return {
      start = { l1 - 1, 0 },
      end_ = { l2 - 1, 0 },
    }
  end
  -- Visual selection: when called from select mode the marks '< and '>
  -- are set. If the cursor is currently in visual mode we use the live
  -- positions instead (the marks update only after leaving visual mode).
  local mode = vim.fn.mode()
  local was_visual = mode == "v" or mode == "V" or mode == "\022"
  if was_visual then
    vim.cmd.normal({ args = { "\27" }, bang = true }) -- leave visual so '< '> finalize
  end
  -- Only consult '<  '> when we just left visual mode. Consulting them
  -- unconditionally from normal-mode entry points picks up a stale
  -- selection from an earlier visual action — which made `<leader>ma`
  -- in normal mode anchor to the wrong lines.
  if was_visual then
    local vstart = vim.fn.getpos("'<")
    local vend = vim.fn.getpos("'>")
    if vstart[2] > 0 and vend[2] > 0 then
      local bufnr = vim.api.nvim_get_current_buf()
      -- Linewise visual uses INT_MAX columns; clamp before creating extmarks.
      local sr, sc = clamp_buffer_position(bufnr, vstart[2] - 1, vstart[3] - 1)
      local er, ec = clamp_buffer_position(bufnr, vend[2] - 1, vend[3] - 1)
      return {
        start = { sr, sc },
        end_ = { er, ec },
      }
    end
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  return { start = { cur[1] - 1, 0 }, end_ = { cur[1] - 1, 0 } }
end

---Resolve the project root that should own comments for `bufnr`. Routes
---through `adapter.identify` first so staged buffers
---(`<stdpath('run')>/nvim.<user>/<run-id>/<N>/<suffix>` — DiffToolGit
---and friends) reach the real project store via the adapter's
---reverse-map. Falls back to `vim.fs.root(bufnr, ...)` only when the
---adapter can't resolve a project identity, so scheduled autocmds operate
---on their event buffer instead of whatever happens to be current.
---@param bufnr integer
---@return string?
local function project_root_for_bufnr(bufnr)
  local all = package.loaded["pjollrig.review.all"]
  if all and all.is_active(bufnr) then
    return all.root(bufnr)
  end
  local adapter = require("pjollrig.adapter")
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local identity = adapter.identify(bufnr)
    if identity and identity.scope == "project" and identity.project_root then
      return identity.project_root
    end
    local cfg = require("pjollrig.config").get()
    local markers = ((cfg or {}).store or {}).root_markers
    local ok, root = pcall(vim.fs.root, bufnr, markers)
    if ok then
      return root
    end
  end
  return nil
end

---Resolve the project root for the current buffer.
---@return string?
local function current_project_root()
  return project_root_for_bufnr(vim.api.nvim_get_current_buf())
end

---Resolve the render inputs for `bufnr` in a single pass: one
---`adapter.identify`, one `store.all`/`session_all` read, and derive
---BOTH the per-buffer records (URI-filtered, resolved-filter applied)
---and the counter set (whole project / session, no resolved-filter)
---from those shared reads.
---
---`store.all_for_uri(uri, { root = root })` internally re-reads `store.all(root)`
---via `for_uri`, and deriving the counter set separately would read
---`store.all(root)` again — two `store.all` calls per render, each
---running `M.sync` (`SELECT COALESCE(MAX(id))`) on a cache hit, plus
---two identity resolutions. Reading the project list once here and
---filtering it in-process collapses that to one identity + one
---`store.all`.
---@param bufnr integer
---@return table[] records, table[] counter_records, table? identity
local function render_inputs(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}, {}, nil
  end
  local store = require("pjollrig.store")
  local adapter = require("pjollrig.adapter")
  local identity = adapter.identify(bufnr)
  -- Phase 2 policy: do not render on the reference side of a diff pair.
  -- The reject notify on `M.add` tells the user to switch buffers.
  if not identity or not identity.uri or identity.diff_side == "reference" then
    return {}, {}, identity
  end
  local uri = identity.uri
  local root = identity.project_root

  -- Counter set = the WHOLE project record set (or the session set when
  -- unrooted), no resolved-filter. `store.all` loads on first access and
  -- syncs on a cache hit, so it is the single source we derive both
  -- result sets from.
  local project_records = {}
  if root then
    store.load(root)
    project_records = store.all(root)
  end
  local session_records = store.session_all()
  local counter_records = root and project_records or session_records

  -- Per-buffer records = URI-equal subset of the project list PLUS
  -- URI-equal session records — i.e. exactly what `all_for_uri` returns,
  -- derived from the reads we already did instead of re-querying.
  local records = {}
  if root then
    for _, r in ipairs(project_records) do
      if r.uri == uri then
        table.insert(records, r)
      end
    end
  end
  for _, r in ipairs(session_records) do
    if r.uri == uri then
      table.insert(records, r)
    end
  end
  return records, counter_records, identity
end

---Return records that belong to `bufnr` (URI equality). Merges project
---records from the currently-resolved root AND session records keyed on
---the same URI, so a session-scope comment on a scratch / terminal /
---unrooted buffer renders alongside project records. Resolves identity
---via `pjollrig.adapter` so the reference side of a diff pair returns
---no records (render skips the temp side per the phase-2 "working-tree
---only" policy) while plain buffers resolve via URI equality.
---@param bufnr integer
---@return table[]
local function records_for_buffer(bufnr)
  local records = render_inputs(bufnr)
  return records
end

local refresh_viewport
-- Forward-declared (like `refresh_viewport`) because `hide_popups_on_leave`
-- below references it from a scheduled callback, but the definition lives
-- further down the file. Without this, the upvalue would bind to a global.
local attach_buffer

---Reconcile `bufnr` against already-resolved render inputs and emit
---`PjollrigOrphaned` for any record whose extmark came back invalid.
---Split out so callers that already resolved `render_inputs` (the
---single-pass paint path) don't re-resolve identity + re-read the store.
---@param bufnr integer
---@param records table[]
---@param counter_records table[]
local function reconcile_records(bufnr, records, counter_records)
  local render = require("pjollrig.ui.render")
  render.reconcile(bufnr, records, counter_records)

  -- For each attached record whose extmark came back invalid, emit a
  -- PjollrigOrphaned event. We resolve via the anchor module so the
  -- shape matches what users have been consuming.
  local anchor = require("pjollrig.anchor")
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  for _, record in ipairs(records) do
    local mid = mark_ids[tostring(record.id)]
    if mid then
      local resolved = anchor.resolve(bufnr, mid)
      if resolved and resolved.invalid then
        emit("PjollrigOrphaned", { id = record.id, record = record })
      end
    end
  end
end

---True when `bufnr` is one of pjollrig's own UI surfaces — the review
---panel (`pjollrig-panel`) or the comment rail (`pjollrig-rail`). These
---scratch buffers can never hold records, so editor-wide sweeps (paint,
---position sync, viewport refresh) skip them instead of paying an
---identify + store read per pass on every mutation.
---@param bufnr integer
---@return boolean
local function is_own_surface(bufnr)
  return vim.bo[bufnr].filetype:match("^pjollrig%-") ~= nil
end

---Paint `bufnr` in a SINGLE pass: resolve `render_inputs` once, then feed
---the same records/counters into both reconcile (with orphan detection)
---and the (sticky-gated) viewport update. Shared by `attach_buffer`,
---`refresh_all_loaded`, and the mutation paths (add, rename) so none of
---them runs two full identity+store passes (one in reconcile, one in
---the viewport refresh).
---@param bufnr integer
---@param sticky boolean? whether sticky mode is on (pass the resolved flag to avoid re-reading config per buffer)
local function paint_buffer(bufnr, sticky)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if is_own_surface(bufnr) then
    return
  end
  if sticky == nil then
    local cfg = require("pjollrig.config").get()
    sticky = (cfg.ui or {}).always_show_popups
  end
  local render = require("pjollrig.ui.render")
  local records, counter_records = render_inputs(bufnr)
  reconcile_records(bufnr, records, counter_records)
  -- Mirror `refresh_viewport`: the non-sticky viewport update is a no-op
  -- under sticky (reconcile already schedules the popups), so skip the
  -- call entirely when sticky to match the old behavior. The "eol"
  -- display mode is the exception — its cursor-line popup expansion is
  -- driven by this viewport pass, so it always runs (sticky is a
  -- float-mode concern).
  if (not sticky or render.display_mode() == "eol") and vim.api.nvim_buf_is_valid(bufnr) then
    render.update_viewport_popups(bufnr, records, counter_records)
  end
end

---Run reconcile + the non-sticky viewport update for every loaded
---buffer in a SINGLE pass. Used after mutations / external syncs that
---may span multiple buffers (e.g. `delete` strips a record that could be
---visible in several windows showing different files).
---
---Reconcile and the viewport update are per-buffer independent —
---`render.reconcile`/`update_viewport_popups` only touch state keyed on
---their own `bufnr` (handles[bufnr], that buffer's extmarks, windows
---showing that buffer) — so fusing the two former back-to-back sweeps
---(reconcile_all_loaded then refresh_all_loaded_viewports) into one loop
---is behavior-preserving while halving the per-buffer store reads: each
---buffer now resolves its inputs once instead of ~4×.
local function refresh_all_loaded()
  local cfg = require("pjollrig.config").get()
  local sticky = (cfg.ui or {}).always_show_popups
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      paint_buffer(bufnr, sticky)
    end
  end
end

local function hide_popups_on_leave(bufnr)
  local ok_editor, editor = pcall(require, "pjollrig.ui.editor")
  if ok_editor and editor.is_opening() then
    return
  end
  -- Defer the hide/keep decision: at BufLeave/WinLeave the window+buffer
  -- transition hasn't settled, so we can't yet tell whether the buffer is
  -- going off-screen (`:edit other`, window closed) or just losing focus
  -- while staying visible (splitting open the quickfix list, help, a diff,
  -- etc.). After scheduling, `win_findbuf` reflects the final layout. Only
  -- hide when the buffer is no longer displayed anywhere; otherwise refresh
  -- its viewport so the popups persist while it stays on screen.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if #vim.fn.win_findbuf(bufnr) == 0 then
      require("pjollrig.ui.render").hide_all_popups(bufnr)
    else
      -- Buffer still visible, just lost focus. Under non-sticky this is a
      -- cheap viewport refresh (unchanged behavior). Under sticky,
      -- `refresh_viewport` early-returns and would never rebuild popups,
      -- so route through `attach_buffer` (reconcile re-schedules the
      -- sticky popups). `attach_buffer` covers both modes.
      local cfg = require("pjollrig.config").get()
      if (cfg.ui or {}).always_show_popups then
        attach_buffer(bufnr)
      else
        refresh_viewport(bufnr)
      end
    end
  end)
end

local function refresh_external_store_changes(roots)
  if type(roots) ~= "table" or #roots == 0 then
    return
  end
  refresh_all_loaded()
  -- The review panel subscribes to PjollrigSynced, so an open panel
  -- (review or project mode) re-renders from the freshly synced store.
  emit("PjollrigSynced", { roots = roots })
end

local function start_sync_timer(group)
  local cfg = require("pjollrig.config").get()
  local interval = tonumber((cfg.store or {}).poll_interval_ms) or 0
  if sync_timer then
    sync_timer:stop()
    sync_timer:close()
    sync_timer = nil
  end
  if interval <= 0 then
    return
  end

  local store = require("pjollrig.store")
  sync_timer = uv.new_timer()
  if not sync_timer then
    return
  end
  sync_timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      local roots = store.sync_all()
      refresh_external_store_changes(roots)
    end)
  )

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if sync_timer then
        sync_timer:stop()
        sync_timer:close()
        sync_timer = nil
      end
    end,
  })
end

---Run the non-sticky viewport refresh for `bufnr`. Cheap enough to fire
---from scroll / resize / cursor-moved autocmds.
---@param bufnr integer
function refresh_viewport(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local render = require("pjollrig.ui.render")
  local mode = render.display_mode()
  -- Mode changes and show() reconcile visuals themselves. Cursor/scroll
  -- events need no identity lookup or store read when popups cannot appear.
  if not render.is_visible() or mode == "hidden" or mode == "inline" then
    return
  end
  local cfg = require("pjollrig.config").get()
  -- Sticky suppresses the viewport pass only for float-style popups
  -- (reconcile already scheduled them all). The "eol" display mode
  -- drives its cursor-line popup expansion through this pass, so it
  -- keeps receiving CursorMoved-fed updates regardless of
  -- `ui.always_show_popups`.
  if (cfg.ui or {}).always_show_popups and mode ~= "eol" then
    return
  end
  -- Single-pass: one identify + one store read derives both result sets,
  -- instead of resolving the per-buffer records and the counter set
  -- separately (each re-resolving identity and re-querying the store).
  local records, counter_records = render_inputs(bufnr)
  render.update_viewport_popups(bufnr, records, counter_records)
end

---Copy live extmark positions back into their records. Extmarks are the
---source of truth while a buffer is open; persisted ranges need to follow
---them before writes, sends, and list formatting.
---@param bufnr integer
---@return { roots: table<string, boolean> }
local function sync_positions_for_buffer(bufnr)
  local touched = { roots = {} }
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return touched
  end
  if is_own_surface(bufnr) then
    return touched
  end

  local store = require("pjollrig.store")
  local adapter = require("pjollrig.adapter")
  local render = require("pjollrig.ui.render")
  local identity = adapter.identify(bufnr)
  if not identity or not identity.uri or identity.diff_side == "reference" then
    return touched
  end

  if identity.project_root then
    store.load(identity.project_root)
  end
  store.session_load()

  local records = store.all_for_uri(
    identity.uri,
    identity.project_root and { root = identity.project_root } or { session_only = true }
  )
  if #records == 0 then
    return touched
  end

  local by_id = {}
  for _, record in ipairs(records) do
    by_id[tostring(record.id or "")] = record
  end

  local patches = render.capture_position_patches(bufnr, records)
  for _, patch in ipairs(patches.updates or {}) do
    local record = by_id[tostring(patch.id or "")]
    if record then
      record.range = patch.range
      if record.scope == "session" then
        store.session_mark_dirty()
      else
        local root = record.project_root or identity.project_root
        if root then
          store.mark_dirty(root)
          touched.roots[root] = true
        end
      end
    end
  end

  return touched
end

---Synchronise every loaded buffer before flushing stores.
local function sync_all_loaded_positions()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      sync_positions_for_buffer(bufnr)
    end
  end
end

---@param action string
---@param err string?
local function notify_save_failed(action, err)
  vim.notify(
    ("pjollrig: failed to persist %s: %s"):format(action, tostring(err or "unknown error")),
    vim.log.levels.ERROR
  )
end

---@param target table
---@param source table
local function replace_table_contents(target, source)
  for key in pairs(target) do
    target[key] = nil
  end
  for key, value in pairs(source) do
    target[key] = value
  end
end

---Bring `bufnr` up to date with the store: reconcile extmarks/popups and
---kick the non-sticky viewport refresh so line-number tints and popups
---materialize immediately. Safe to call for buffers with no records or
---no project root (both helpers early-return). Does NOT emit User
---`Pjollrig*` events — those are reserved for mutations.
---@param bufnr integer
function attach_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  -- Single-pass paint: resolve `render_inputs` once and feed it to both
  -- reconcile (orphan detection retained) and the sticky-gated viewport
  -- update, instead of `reconcile_buffer` + `refresh_viewport` each
  -- re-resolving identity and re-reading the store.
  paint_buffer(bufnr)
end

---Per-bufnr snapshot of the URI that was live when `BufFilePre`
---fired. `:saveas` / `:file` mutate the buffer name before the autocmd
---dispatch chain lands on `BufFilePost`; without snapshotting in
---`BufFilePre` there is no reliable way to recover the old URI for
---the rename rewrite. Keys are cleared once the paired `BufFilePost`
---handler runs (or the buffer is wiped).
---@type table<integer, string>
local pre_rename_uris = {}

---`BufFilePre` handler — stash the buffer's current URI so the paired
---`BufFilePost` can rewrite records whose `uri` matches it.
---
---`:saveas` fires `BufFilePre`/`BufFilePost` on both the originally-
---edited buffer (loaded, listed, carries the records) and a brand-
---new alternate buffer Neovim creates for the prior name (unloaded,
---unlisted). We only care about the loaded one; otherwise the
---alternate's pair would swap the rewrite back as the second
---`BufFilePost` fires.
---@param bufnr integer
local function on_bufname_pre(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local uri = require("pjollrig.uri").for_bufnr(bufnr)
  if uri then
    pre_rename_uris[bufnr] = uri
  end
end

---Handle a buffer whose name just changed (`:saveas`, `:file`,
---`:Move`-style plugin renames). Looks up the pre-rename URI captured
---by `on_bufname_pre`, rewrites every record whose `uri` matches to
---the new buffer URI, marks the store dirty, saves, reconciles the
---buffer so handles re-attach under the new URI, and fires a single
---`User PjollrigRenamed` autocmd with the aggregate payload. Silent
---no-op when no matching records exist or the URI didn't change.
---@param bufnr integer
local function on_bufname_changed(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- Same alternate-buffer filter as `on_bufname_pre`: only the
    -- loaded, records-carrying buffer should drive the rewrite.
    return
  end
  local old_uri = pre_rename_uris[bufnr]
  pre_rename_uris[bufnr] = nil
  local store = require("pjollrig.store")
  local uri_mod = require("pjollrig.uri")
  local new_uri = uri_mod.for_bufnr(bufnr)
  if not new_uri or not old_uri or old_uri == new_uri then
    return
  end
  -- Walk both the current project's records and the session store.
  -- A `:saveas` on a session-scope scratch buffer keeps the record's
  -- `scope = "session"` but rewrites the URI — users can
  -- `:PjollrigDelete` and re-add in project scope if they want the
  -- record to move along with the file. This quirk is documented.
  local ids = {}
  local touched_project = false
  -- Use the adapter-resolved root: on a staged buffer `:saveas` is
  -- unlikely, but any read-side "which project owns this buffer?"
  -- question has to reverse-map through the adapter to reach the real
  -- store.
  local root = project_root_for_bufnr(bufnr)
  if root then
    for _, record in ipairs(store.all(root)) do
      if record.uri == old_uri then
        record.uri = new_uri
        table.insert(ids, record.id)
        touched_project = true
      end
    end
    if touched_project then
      store.mark_dirty(root)
      store.save(root)
    end
  end
  local touched_session = false
  for _, record in ipairs(store.session_all()) do
    if record.uri == old_uri then
      record.uri = new_uri
      record.meta = record.meta or {}
      record.meta.ephemeral = uri_mod.is_ephemeral(new_uri) or nil
      table.insert(ids, record.id)
      touched_session = true
    end
  end
  if touched_session then
    store.session_mark_dirty()
    store.session_save()
  end
  if #ids == 0 then
    return
  end
  -- Re-paint the buffer (single-pass reconcile + viewport) so the
  -- render layer, which keyed handles off the old URI, rebuilds
  -- against the new URI. Without this, BufWinEnter's reconcile during
  -- the saveas flow tore down every handle before we rewrote the
  -- records.
  paint_buffer(bufnr)
  emit("PjollrigRenamed", {
    bufnr = bufnr,
    old_uri = old_uri,
    new_uri = new_uri,
    record_count = #ids,
    ids = ids,
  })
end

---Initialize pjollrig with user options.
---@param opts pjollrig.Config|nil
function M.setup(opts)
  opts = opts or {}
  local config = require("pjollrig.config")
  config.setup(opts)
  -- The icons module caches its enabled/provider verdicts; a re-setup can
  -- change ui.icons, so drop the caches with the config they came from.
  require("pjollrig.ui.icons")._reset()

  -- Register bundled sinks/integrations unless the user opted out.
  require("pjollrig.sinks").setup(require("pjollrig.config").get().sinks)

  -- Initialize the render layer (highlights).
  require("pjollrig.ui.render").setup()
  require("pjollrig.ui.mouse").setup()

  -- Idempotent augroup: clear = true means a second setup() wins cleanly.
  local group = vim.api.nvim_create_augroup("pjollrig", { clear = true })
  local store = require("pjollrig.store")
  start_sync_timer(group)

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      vim.schedule(function()
        attach_buffer(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    callback = function(ev)
      hide_popups_on_leave(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(ev)
      local bufnr = ev.buf
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- Pjollrig's own surfaces (panel, rail) never hold records —
      -- don't even schedule a refresh for cursor motion inside them.
      if is_own_surface(bufnr) then
        return
      end
      -- Coalesce the burst: a single user action fires several of these
      -- events, but only the first schedules the refresh. Subsequent
      -- events in the same burst find the flag already set and no-op, so
      -- the buffer renders once per action instead of 2–3×. Scheduling
      -- (vs. an inline call) still avoids float-reconfigure work from
      -- inside the autocmd and adds no latency.
      if viewport_refresh_pending[bufnr] then
        return
      end
      viewport_refresh_pending[bufnr] = true
      vim.schedule(function()
        viewport_refresh_pending[bufnr] = nil
        refresh_viewport(bufnr)
      end)
    end,
  })

  -- Sticky-only: rebuild popups after a window-layout change. Under
  -- sticky every layout event routes through `refresh_viewport`, which
  -- early-returns, so closing a window never re-runs reconcile. When the
  -- closed window was a sticky float's `relative='win'` anchor, Neovim
  -- auto-closes the float; if the buffer is still shown in another window
  -- nothing rebuilds the popup. Re-reconcile every still-visible buffer so
  -- their floats come back. Non-sticky users pay nothing (early return).
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      local cfg = require("pjollrig.config").get()
      if not (cfg.ui or {}).always_show_popups then
        return
      end
      -- The window is still in the layout inside the WinClosed callback, so
      -- defer: recompute the surviving windows and reconcile their buffers.
      vim.schedule(function()
        local seen = {}
        for _, winid in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(winid) then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            if not seen[bufnr] then
              seen[bufnr] = true
              attach_buffer(bufnr)
            end
          end
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("pjollrig.ui.render").refresh_highlights()
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local touched = sync_positions_for_buffer(ev.buf)
      -- Route through the adapter-aware helper so a write from a
      -- staged buffer still flushes the right project store. `save`
      -- on nil is a no-op, so the fallback path stays safe.
      local root = project_root_for_bufnr(ev.buf)
      if root then
        local ok, err = store.save(root)
        if not ok then
          notify_save_failed("project store", err)
        end
      end
      for touched_root in pairs(touched.roots) do
        if touched_root ~= root then
          local ok, err = store.save(touched_root)
          if not ok then
            notify_save_failed("project store", err)
          end
        end
      end
      -- A write to a file that owns session-scope records (e.g. an
      -- unrooted scratch that the user `:w <path>`ed) should flush the
      -- session store too. Cheap no-op when nothing is dirty.
      local ok, err = store.session_save()
      if not ok then
        notify_save_failed("session store", err)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    group = group,
    callback = function(ev)
      -- Drop any pending BufFilePre URI snapshot: a buffer that unloads
      -- between BufFilePre and the deferred BufFilePost handler would
      -- otherwise leak its entry forever (`on_bufname_changed`
      -- early-returns on unloaded buffers before clearing the key).
      pre_rename_uris[ev.buf] = nil
      require("pjollrig.ui.render").clear_buffer(ev.buf)
    end,
  })

  -- `:saveas`, `:file`, and plugin-driven renames all fire
  -- BufFilePre (old name still live) → BufFilePost (new name
  -- installed). We snapshot the URI in Pre because by Post the buffer
  -- name has already been swapped, leaving no reliable way to
  -- discover the URI records were filed under. BufFilePost then
  -- rewrites matching records, saves, and fires PjollrigRenamed.
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(ev)
      on_bufname_pre(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(ev)
      -- A rename can retarget what a path resolves to (symlinks,
      -- overwrite-by-rename). Drop the URI module's realpath memo
      -- BEFORE the deferred rewrite recomputes the new URI, so the
      -- rename path can never be served a stale resolution.
      require("pjollrig.uri").invalidate_realpath_cache()
      vim.schedule(function()
        on_bufname_changed(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      sync_all_loaded_positions()
      store.flush_all()
    end,
  })

  -- Lazy-load sweep: when the plugin is gated behind `cmd = {...}` /
  -- `keys = {...}` in a lazy spec, `BufReadPost` fires before
  -- `M.setup()` runs, so the autocmd above never sees the buffers the
  -- user already has open. Walk every currently-loaded buffer and run
  -- the same attach path so pre-existing records paint immediately.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach_buffer(bufnr)
    end
  end
end

---Build the record and wrap up add().
---@param body string
---@param bufnr integer
---@param range table
local function finalize_add(body, bufnr, range)
  if not body or body == "" then
    return
  end
  local store = require("pjollrig.store")
  local id_mod = require("pjollrig.id")
  local ui = require("pjollrig.ui")
  local adapter = require("pjollrig.adapter")

  local identity, err = adapter.identify(bufnr)
  if not identity then
    vim.notify(("pjollrig: %s"):format(err or "buffer has no identity"), vim.log.levels.WARN)
    return
  end
  if not identity.is_writable then
    vim.notify(("pjollrig: %s"):format(identity.reject_reason or "buffer is not writable"), vim.log.levels.WARN)
    return
  end

  -- Capture what the comment anchors to at creation time: the comment
  -- card's quote line cites this excerpt even after the code changes,
  -- and editing the comment keeps it (it quotes what was commented on).
  -- Stored on `meta` — the extensible JSON blob persisted with the
  -- record — so no store schema change is needed. Multi-line ranges
  -- cite the first line with a `…` continuation marker.
  local start_row = range and range.start and tonumber(range.start[1]) or 0
  local end_row = range and range.end_ and tonumber(range.end_[1]) or start_row
  local first_line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
  local meta = identity.ephemeral and { ephemeral = true } or {}
  meta.excerpt = require("pjollrig.str").excerpt(first_line, end_row > start_row)

  local now = os.time()
  local record = {
    id = id_mod.new(),
    uri = identity.uri,
    scope = identity.scope,
    project_root = identity.project_root,
    range = range,
    body = body,
    author = ui.git_email(),
    created_at = now,
    updated_at = now,
    resolved = false,
    meta = meta,
  }
  -- Invariant canary: re-run `identify` and refuse to persist if it
  -- doesn't reproduce the identity we built the record around. Guards
  -- against regressions where the adapter's build-time and reload-time
  -- identity diverge (staged buffers, future reverse-map bugs) — without
  -- this check, a record could persist under a non-reproducible URI and
  -- never re-anchor, or worse, land in the wrong store if `scope` /
  -- `project_root` drifted between the two `identify` calls.
  local verify, verr = adapter.identify(bufnr)
  if
    not verify
    or verify.uri ~= record.uri
    or verify.scope ~= record.scope
    or verify.project_root ~= record.project_root
  then
    vim.notify(
      ("pjollrig: URI invariant violated (expected %s/%s/%s, got %s/%s/%s: %s)"):format(
        record.uri,
        tostring(record.scope),
        tostring(record.project_root),
        verify and verify.uri or "nil",
        verify and tostring(verify.scope) or "nil",
        verify and tostring(verify.project_root) or "nil",
        verr or "no err"
      ),
      vim.log.levels.ERROR
    )
    return
  end
  store.put_record(record)
  local ok, err
  if record.scope == "session" then
    ok, err = store.session_save()
  else
    ok, err = store.save(identity.project_root)
  end
  if not ok then
    if record.scope == "session" then
      store.session_remove(record.id)
    else
      store.remove(identity.project_root, record.id)
    end
    notify_save_failed("new comment", err)
    return
  end
  -- Single-pass paint: reconcile (extmarks + popups, idempotent) and
  -- the viewport update off ONE identity + store read — the same path
  -- attach_buffer uses. No per-mutation attach/detach API needed.
  paint_buffer(bufnr)
  emit("PjollrigAdded", record)
end

---Add a new comment, optionally tied to a range in the current buffer.
---@param opts {range?: table, body?: string, meta?: table}|nil
function M.add(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local range = resolve_range(opts)
  local all = package.loaded["pjollrig.review.all"]
  local valid
  if all and all.is_active(bufnr) then
    local target, err = all.comment_target(bufnr, range)
    if not target then
      vim.notify("pjollrig: " .. err, vim.log.levels.WARN)
      return
    end
    bufnr, range, valid = target.buf, target.range, target.valid
  end
  local function submit(body)
    if valid and not valid() then
      vim.notify("pjollrig: source or review changed; refresh and add the comment again", vim.log.levels.WARN)
      return
    end
    finalize_add(body, bufnr, range)
  end
  if opts.body and opts.body ~= "" then
    submit(opts.body)
    return
  end
  require("pjollrig.ui").prompt({ prompt = "Comment: " }, function(body)
    if body and body ~= "" then
      submit(body)
    end
  end)
end

---@param bufnr integer
---@param record table
---@param mark_ids table<string, integer>
---@return table?
local function comment_position(bufnr, record, mark_ids)
  local id = tostring(record.id or "")
  local mark_id = mark_ids[id]
  if mark_id then
    local resolved = require("pjollrig.anchor").resolve(bufnr, mark_id)
    if resolved and resolved.invalid then
      return nil
    end
    if resolved and resolved.range and resolved.range.start then
      local row, col = clamp_buffer_position(bufnr, resolved.range.start[1], resolved.range.start[2] or 0)
      return { id = id, row = row, col = col, record = record }
    end
  end

  if record.range and record.range.start then
    local row, col = clamp_buffer_position(bufnr, record.range.start[1] or 0, record.range.start[2] or 0)
    return { id = id, row = row, col = col, record = record }
  end
  return nil
end

---@param bufnr integer
---@param records table[]
---@return table[]
local function comment_positions_for_buffer(bufnr, records)
  local render = require("pjollrig.ui.render")
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  local positions = {}
  for _, record in ipairs(records or {}) do
    local pos = comment_position(bufnr, record, mark_ids)
    if pos then
      table.insert(positions, pos)
    end
  end
  table.sort(positions, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a.id < b.id
  end)
  return positions
end

---@param count any
---@return integer
local function normalized_count(count)
  count = tonumber(count) or 1
  if count ~= count or count < 1 then
    return 1
  end
  return math.floor(count)
end

---Jump to the nearest next/previous comment in the current buffer.
---@param direction "next"|"prev"|"previous"
---@param opts? { count?: integer }
---@return boolean ok
function M.jump(direction, opts)
  opts = opts or {}
  local forward
  if direction == "next" then
    forward = true
  elseif direction == "prev" or direction == "previous" then
    forward = false
  else
    vim.notify(("pjollrig: unknown jump direction %q"):format(tostring(direction)), vim.log.levels.ERROR)
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local all = package.loaded["pjollrig.review.all"]
  if all and all.is_active(bufnr) then
    return all.jump_comment(forward, normalized_count(opts.count))
  end
  attach_buffer(bufnr)

  local records = records_for_buffer(bufnr)
  if #records == 0 then
    vim.notify("pjollrig: no comments in this buffer", vim.log.levels.WARN)
    return false
  end

  local positions = comment_positions_for_buffer(bufnr, records)
  if #positions == 0 then
    vim.notify("pjollrig: no jumpable comments in this buffer", vim.log.levels.WARN)
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cur_row, cur_col = cursor[1] - 1, cursor[2]
  local count = normalized_count(opts.count)
  local target

  if forward then
    for _, pos in ipairs(positions) do
      if pos.row > cur_row or (pos.row == cur_row and pos.col > cur_col) then
        target = pos
        count = count - 1
        if count == 0 then
          break
        end
      end
    end
  else
    for i = #positions, 1, -1 do
      local pos = positions[i]
      if pos.row < cur_row or (pos.row == cur_row and pos.col < cur_col) then
        target = pos
        count = count - 1
        if count == 0 then
          break
        end
      end
    end
  end

  if count > 0 or not target then
    vim.notify(("pjollrig: no %s comment"):format(forward and "next" or "previous"), vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_win_set_cursor(0, { target.row + 1, target.col })
  pcall(vim.cmd, "normal! zv")
  refresh_viewport(bufnr)
  return true
end

---@param opts? { count?: integer }
---@return boolean
function M.next(opts)
  return M.jump("next", opts)
end

---@param opts? { count?: integer }
---@return boolean
function M.prev(opts)
  return M.jump("prev", opts)
end

---Find a record by id across both project + session scopes.
---Returns the record and a closure that persists any mutation back
---through the right store path.
---@param id string
---@param locator? { scope?: "project"|"session", project_root?: string }
---@return table? record, (fun())? save, (fun())? remove
local function find(id, locator)
  local store = require("pjollrig.store")
  locator = locator or {}

  local function find_project(root)
    if not root then
      return nil, nil, nil
    end
    local record = store.get(root, id)
    if record then
      local function save()
        store.put(root, record)
        return store.save(root)
      end
      local function remove()
        local removed = store.remove(root, id)
        local ok, err = store.save(root)
        return ok, err, removed
      end
      return record, save, remove
    end
    return nil, nil, nil
  end

  local function find_session()
    for _, r in ipairs(store.session_all()) do
      if r.id == id then
        local function save()
          store.session_put(r)
          return store.session_save()
        end
        local function remove()
          local removed = store.session_remove(id)
          local ok, err = store.session_save()
          return ok, err, removed
        end
        return r, save, remove
      end
    end
    return nil, nil, nil
  end

  if locator.scope == "session" then
    local record, save, remove = find_session()
    if record then
      return record, save, remove
    end
  elseif locator.project_root then
    local record, save, remove = find_project(locator.project_root)
    if record then
      return record, save, remove
    end
  end

  -- Lookups from `M.edit`/`M.delete`/`M.resolve` run against the
  -- project store that owns the *current* buffer. Route through the
  -- adapter-aware helper so an id coming off a staged buffer still
  -- finds the real project records.
  local root = current_project_root()
  if root then
    local record, save, remove = find_project(root)
    if record then
      return record, save, remove
    end
  end

  -- Panel and picker paths may carry a root, but fall back to every
  -- loaded project store so ids remain actionable after the current window
  -- moved to a panel/help/scratch buffer. `store.loaded_roots()` does not
  -- load arbitrary store files from disk; it only lists roots already
  -- touched this session.
  for _, cached_root in ipairs(store.loaded_roots()) do
    local record, save, remove = find_project(cached_root)
    if record then
      return record, save, remove
    end
  end

  -- Fall through to the session store.
  return find_session()
end

---Edit an existing comment by id, prompting for the new body. Returns
---nothing: failures NOTIFY instead — an unknown id WARNs, a failed
---store write ERRORs (and rolls the in-memory record back). An empty
---prompt answer cancels silently.
---@param id string
---@param opts? { scope?: "project"|"session", project_root?: string }
function M.edit(id, opts)
  local record, save = find(id, opts)
  if not record or not save then
    vim.notify("pjollrig: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  require("pjollrig.ui").prompt({ prompt = "Edit: ", default = record.body }, function(body)
    if not body or body == "" then
      return
    end
    local before = vim.deepcopy(record)
    record.body = body
    record.updated_at = os.time()
    local ok, err = save()
    if not ok then
      replace_table_contents(record, before)
      notify_save_failed("edited comment", err)
      return
    end
    -- Rebuild popups for every buffer that currently renders this record.
    refresh_all_loaded()
    emit("PjollrigEdited", record)
  end)
end

---Delete a comment by id. Returns true when a record was found,
---removed, and persisted (nil on not-found or persistence failure).
---@param id string
---@param opts? { scope?: "project"|"session", project_root?: string, quiet?: boolean, no_refresh?: boolean }
---@return boolean? deleted
function M.delete(id, opts)
  opts = opts or {}
  local record, _, remove = find(id, opts)
  if not record or not remove then
    -- `quiet` suppresses the not-found WARN for callers that delete in
    -- bulk where some ids may already be gone (e.g. the auto-clear loop
    -- in `M.send` after a concurrent sync removed records).
    if not opts.quiet then
      vim.notify("pjollrig: no comment with id " .. tostring(id), vim.log.levels.WARN)
    end
    return
  end
  local snapshot = vim.deepcopy(record)
  local ok, err = remove()
  if not ok then
    require("pjollrig.store").put_record(snapshot)
    notify_save_failed("deleted comment", err)
    return
  end
  -- Push the pre-delete snapshot so `undo_delete` can restore it. The
  -- stack is LIFO; trim from the front when it exceeds the bound.
  push_bounded(delete_undo_stack, snapshot)
  -- A fresh deletion invalidates the redo branch, mirroring Vim's
  -- undo-tree: a new edit discards any redo history.
  delete_redo_stack = {}
  -- `no_refresh` lets bulk callers (the auto-clear loop in `M.send`)
  -- suppress the editor-wide repaint per record and run ONE
  -- `refresh_all_loaded()` after their loop instead. Only the repaint is
  -- batched — `PjollrigDeleted` still fires per record.
  if not opts.no_refresh then
    refresh_all_loaded()
  end
  emit("PjollrigDeleted", { id = id, record = record })
  return true
end

---Restore the most recently deleted comment. Multi-level: call
---repeatedly to undo successive deletions in LIFO order.
function M.undo_delete()
  local snapshot = table.remove(delete_undo_stack)
  if not snapshot then
    vim.notify("pjollrig: nothing to undo", vim.log.levels.INFO)
    return
  end
  local ok, err = require("pjollrig.store").restore_record(snapshot)
  if not ok then
    table.insert(delete_undo_stack, snapshot) -- keep it for a retry
    notify_save_failed("restored comment", err)
    return
  end
  -- Restoring moves the snapshot onto the redo branch so `redo_delete`
  -- can re-apply it. LIFO; trim from the front at the bound.
  push_bounded(delete_redo_stack, snapshot)
  refresh_all_loaded()
  emit("PjollrigRestored", snapshot)
end

---Re-apply the most recently undone deletion (redo). Multi-level:
---call repeatedly to redo successive undos in LIFO order. A fresh
---`M.delete` clears the redo stack, matching Vim's undo-tree behavior.
function M.redo_delete()
  local snapshot = table.remove(delete_redo_stack)
  if not snapshot then
    vim.notify("pjollrig: nothing to redo", vim.log.levels.INFO)
    return
  end
  -- Re-delete by the snapshot's OWN scope/root rather than re-`find`ing
  -- through the current buffer. Redo invoked from a different buffer or
  -- project must not depend on whichever store the current buffer
  -- resolves to — that path could fail to surface the record and drop
  -- the snapshot from the redo stack permanently.
  local store = require("pjollrig.store")
  local removed =
    store.remove_record({ scope = snapshot.scope, id = snapshot.id, project_root = snapshot.project_root })
  local ok, err
  if snapshot.scope == "session" then
    ok, err = store.session_save()
  else
    ok, err = store.save(snapshot.project_root)
  end
  if not ok then
    table.insert(delete_redo_stack, snapshot) -- keep it for a retry
    notify_save_failed("deleted comment", err)
    return
  end
  -- If the record was already gone (e.g. removed by a concurrent sync),
  -- treat the redo as a no-op success: still pop it onto the undo stack
  -- so the round-trip stays consistent, but don't error-spam.
  push_bounded(delete_undo_stack, snapshot)
  refresh_all_loaded()
  emit("PjollrigDeleted", { id = snapshot.id, record = removed or snapshot })
end

---Mark a comment as resolved. Returns nothing: failures NOTIFY instead
---— an unknown id WARNs, a failed store write ERRORs (and rolls the
---in-memory record back).
---@param id string
---@param opts? { scope?: "project"|"session", project_root?: string }
function M.resolve(id, opts)
  local record, save = find(id, opts)
  if not record or not save then
    vim.notify("pjollrig: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  local before = vim.deepcopy(record)
  record.resolved = true
  record.updated_at = os.time()
  local ok, err = save()
  if not ok then
    replace_table_contents(record, before)
    notify_save_failed("resolved comment", err)
    return
  end
  emit("PjollrigResolved", record)
end

---Sort records by uri → start line → id so every surface that lists
---records (the comments panel, picker, completion) sees the same
---order. Returning a sorted list from `list()` itself — rather than
---relying on callers to re-sort — is load-bearing for the picker:
---positional numbers from tab-completion must resolve to the same
---records the user sees in `:PjollrigList`.
---@param records table[]
---@return table[]
local function sort_records(records)
  -- Sorts in place (callers own a fresh list). The shared
  -- `pjollrig.range.compare` keeps the panel, picker, and completion
  -- in agreement.
  table.sort(records, require("pjollrig.range").compare)
  return records
end

---List comments, optionally filtered. Results are always sorted by
---`uri → start line → id` so the ordering seen in `:PjollrigList`, the
---picker, and the positional-number completer is identical.
---
---`filter` holds record predicates only. `opts` controls how the query
---runs:
---
---  * `sync` (default true) — before reading, walk every loaded buffer
---    and fold moved anchor extmarks back into the records: positions
---    are updated in memory and the touched stores are marked dirty for
---    the debounced flush. It renders nothing, but it is NOT a pure
---    read. Pass `sync = false` for a read of the records as stored —
---    read-only surfaces (the review panel) render right after
---    mutations whose paths already synced, so the editor-wide sweep
---    (a store probe + root resolution per buffer) is pure overhead
---    there. Writing paths (send, picker) keep the sync.
---  * `root` — project root to query instead of resolving one from the
---    current buffer/cwd. Review surfaces pass the session's cached
---    root so panel/autoflush calls (whose current buffer may be a
---    scratch buffer outside the project) still hit the right store.
---@param filter {uri?: string, uris?: table<string, true>, path_suffix?: string, unresolved?: boolean, orphaned?: boolean, author?: string, exclude_imported?: boolean}|nil
---@param opts {sync?: boolean, root?: string}|nil
---@return table[]
function M.list(filter, opts)
  filter = filter or {}
  opts = opts or {}
  -- Preserve the send filter for imports already present in existing stores.
  local function is_import(record)
    local meta = type(record.meta) == "table" and record.meta or nil
    local gh = meta and type(meta.github) == "table" and meta.github or nil
    return gh ~= nil and gh.imported == true
  end
  if opts.sync ~= false then
    sync_all_loaded_positions()
  end
  local store = require("pjollrig.store")
  local anchor = require("pjollrig.anchor")
  local render = require("pjollrig.ui.render")
  local uri_mod = require("pjollrig.uri")
  local bufnr = vim.api.nvim_get_current_buf()
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  -- Walk both stores. The picker/panel listing is per-run-short-lived; the
  -- filter winnows and consumers can scope further. Keeps the scope
  -- transparent — no caller branches on `record.scope`.
  local all = {}
  -- Resolve the project root via the adapter so a staged buffer
  -- (DiffToolGit et al.) hits the real project store rather than
  -- walking up through `stdpath('run')` to a dead end — raw
  -- `store.root()` here returned nil and left M.list blind to every
  -- record saved via `adapter.identify`'s reverse-map.
  local root = opts.root or current_project_root()
  if root then
    for _, r in ipairs(store.all(root)) do
      table.insert(all, r)
    end
  end
  for _, r in ipairs(store.session_all()) do
    table.insert(all, r)
  end
  local results = vim
    .iter(all)
    :filter(function(r)
      if filter.uri and r.uri ~= filter.uri then
        return false
      end
      if filter.uris and not filter.uris[r.uri] then
        return false
      end
      if filter.path_suffix then
        -- Case-sensitive suffix match. Prefer resolving URIs back to a
        -- filesystem path so callers can query with the natural
        -- project-relative suffix (`src/foo.lua`); fall back to the raw
        -- URI for non-file schemes so session-scope records still match.
        local candidate = uri_mod.to_path(r.uri) or tostring(r.uri or "")
        local suffix = filter.path_suffix
        if #candidate < #suffix or candidate:sub(-#suffix) ~= suffix then
          return false
        end
      end
      if filter.unresolved and r.resolved then
        return false
      end
      if filter.author and r.author ~= filter.author then
        return false
      end
      if filter.exclude_imported and is_import(r) then
        return false
      end
      if filter.orphaned then
        local mid = mark_ids[tostring(r.id)]
        if not mid then
          return false
        end
        local resolved = anchor.resolve(bufnr, mid)
        if not resolved or not resolved.invalid then
          return false
        end
      end
      return true
    end)
    :totable()

  sort_records(results)
  return results
end

---Dispatch filtered comments to a named sink. With a nil/"" sink name,
---prompts through the sink picker first. Dispatch failures notify
---(ERROR) from the async callback — there is no return value to carry
---them.
---@param sink_name string|nil
---@param filter table|nil record predicates (see M.list)
---@param ctx table|nil sink dispatch context (passed to the sink's send)
---@param opts {root?: string}|nil list options: `root` scopes the store
---query the way M.list's `opts.root` does (review sessions pass the
---session's cached root). The send path always keeps the position sync.
function M.send(sink_name, filter, ctx, opts)
  if sink_name == nil or sink_name == "" then
    require("pjollrig.ui").select_sink(function(name)
      if name then
        M.send(name, filter, ctx, opts)
      end
    end)
    return
  end
  filter = filter or {}
  local records = M.list(filter, { root = opts and opts.root or nil })
  -- Fetch the spec up front so we can check `clear_on_success` after
  -- dispatch without a second registry lookup. Unknown sinks still flow
  -- through `dispatch`'s existing `cb(false, "unknown sink")` path below
  -- (sink will be nil here, `sink.clear_on_success` never evaluates).
  local sinks = require("pjollrig.sinks")
  local sink = sinks.get(sink_name)
  -- Async delivery must not consume edits made while the sink was busy.
  local sent_records = sink and sink.clear_on_success and vim.deepcopy(records) or nil
  sinks.dispatch(sink_name, records, ctx or {}, function(ok, err)
    -- Fire `PjollrigSent` BEFORE any auto-clear so subscribers see the
    -- send event ahead of the per-record `PjollrigDeleted` events — a
    -- causal "send happened, now the records are going away" order.
    emit("PjollrigSent", {
      sink = sink_name,
      count = #records,
      ok = ok,
      err = err,
    })
    if not ok then
      vim.notify(("pjollrig: sink %q failed: %s"):format(sink_name, tostring(err)), vim.log.levels.ERROR)
      return
    end
    if sink and sink.clear_on_success and #records > 0 then
      -- Custom sinks may deliver only part of a batch and stamp a
      -- sent_marker on delivered records. Never clear the undelivered ones.
      local marker = sink.sent_marker
      -- Reuse `M.delete` so each record goes through the full lifecycle
      -- — store.remove + save and one `User PjollrigDeleted` per record
      -- — exactly as if the user had deleted them by hand. `M.delete`
      -- is idempotent on unknown ids (returns early), so a sink that
      -- already cleared records itself becomes a no-op here. Pass
      -- `quiet` so already-removed records (e.g. a concurrent sync)
      -- don't spam a not-found WARN per id, and `no_refresh` so the
      -- editor-wide repaint runs ONCE after the loop instead of once
      -- per cleared record.
      local cleared = false
      for index, record in ipairs(records) do
        local delivered = marker == nil or (type(record.meta) == "table" and record.meta[marker] ~= nil)
        local snapshot = sent_records[index]
        local current = delivered and find(snapshot.id, snapshot) or nil
        if delivered and require("pjollrig.sinks.helpers").same_record(current, snapshot, marker) then
          local deleted = M.delete(snapshot.id, {
            scope = snapshot.scope,
            project_root = snapshot.project_root,
            quiet = true,
            no_refresh = true,
          })
          cleared = cleared or deleted == true
        end
      end
      if cleared then
        refresh_all_loaded()
      end
    end
  end)
end

---Register a sink adapter. Delegates to the sinks registry.
---
---Optional delivery-contract fields consumed by `M.send`:
---`sent_marker` (string) names the `meta` key the sink stamps on each
---record it actually delivered — with `clear_on_success`, only marked
---records are cleared.
---@param spec {name: string, send: fun(comments: table, ctx: table, cb: fun(ok, err)), format?: fun(c): string, validate?: fun(ctx): boolean, string?, sent_marker?: string}
function M.register_sink(spec)
  return require("pjollrig.sinks").register(spec)
end

---Register a review panel tab. Delegates to the panel's tab registry.
---@param spec pjollrig.PanelTab
function M.register_review_tab(spec)
  return require("pjollrig.review.panel").register_tab(spec)
end

---Register a review source resolver for `:PjollrigReview`. Delegates to
---the review sources registry; resolvers are PREPENDED, so a resolver
---registered here shadows the builtins (dirs/git/pr) for any arguments
---its `match` accepts.
---@param resolver {name: string, match: fun(fargs: string[]): boolean, resolve: fun(fargs: string[], opts: table): table|nil, string|nil}
function M.register_review_source(resolver)
  return require("pjollrig.review.sources").register(resolver)
end

-- Exposed for the review layer (panel reply creation repaints the
-- target buffer); not part of the stable public API. Repaints `bufnr`
-- from the store — same path BufWinEnter uses.
---@param bufnr integer
function M._attach_buffer(bufnr)
  attach_buffer(bufnr)
end

-- Exposed for tests (leak assertions on the BufFilePre snapshot table);
-- not part of the stable public API.
function M._pre_rename_uris()
  return pre_rename_uris
end

-- Internal: exposed for tests (the `_reset` family) — drop the store
-- poll timer so a headless run exits cleanly between specs.
function M._reset_sync_timer()
  if sync_timer then
    sync_timer:stop()
    sync_timer:close()
    sync_timer = nil
  end
end

return M
