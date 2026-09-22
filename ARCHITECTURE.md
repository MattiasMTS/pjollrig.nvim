# Architecture

pjollrig.nvim stores persistent review comments for Neovim buffers. A
comment is anchored by URI and range, rendered with extmarks in one of four
display modes (floating popups, eol virtual text, inline boxes, or hidden
anchors), listed in the comments panel, and optionally sent to an external
sink.

The plugin is local-first. There is no hosted service or network broker.
Project comments use a local SQLite database in WAL mode; session comments
for unrooted and special buffers use a small file store under Neovim state.

## Platform

Neovim >= 0.12 (enforced at plugin load and reported by
`:checkhealth pjollrig`). The runtime leans on unix domain sockets (socket
sink), `tar` (review baseline staging), and `git` (review resolvers), so
macOS and Linux are supported; Windows is untested and unsupported.

## Design Principles

- URI identity is the source of truth. Buffers, panel rows, and sinks
  all resolve back to records keyed by `uri`.
- Rendering is disposable. Extmarks and popups are rebuilt from persisted
  records whenever needed.
- Storage is local and durable. Project records are transactionally written
  to SQLite; same-project Neovim sessions discover changes by polling the
  event log.
- External systems are sinks, not dependencies. Clipboard, cmux, and WezTerm are
  integrations layered on top of the core record model.

## Module Map

```text
plugin/pjollrig.lua             commands and <Plug> maps
lua/pjollrig/init.lua           public API, autocmd wiring, lifecycle events
lua/pjollrig/config.lua         defaults and validation
lua/pjollrig/adapter.lua        buffer identity and diff/staged-buffer handling
lua/pjollrig/uri.lua            canonical URI helpers
lua/pjollrig/store.lua          project/session persistence facade
lua/pjollrig/sqlite.lua         minimal LuaJIT FFI SQLite wrapper
lua/pjollrig/anchor.lua         shared extmark namespace
lua/pjollrig/ui.lua             prompt and sink picker facade
lua/pjollrig/ui/editor.lua      floating comment editor
lua/pjollrig/ui/render.lua      extmarks, display modes, popups, viewport rendering
lua/pjollrig/review.lua         review session core (start/open/next/prev/finish/stop)
lua/pjollrig/review/panel.lua   the comments/review panel (tabs, rows, project mode)
lua/pjollrig/review/git.lua     git plumbing (rev-parse, merge-base, changed files, staging)
lua/pjollrig/review/inline.lua  unified-mode diff paint (virtual lines, folds, hunk nav)
lua/pjollrig/review/all.lua     continuous all-files view, source row mapping, snapshot guards
lua/pjollrig/review/sources.lua resolver registry (dirs, git ref, pr via gh CLI, chat)
lua/pjollrig/review/chat.lua    Claude Code transcript reader behind the `chat` resolver
lua/pjollrig/sinks/             sink registry and bundled sinks (clipboard, cmux, wezterm, github, socket)
```

`init.lua` lazy-requires most modules so command/key based lazy-loading has
minimal startup cost. Setup still needs to run early enough to register buffer
autocmds; README recommends `BufReadPost` / `BufNewFile`.

## Record Identity

The persisted record shape is:

```lua
{
  id = "unique",
  uri = "file:///abs/path.lua",
  scope = "project", -- or "session"
  project_root = "/abs/path/to/root", -- nil for session records
  range = { start = { row, col }, end_ = { row, col } },
  body = "text",
  author = "user@example.com",
  created_at = 1731000000,
  updated_at = 1731000000,
  resolved = false,
  meta = {},
}
```

`adapter.identify(bufnr)` owns the question "where should comments on this
buffer live?". It returns a URI, scope, project root, writability, and optional
diff-side metadata.

Important identity cases:

- Normal file in a project: `scope = "project"`, `project_root` from
  `vim.fs.root(bufnr, store.root_markers)`.
- Unrooted file or allowed special buffer: `scope = "session"`.
- Quickfix, prompt, and command-line-window buffers: rejected for adds.
- Diff views: comments are accepted only on the writable side when the pair can
  be identified.
- Runtime-staged paths under `stdpath("run")`: reverse-mapped back to the real
  project file when possible, otherwise rejected with a diagnostic notify.

`M.add` re-runs `adapter.identify` immediately before persisting and refuses to
write if the URI changed. That catches regressions where add-time and
reload-time identities would diverge.

## Rendering

`ui/render.lua` is the only module that owns visual state. For each visible
record it keeps one handle containing:

- a primary extmark for anchoring and line-number highlighting
- additional decoration extmarks for multi-line ranges
- optional sibling decoration extmarks for the eol marker / inline box block
- an optional popup buffer/window

Both entry points dispatch on the display mode. `render.reconcile(bufnr,
records)` is idempotent: it creates or updates handles for live records,
clears handles whose record disappeared, and decides per mode what a record
gets beyond its anchor extmark. `render.update_viewport_popups(bufnr,
records)` owns the transient popups: under `float` it shows popups for
viewport lines (or every line when `ui.always_show_popups`), under `eol`
its visibility test becomes the cursor line, and under `inline`/`hidden`
it tears every popup down.

The mode is split state: `config.get().ui.display_mode` is only the startup
default (`"eol"`); runtime switches (`:PjollrigDisplay` /
`render.set_display_mode`, cycle order float → eol → inline → hidden) live
in module state, in-memory, reset on restart. A switch repaints every
loaded buffer through the same reconcile + viewport-refresh path `show()`
uses.

Per mode:

- `eol`: reconcile puts a sibling decoration extmark on each record's
  anchor line carrying the collapsed `● c<short-id> n/m · body` virt-text
  marker, truncated to the leftover window width (`n/m` = same-line stack
  position, omitted for singles). Markers render for every record —
  viewport/sticky gating is a float concern. The full popup expands while
  the cursor covers the record: `CursorMoved` feeds init.lua's coalesced
  viewport refresh, and the viewport pass renders popups for cursor-line
  records instead of viewport lines.
- `inline`: each commented line renders ONE `virt_lines` block of bordered
  boxes below the anchor, owned by the stack head's handle and ordered by
  `record_stack_less` — code is pushed down, never covered. No popups ever;
  the box already shows the full body and footer, and edit/delete stay
  reachable through `record_at_cursor`.
- `float`: anchored popups with occlusion-aware placement — the
  right-margin spot is used only when every buffer line the popup would
  span leaves it on genuinely empty cells (measured by `strdisplaywidth`),
  otherwise the whole same-line stack falls back below the anchor (above
  when the window bottom leaves no room), never split between placements.
  Eol's expanded popups reuse this path.
- `hidden`: anchor extmarks and line-number tint only.

Float popups and inline boxes share `build_popup_content` (title with short
id + counter, body fitted to a width cap, date/actions footer). Floats
ellipsis-truncate each body line; inline word-wraps instead, since there is
no expanded popup left to reveal the rest.

`config.ui.eol_expand` picks where eol's cursor expansion renders (read at
dispatch time, config-at-setup): `"float"` (default) takes the popup path
above; `"rail"` makes the viewport pass hand the cursor-line records to
`ui/rail.lua` instead — a real `vertical botright` window on the far
right, so covering code is structurally impossible and the occlusion
placement never runs. The rail owns its window, scratch buffer
(`pjollrig://rail`, `bufhidden=wipe`), and lifecycle augroup; render.lua
owns the cards — `render.rail_card_rows` returns the inline box's
`[text, hl]` chunk rows, and the rail only materializes them into buffer
lines + highlight extmarks, aligned so the first card's top row sits at
the anchor line's screen row. An uncommented cursor line clears the cards
but keeps the window; the rail closes when the display mode leaves eol,
the buffer's records disappear, or the code window closes.

Popups are intentionally transient. `BufLeave` and `WinLeave` hide them to
avoid leaking floats across windows. The comment editor is a special case:
opening it moves focus into a pjollrig float, so the leave handler skips that
single transition (in every mode) to keep the record's popup visible while
typing.

Same-line comments stack vertically by popup height. The popup/box title
counter (for example `cabc 2/3`) is the record's position among its scope's
comments; the eol marker's `n/m` is the same-line stack position.

## Storage

All persistent files live under:

```text
stdpath("state")/manicule/
```

Project stores are named from the escaped project root:

```text
<escaped-root>[%%<branch>].sqlite3
```

Session stores use:

```text
session.<format>
```

`store.scope_by_branch = true` appends the current git branch to the project store name
except for `main` and `master`. The default is `false` because comments are
treated as content annotations rather than branch-local editor state.

### Project SQLite

Project stores use two main tables:

```sql
records(root, id, data, deleted_at, updated_at)
events(id, root, record_id, kind, payload, client_id, created_at)
```

`records` is the current projection. `events` is an append-only local event log.
Writes run in `BEGIN IMMEDIATE` transactions with WAL enabled.

Each store client keeps a base snapshot from its last load. On save it diffs the
local record against that base and writes only locally changed fields. If
another Neovim session changed a different field first, the save reads the
current projection and applies only the local field patch. Deletes are
tombstones and take precedence over stale updates.

Clean caches poll `MAX(events.id)` and reload the projection when a newer event
appears. Dirty caches wait until their local save completes.

### Session Files

Session records use:

```lua
{ version = 1, records = { ... } }
```

The payload is encoded as `mpack` by default or JSON when
`store.format = "json"`.

## Main Flows

### Add

```text
M.add
  -> resolve range
  -> ui.prompt / ui.editor.open
  -> adapter.identify
  -> build record
  -> store.put_record + save
  -> render reconcile + viewport refresh
  -> User PjollrigAdded
```

### Reload / Attach

```text
BufReadPost / BufWinEnter
  -> adapter.identify
  -> store.load / store.session_load
  -> store.all_for_uri
  -> render.reconcile
  -> render.update_viewport_popups
```

### Edit / Delete / Resolve

Mutations find the record by explicit locator, current buffer project, loaded
project caches, then session store. After persistence, loaded buffers reconcile
from the store. Delete also refreshes viewports immediately so remaining popups
do not wait for cursor movement.

### Jump

`M.jump("next"|"prev")` is current-buffer scoped. It attaches the buffer,
collects records for the buffer URI, resolves live extmark positions when
available, and moves the cursor to the nearest matching comment without using
quickfix.

### Send

```text
M.send
  -> M.list(filter)
  -> sinks.dispatch(name, records, ctx, cb)
  -> User PjollrigSent
  -> clear_on_success (default true for every sink) deletes sent records
     (only those still matching the send-time snapshot by content;
      helpers.same_record ignores range drift, updated_at, sent marker)
```

## Events

Events are native `User` autocmds.

| Pattern              | Data shape |
| -------------------- | ---------- |
| `PjollrigAdded`      | record |
| `PjollrigEdited`     | record |
| `PjollrigDeleted`    | `{ id, record }` |
| `PjollrigResolved`   | record with `resolved = true` |
| `PjollrigSent`       | `{ sink, count, ok, err }` |
| `PjollrigSynced`     | `{ roots }` |
| `PjollrigOrphaned`   | `{ id, record }` |
| `PjollrigRenamed`    | `{ bufnr, old_uri, new_uri, record_count, ids }` |
| `PjollrigVisibility` | `{ hidden = boolean }` |

## Extension Points

Three registries: sinks (below), review panel tabs (below), and review
source resolvers (`sources.register`, re-exported as
`require("pjollrig").register_review_source`, documented under Review
Mode).

Sinks are the stable extension point:

```lua
require("pjollrig").register_sink({
  name = "tool",
  label = "Tool",
  pre_text = "Optional text before formatted comments.",
  post_text = "Optional text after formatted comments.",
  clear_on_success = true, -- default; false keeps comments after a send
  validate = function(ctx) return true end,
  send = function(comments, ctx, cb) cb(true) end,
})
```

Sinks should use `lua/pjollrig/sinks/helpers.lua` for shared formatting where
possible, including the optional `pre_text` and `post_text` wrappers for text
payloads. Tests should exercise sinks with local fakes, not real network calls.

Review panel tabs (`panel.register_tab`, re-exported as
`require("pjollrig").register_review_tab`) append custom tabs after the
builtin Files/Comments pair in the panel's H/L cycle, in registration
order — the builtins stay hardcoded:

```lua
require("pjollrig").register_review_tab({
  name = "checks",                     -- unique id, also the H/L cycle key
  title = function(ctx)                -- winbar label (string or function),
    return ("Checks %d/%d"):format(7, 9) -- resolved per render: live counts work
  end,
  available = function(session)        -- optional per-session gate (default: always)
    return session ~= nil
  end,
  project = false,                     -- optional: also offer the tab in
                                       -- :PjollrigList project mode (default: no)
  build = function(ctx)                -- rows for render;
    -- ctx = { session, bufnr, width, refresh, spinner_frame }
    return { { text = "lint ok", spans = { { 0, 4, "DiagnosticOk" } }, data = { id = 1 } } }
  end,
  prefetch = true,                     -- optional: fire on_show once at review
                                       -- open (gated by `review.panel.prefetch`)
  busy = function(ctx)                 -- optional: true while fetching — the
    return false                       -- winbar title gets a spinner frame
  end,
  animated = function(ctx)             -- optional: true while rows should tick —
    return false                       -- the panel re-renders the CURRENT tab
                                       -- ~100ms so build() can draw
                                       -- ctx.spinner_frame / live counters
  end,
  keymaps = {                          -- buffer-local, active only while current
    ["<CR>"] = function(row, ctx) end, -- row = the line_data entry under the cursor
  },
  on_show = function(ctx) end,         -- fires entering the tab, before build
  on_hide = function(ctx) end,         -- (the lazy-fetch hook); on_hide on leave
})
```

Rows render through the panel's existing set_lines+extmark pass:
`spans` are `{col, end_col, hl}` byte ranges, and `data` lands in the
panel's per-row `line_data` under `kind = "custom:<name>"`. An
unavailable tab is skipped by H/L and absent from the winbar
(availability is re-evaluated per render/switch). The panel's own keys
(`H` `L` `<Esc>` `q` `dd` `ce` `u` `<C-r>` `r` `gr` `v` `t` `za` `o`)
are reserved — registering a keymap over one errors; `<CR>` is allowed
(custom rows need activation) and is routed by the panel's own map.
`ctx.refresh()` re-renders the open panel — whatever tab is current —
and is safe to call from `vim.schedule` after an async fetch; it no-ops
once the panel is closed. Registering while a panel is open takes
effect on the next render. Bundled tabs load through
`lua/pjollrig/review/tabs/init.lua` on the first panel open
(pcall-required, so an absent module is skipped silently);
`panel._reset_tabs()` is the test seam.

## Review Mode

`:PjollrigReview` opens a diff-review session over file pairs (baseline left,
worktree right). One active session at a time, in its own tab page.

**Session core** (`lua/pjollrig/review.lua`):
- Right side: real worktree file where it exists; comments anchor natively.
- Left side: read-only staged baseline copy (modifiable=false, readonly=true,
  bufhidden=wipe, swapfile=false).
- `review.file_mode = "all"` uses an owned `pjollrig-review-all` scratch
  buffer with source mappings for every code row. File construction yields
  between file batches; switching panel rows reuses the buffer without
  recomputing diffs. Cursor movement only reads the mapping and updates the
  breadcrumb/panel index. `R` explicitly rebuilds the snapshot.
- All-files comment creation resolves to a real source buffer/range BEFORE
  opening the editor, then verifies the source snapshot again on submission.
  Headers, removed lines and mixed-file/side ranges are not commentable.
  Inline comment annotations use a separate namespace, never editable-source
  anchor extmarks. The existing own-surface gate excludes the synthetic buffer
  from position persistence; no display coordinates can leak into the store.
- `:PjollrigReviewFiles single|all` switches file scope independently of the
  saved per-file diff presentation. The initial all-files renderer is unified.
- Diff rendering is chosen by `review.diff_mode`; `:PjollrigReviewDiffMode`
  flips it and re-opens the current index.
  - `split` (default): `:diffsplit` pairs (left split beside right).
  - `unified`: one window on the worktree file, diff painted inline (below).
- Deleted files: left-only display, notify that comments are file-level notes.
- Navigation: `next()`/`prev()` wrap around.
- Panel (`lua/pjollrig/review/panel.lua`): auto-opens on session start as an
  owned scratch buffer (`pjollrig://panel`, filetype `pjollrig-panel`,
  nofile/nomodifiable) in a fixed-height bottom split — NOT the quickfix
  list, which stays free for the user during reviews. One idempotent
  `render()` rebuilds buffer lines + extmarks from `review.state()` and the
  store; per-row locators live in a module-local `line_data` table (files
  view: pair index; comments view: record id/uri/line). The winbar is a
  Pierre-style tab bar (`Files 12 │ Comments 5`, active tab in
  `PjollrigPanelTabActive`, `N/M viewed` progress right-aligned via `%=`);
  `L`/`H` switch tabs with wraparound. The Files tab (default) shows
  `<icon> [status] path  · N comments` with live counts refreshing on
  `User Pjollrig*` events, icon highlights applied as extmarks, and the OPEN
  pair marked with a `▸` overlay, a full-line `PjollrigPanelCurrent`
  background (Normal bg blended 8% toward fg; CursorLine link on transparent
  themes), and a bold filename — re-marked without a re-render on pair
  switch (`sync_index`). The tab renders one of two layouts — flat rows or
  a directory tree with collapsible rollup rows — seeded per session from
  `review.panel.layout` and toggled with `t` (layout and collapse state are
  session-scoped, reset in `close()`). File rows behave identically in both
  layouts: `<CR>` drills into a scoped comments view or calls
  `review.open_pair(idx)`; the Comments tab lists the session records (resolved
  ones dimmed, `dd`/`ce`/`u`/`<C-r>`/`r`/`gr` buffer-local). Lifecycle
  mirrors `ui/rail.lua`: dedicated augroup, WinClosed teardown,
  window+buffer+autocmds dropped on hide, full state reset in `close()`
  (called by `stop()`).
- Project mode (`panel.open_comments()`, wired to `:PjollrigList`): outside a
  session, the same panel opens with a single `Comments N · project` tab
  listing every project comment (paths project-root-relative, root
  captured from the invoking buffer). Same comment-row maps; `<CR>` opens
  the file in the previous window; `q` closes in any placement; refreshes
  coalesce over the same `User Pjollrig*` events. Inside a session,
  `:PjollrigList` focuses the review panel on its Comments tab. There is
  no quickfix machinery anywhere — `pjollrig.list()` renders nothing (its default position sync is its only side effect; `opts.sync = false` disables it).
- `finish()`: collects session comments via URI filter, dispatches to
  configured sink; auto-flushes on `VimLeavePre` when sink is configured and
  comments exist.

**Unified mode** (`lua/pjollrig/review/inline.lua`):
- Paints the diff ONTO the real worktree buffer instead of building a
  synthetic `git diff` document. That choice is load-bearing: records are
  keyed by worktree URI and store ranges in worktree line coordinates
  (`adapter.identify`, `sinks/helpers.line_span`), so a separate diff
  buffer would need a diff↔file mapping at four seams — `finalize_add`,
  `render_extmark`, `capture_position_patches`, and the `record.range`
  fallback in `comment_position` — where one miss silently persists a
  comment against the wrong line. Painting the file keeps all four exact.
- `vim.diff(..., { result_type = "indices" })` against the staged
  baseline. Added lines get `line_hl_group = PjollrigDiffAdd`; removed
  lines become `virt_lines` (above their replacement, or below the line
  they followed for a pure deletion). Empty baseline/buffer content is
  normalised to `""` so an added file diffs as a clean all-add.
- Own namespace (`pjollrig_review_inline`), separate from `anchor.ns`, and
  priority 100 so comment anchors (220) still tint their line number.
- Unchanged regions fold via a `foldexpr` over the kept-row set
  (`review.context` lines around each hunk). Window options are saved
  before the first change and restored by `clear()`, since the worktree
  buffer outlives the session tab.
- Removed lines are virtual, so they are not commentable — the same
  restriction split mode has on its read-only baseline side.
- `]h` / `[h` navigate hunks; both maps are buffer-local and removed on
  `clear()`. `review.open_pair()`/`stop()` call `clear_all()`.

**Resolver registry** (`lua/pjollrig/review/sources.lua`):
- Turns `:PjollrigReview` arguments into staged file pairs.
- Builtin resolvers: `<dirL> <dirR>` (walks dirR, pairs by rel-path, content
  diff), `<git-ref>` (merge-base vs HEAD, shows only your changes), bare
  (defaults to `HEAD`), `pr <n>` (via `gh pr view --json`, shells to gh CLI),
  `chat [all|<n>]` (a Claude Code assistant turn as a markdown document).
- `chat` (`lua/pjollrig/review/chat.lua`) is Claude-Code-specific and opt-in
  by presence of `~/.claude/projects/<cwd-slug>/*.jsonl` (slug = the cwd
  with every non-alphanumeric byte replaced by `-`); read-only and
  best-effort — a missing dir or an unrecognized event shape fails the
  resolve with a clear message. Sessions are listed by mtime (title from
  the last `ai-title` event, else the first prompt's first line, else the
  id); a turn is a run of consecutive `assistant` events ended by ANY
  `user` event (tool results included), text blocks joined with blank
  lines, sidechain events skipped, turns under 3 lines / 120 chars
  dropped, and the kept turns numbered newest-first. Scans are linear and
  prefix-filtered (`string.find` for the `"type":"…"` marker before any
  json-decode) since transcripts run to many MB. The picked turn is
  written to `stdpath("cache")/manicule/chat/<id8>-turn-<n>.md` with a
  3-line comment header and paired with an empty staged left (`A`) in an
  owned stage dir. Its `vim.ui.select` pickers run inside its own
  `resolve_async` chain (the scan starts in a scheduled step, the picker
  callbacks continue it), so they open over the already-visible review
  shell without registry changes; cancelling a picker fails the resolve.
- `register(resolver)` prepends to registry → user resolvers shadow builtins.
- All resolvers return `{files: [{left, right, status, path}], label}`.
- Two entry points share the registry. `resolve(fargs, opts)` blocks until
  the job is staged (tests, external callers). `resolve_async(fargs, opts,
  cb)` — the `:PjollrigReview` path — returns immediately and fires `cb(job,
  err)` on the main loop: the builtin git/pr resolvers run as spawn+callback
  continuations, and a resolver registered without its optional
  `resolve_async` runs its sync `resolve` inside one scheduled step. The
  command layer pairs it with `review.start_async`, which opens the review
  shell (tab + panel spinner) within a frame, attaches the pairs from the
  callback, and guards against stale resolves with a session generation
  counter (`:PjollrigReviewStop`/a superseding `:PjollrigReview` mid-resolve
  tears down cleanly; the late callback only deletes its ownerless stage
  dirs). Per-pair panel diffstat fills after attach in deferred chunks
  (`review.diffstat()` returns nil until the fill's single refresh).
- Resolver authors get the git plumbing as a library
  (`require("pjollrig.review.git")`): `root(dir)` (repo toplevel),
  `rev_parse(root, ref)` / `merge_base(root, a, b)` (both return
  `sha|nil, err`), `changed_files(root, base)` (name-status list incl.
  untracked as "A"), `stage_baseline(root, base, entries, dir)` (write
  baseline copies under `dir` and return ready `{left, right, status,
  path}` pairs), and `materialize(root, ref, paths, dir)` (batch-extract
  arbitrary blobs). Each has an `_async` twin (`run_async`, `root_async`,
  `rev_parse_async`, `merge_base_async`, `changed_files_async`,
  `stage_baseline_async`, `materialize_async`) whose callback fires on the
  main loop. Custom resolvers compose these instead of shelling out to git
  themselves.
- `pr <n>` with the head checked out also imports existing PR review comments
  (`lua/pjollrig/review/import.lua`): `gh api .../pulls/<n>/comments --paginate`
  → project records with `meta.github = {id, url, imported = true}`. Best-effort
  (failure → WARN, review still opens), deduped on `meta.github.id`, skipped
  entirely on the both-sides-staged path. On the async path the import runs
  AFTER the session is on screen (`import.github_pr_async`, kicked by
  `review.start_async` via the job's `github_import` marker; one panel
  refresh reconciles the counts when it lands); the sync `sources.resolve`
  still imports before returning. Imported records are excluded from
  `finish()` (`M.list`'s `exclude_imported` filter) and skipped by the github
  sink so GitHub's own comments are never echoed back.

**GitHub sink** (`lua/pjollrig/sinks/github.lua`): posts the batch as a PR
review via `gh api` (PR from `ctx.pr` or `gh pr view`, repo from
`gh repo view`; argv-only, JSON body via `--input` temp file; registers only
when `gh` is executable).

**Socket sink** (`lua/pjollrig/sinks/socket.lua`):
- Generic JSONL-over-unix-socket transport; bundled, enabled by default.
- Protocol: `hello` (pid, job id) → `submit` (label, comments array) ← `ack`.
- Comments serialized as `{path, lnum, end_lnum, body, side: "working"}`;
  paths project-relative when `project_root` present, line numbers 1-based.
- Timeout: 2000ms default for ack; on connect/write/ack failure, writes
  `submit.json` fallback next to socket path so comments are never lost.
- `clear_on_success = true` (records deleted after consumer acks).

**Driver contract** (`start_from_job`):
- External tools (coding-agent extensions, scripts) write a job JSON file:
  `{id, label, return_socket, files: [{left, right, status, path}]}`.
- `require("pjollrig.review").start_from_job(path)` reads it, starts the
  session, wires the socket sink.
- Comments flow back via the socket; the driver composes feedback however it
  wants (insert into editor, post to PR, etc).

## Tests

`make test` runs the headless `mini.test` harness. The suite uses ephemeral
state directories and throwaway project roots with `.git` markers.

- `tests/pjollrig/`: module-level behavior, store persistence, adapter identity,
  picker routing, sink selection.
- `tests/integration/`: real workflows with buffers, floating windows, the
  comments panel, render lifecycle, fake prompts, fake sinks, and lifecycle
  events.

The test policy is integration-first when behavior crosses Neovim surfaces.
Mocks are avoided except for costly or external systems.

## Non-Goals

- Hosted storage or network sync.
- Multi-user realtime collaboration.
- Threads, replies, or reactions in the core record model. GitHub thread
  interactions (replies, resolve/unresolve) exist, but they live entirely in
  the sink/meta layer (`meta.github`, `meta.github_reply`) — the record
  schema itself stays flat and host-agnostic.
- A pluggable render backend.
- Fuzzy re-anchoring by line text.
