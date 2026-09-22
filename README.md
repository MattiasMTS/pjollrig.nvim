# pjollrig.nvim

**Review the diff. Leave a note. Cut the pjoller.**

> **pjollrig** · Swedish adjective · roughly **PYOLL-ri(g)**, stress on the
> first syllable; `pj` sounds like the `py` in “pure”.
> [Silly, chatty, or prone to idle chatter](https://www.synonymer.se/sv-syn/pjollrig).
> A playful nod to the northern Swedish *pjoller*: chatter and nonsense.

Persistent review comments for Neovim.

pjollrig.nvim lets you attach notes to lines or ranges in any buffer, keep
them anchored with extmarks as text moves, browse them in the comments
panel, and send them to a sink such as the clipboard or a running
coding-agent surface.

It is meant for local code review and follow-up work: leave comments while
reading code, collect them across files, then resolve them or hand them off as
a review batch.

> Status: alpha.

## Features

- Anchored comments on normal files, unrooted files, scratch buffers,
  terminals, and help buffers.
- Four comment display modes — end-of-line virtual text (default), floating
  popups, inline boxes, or hidden anchors — cycled live with
  `:PjollrigDisplay`.
- Diff-review sessions (`:PjollrigReview`) over uncommitted changes, a git
  ref, or two directories. No network requests on review startup.
- A comments panel for scanning, jumping, editing, and deleting comments —
  the quickfix list stays yours.
- Project-scoped and session-scoped persistence.
- Pluggable sinks for sending comments elsewhere; clipboard, cmux, WezTerm, and
  a JSONL Unix-socket transport are built in.
- Native `User` autocmd events for lifecycle hooks.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the deeper implementation notes and
event payloads. GitHub integration and Claude transcript review are
[deferred features](./docs/deferred-features.md), not part of the current release.

## Requirements

- Neovim >= 0.12.
- macOS or Linux (`git`, `tar`, and unix sockets at runtime); Windows is
  untested and unsupported.
- The default project store uses the local SQLite library through LuaJIT
  FFI; most Neovim builds can load `libsqlite3` already.

Run `:checkhealth pjollrig` after setup to verify the store directory, SQLite
support, clipboard support, and registered sinks.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "MattiasMTS/pjollrig.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = {
    "PjollrigAdd",
    "PjollrigList",
    "PjollrigNext",
    "PjollrigPrev",
    "PjollrigSend",
    "PjollrigReview",
    "PjollrigReviewNext",
    "PjollrigReviewPrev",
    "PjollrigReviewFinish",
    "PjollrigReviewStop",
  },
  keys = {
    { "<leader>ma", "<Plug>(pjollrig-add)", mode = { "n", "x" }, desc = "Pjollrig: add comment" },
    { "<leader>ml", "<Plug>(pjollrig-list)", desc = "Pjollrig: list comments" },
  },
  opts = {},
}
```

Use an event trigger because setup registers the autocmds that attach existing
records to loaded buffers.

### Previously manicule.nvim

Update your plugin spec to `MattiasMTS/pjollrig.nvim`, Lua imports to
`require("pjollrig")`, commands from `Manicule…` to `Pjollrig…`, and
`<Plug>(manicule-…)` mappings to `<Plug>(pjollrig-…)`. Custom highlights and
`User` events also use the `Pjollrig` prefix; plugin globals use `pjollrig`.
The old API names are not aliases. Your own leader keys can stay the same.

The default comment store remains `stdpath("state")/manicule/`, and existing
comment URIs retain their identities.
There is no data migration. An explicitly configured `store.dir` still wins.
If you use lazy.nvim's `dev = true`, rename your local checkout to
`pjollrig.nvim` or set `dir` to its existing path.

## Usage

```vim
:PjollrigAdd            " add a comment on the current line or visual range
:PjollrigList           " open all project comments in the comments panel
:PjollrigEdit           " pick a comment to edit, or pass a list position
:PjollrigDelete         " pick a comment to delete, or pass a list position
:PjollrigResolve        " pick a comment to mark resolved
:PjollrigToggle         " hide or restore all comment visuals; during a review session, shows/hides the review panel
:PjollrigDisplay [mode] " set the comment display mode; bare command cycles
:PjollrigNext [count]   " jump to the next comment in the current buffer
:PjollrigPrev [count]   " jump to the previous comment in the current buffer
:PjollrigSend [sink]    " send comments to a sink
```

`:PjollrigAdd` opens a small markdown buffer in insert mode. `<Esc>` then
`<CR>` submits, `q` in normal mode cancels, and moving focus out of the
floating editor discards the draft.

Default keymaps (set `vim.g.pjollrig_no_default_keymaps = 1` before loading
to opt out):

- `gca` / `gcd` edit / delete the comment at or covering the cursor.
- `]m` / `[m` jump to the next / previous comment in the current buffer.

Core actions are also exposed as `<Plug>` maps for your own bindings:
`(pjollrig-add)`, `(pjollrig-list)`, `(pjollrig-next)`, `(pjollrig-prev)`,
`(pjollrig-edit)`, `(pjollrig-delete)`, `(pjollrig-toggle)`,
`(pjollrig-display-cycle)`, `(pjollrig-review-next)`,
`(pjollrig-review-prev)`, and `(pjollrig-review-diff-mode)`.

### Mouse comments

In normal mode, hover a code line to reveal a `+` in the gutter. Click it
for a single-line comment, or double-click a code line without needing a gutter.
Comments open on release, with no selection preview. Dragging, Escape, or
releasing off the clicked line/button cancels. There is no drag-to-comment.
Double-click commenting replaces normal-mode double-click word selection on
commentable lines; single clicks and ordinary click-drag selection stay native.
The existing editor bindings apply: `<Esc>` then `<CR>` saves; normal `q` cancels.

Setup enables Neovim mouse input (`mouse=a`) by default via `ui.enable_mouse = true`.
Set `ui.enable_mouse = false` to leave your existing mouse setting untouched;
this does not turn mouse input off or undo an earlier setup.
A terminal that reports mouse motion is still required. Comment gestures enable
`mousemoveevent`. Ordinary buffers need gutter space
(`:set number` or `:set signcolumn=yes`); the all-files review uses its existing
line-number prefix. No statuscolumn replacement or layout changes. Removed
lines, virtual rows, and unsupported buffers have no button. Wrapped continuation
rows and lines whose first column is horizontally offscreen are skipped;
scrolling cancels a pending click.

Set `ui.mouse_comments = false` to disable. Existing normal-mode global mouse
mappings are preserved and disable this feature with a warning; buffer-local
mouse mappings take precedence in their buffers.

### Display modes

- `eol` (default) — a collapsed end-of-line marker per comment showing the
  short id and first body line; the full popup expands while the cursor
  sits on the line.
- `float` — anchored floating popups with occlusion-aware placement, gated
  by the viewport (or always shown with `ui.always_show_popups = true`).
- `inline` — a bordered virtual-line box below each commented line; code is
  pushed down, never covered.
- `hidden` — anchor extmarks and line-number tint only.

`:PjollrigDisplay <mode>` switches live; a bare `:PjollrigDisplay` cycles
`float → eol → inline → hidden`. The startup mode comes from `ui.display_mode`;
runtime switches are in-memory and reset when Neovim restarts. Map
`<Plug>(pjollrig-display-cycle)` to cycle from a keymap.

The expanded comment card (shared by `eol` and `float`):

```
local sum = 0                      ┌ c4f2a1c 1/2 ───────────────────┐
for _, item in ipairs(items) do    │ handle the empty items case    │
end                                │ before summing                 │
                                   │ Aug 20 14:05 · edit gca | del… │
                                   └────────────────────────────────┘
```

A leading badge marks each comment's origin: `●` for local comments,
`[gh]` (or a Nerd Font glyph — see `ui.icons`) for comments imported from
a GitHub PR. `ui.eol_expand = "rail"` renders `eol`'s expanded cards into a
real side window on the far right instead of popups, so cards can never
cover code (config-at-setup; no runtime command in v1). `gca`/`gcd` work
from the commented line in every mode.

## Comments panel

`:PjollrigList` opens the comments panel: an owned `pjollrig://panel`
buffer placed by `review.panel.position` (bottom split by default),
showing a single `Comments N · project` tab with one row per comment —
`[ ] path:line  first body line`, paths relative to the project root,
resolved rows dimmed. The quickfix list is never touched.

- `<CR>` opens the comment's file at its line in the previous window.
- `dd` deletes the comment under the cursor.
- `ce` edits the comment under the cursor.
- `u` undoes the last comment deletion (multi-level; repeat to undo more).
- `<C-r>` redoes the last undone deletion (multi-level; a new deletion clears the redo branch).
- `q` closes the panel; `:PjollrigList` reopens it.

The rows refresh in place when comments are added, edited, deleted,
restored, resolved, or synced from another Neovim session. During a
review session, `:PjollrigList` instead focuses the review panel on its
Comments tab.

## Review mode

`:PjollrigReview` opens a diff-review session: baseline versions staged on
the left (read-only), your working tree on the right. Comment on the right
side as usual, then send the batch with `:PjollrigReviewFinish [sink]`.

    :PjollrigReview              " uncommitted changes (vs HEAD)
    :PjollrigReview main         " your branch vs merge-base with main
    :PjollrigReview <dirA> <dirB> " any two directories
    :PjollrigReviewNext          " next changed file
    :PjollrigReviewPrev          " previous changed file
    :PjollrigReviewFinish [sink] " send comments to a sink (optional arg)
    :PjollrigReviewStop          " close the session
    :PjollrigReviewDiffMode      " toggle split <-> unified (or name one)
    :PjollrigReviewFiles all     " stack every file in one continuous unified view
    :PjollrigReviewFiles single  " return to per-file diffs

`review.diff_mode` picks how a pair renders; `:PjollrigReviewDiffMode` flips it
mid-session. `split` (default) is a side-by-side `:diffsplit` pair.
`unified` shows one window — the worktree file — with the diff painted on:
added lines highlighted, removed lines drawn as virtual text where they
used to sit, and unchanged regions folded away (tune with
`review.fold_unchanged` and `review.context`; `za`/`zR` behave as usual).
Comments anchor to true worktree line numbers in both modes; removed
lines and the read-only baseline side are not commentable. `]h` / `[h`
jump between hunks (wrapping).

### Continuous all-files review

`:PjollrigReviewFiles all` stacks every file under a header in one read-only
review buffer. The Files panel becomes an outline: Enter or `o` scrolls to
that file's first hunk, including when the file has comments. Comments-tab
entries jump to their corresponding lines in the combined view.

- `]h` / `[h` — next/previous hunk across all files, wrapping.
- `za` on a file header — collapse or expand that file.
- `gf` on working-side code — open the real source at that line in another tab.
- `R` — rebuild the snapshot after source edits, retaining the current file/line.
- Existing add, edit, delete, send, and comment-navigation commands still work.

Comments appear beneath their source lines. Adding a comment maps the selected
working-side lines back to the real source file; headers, removed lines, and
selections crossing files or removed lines cannot receive comments. If the
source changes before submission, refresh and add the comment again. Binary
and unreadable files show a placeholder.

The top bar tracks the file and hunk under the cursor. `review.fold_unchanged`
and `review.context` control unchanged-code folds; file sections can be folded
independently. All-files mode currently renders unified diffs. Your per-file
`review.diff_mode` preference is preserved for `:PjollrigReviewFiles single`.
With no argument, `:PjollrigReviewFiles` toggles the two file modes.
Set `review.file_mode = "all"` to open future reviews this way by default.

Each review window carries a winbar breadcrumb — `path · M · +12 −4` on
the worktree side, `path · baseline` on the read-only side.

A panel opens automatically: a plain `pjollrig://panel` buffer (filetype
`pjollrig-panel`), so the global quickfix list stays free during the
review. `review.panel.position` places it: `"bottom"` split (default),
`"left"`/`"right"` full-height column, or a centered `"float"` that
takes focus (`q` closes it; `review.panel.size` overrides rows/columns
for the splits). Its winbar is a tab bar — `Files 12 │ Comments 5`
with the active tab emphasized and the viewed progress (`3/12 viewed`)
right-aligned — and `L`/`H` switch to the next/previous tab, wrapping.
In the Files tab each line shows one file with its status, diffstat,
and a live comment count (colored filetype icons when an icon provider
is installed — see `ui.icons`), and the pair on screen is marked with
`▸`, a highlighted line, and a bold filename.

Files you navigate away from with `:PjollrigReviewNext` (or `<Tab>` in a
review buffer) are marked viewed — `✓` and dimmed in the panel, with progress
(`3/12 viewed`) in the winbar. Next skips viewed files while unviewed files
remain. `:PjollrigReviewPrev` / `<S-Tab>` steps back without marking or skipping.
`v` in the panel toggles a file's viewed state by hand.

Panel keymaps (buffer-local): `L`/`H` switch the Files/Comments tabs.
`<CR>` on a commented file drills into a comments view scoped to that
file (`<CR>` jumps to a comment, `dd` deletes, `ce` edits, `u`/`<C-r>`
undo/redo a deletion, `<Esc>` goes back; switching tabs also clears
the scope); `<CR>` on a file without comments switches the diff to
that pair, and `o` always opens the pair. `v` toggles viewed. `t`
toggles the Files tab's layout (below). `:PjollrigToggle` shows/hides
the panel during a review.

The Files tab has two layouts — `"flat"` (the default; set
`review.panel.layout` to change it) lists one full path per line, and
`t` toggles into a `"tree"` layout for the rest of the session: the
same files grouped by directory, Pierre-style, with two-space nesting,
single-child chains collapsed into one row (`lua/pjollrig`), and each
`▾`/`▸` directory row rolling up its subtree's diffstat, comment count,
and viewed state (`●` while any file inside is unviewed, `✓` once all
are). `<CR>` or `za` on a directory row collapses or expands it — the
open pair auto-expands its chain to stay visible — and `v` marks the
whole subtree viewed. File rows behave identically in both layouts
(`<CR>` drills into comments or opens the pair, `o` always opens).

Plugins can add their own panel tabs after the builtin Files/Comments
pair with `require("pjollrig").register_review_tab({...})`: a unique
`name`, a winbar `title` (a string, or a function for a live count like
`Tasks 7/9`), and a `build(ctx)` returning the rows to render.
Optional extras: `available(session)` gates the tab per session,
tab-local `keymaps` are active only while it is current, `on_show` is a
lazy-fetch hook, `prefetch = true` fires it at review open (disable all
eager fetching with `review.panel.prefetch = false`), `busy`/`animated` drive
the winbar spinner and live row ticking, and `ctx.refresh()` re-renders
after an async fetch. See ARCHITECTURE.md ("Extension Points") for the
full spec.

Review startup resolves local Git data asynchronously; the editor stays
responsive while baselines are staged. Large all-files views still take time
to build. See [performance measurements](./docs/performance.md).

External tools can drive a review session by writing a JSON job file and
calling `require("pjollrig.review").start_from_job(path)`; comments return
through the bundled `socket` sink as JSONL over a unix socket.

## Configuration

All keys are optional.

```lua
require("pjollrig").setup({
  store = {
    dir = vim.fn.stdpath("state") .. "/manicule/",
    format = "mpack", -- session store: "mpack" or "json"
    scope_by_branch = false, -- true scopes the store file by git branch (main/master skipped)
    persist_unrooted = true,
    canonicalize_symlinks = true,
    root_markers = { ".git", ".hg", "package.json" },
    poll_interval_ms = 750,
  },
  sinks = {
    clipboard = true,
    wezterm = {
      enabled = true, -- registers when wezterm and WEZTERM_PANE are available
      auto_submit = false, -- paste only; true sends Enter after the paste
      submit_delay_ms = 120,
      clear_on_success = true, -- default; false keeps comments after a send
    },
    cmux = {
      enabled = true,
      auto_submit = true, -- set false to paste and wait for manual Enter
      submit_delay_ms = 120, -- delay before Enter, lets a large paste settle first
      paste_chunk_bytes = 1024, -- max bytes per paste chunk (large reviews are split to avoid PTY truncation)
      paste_chunk_delay_ms = 80, -- delay between paste chunks so the agent's terminal can drain
      paste_retries = 2, -- re-upload + re-paste attempts per chunk (cmux can silently drop concurrent uploads)
      clear_on_success = true, -- default; false keeps comments after a send
      pre_text = "Optional instructions inserted before the comments.",
      post_text = "Optional follow-up instructions inserted after the comments.",
    },
  },
  review = {
    diff_mode = "split", -- "split" (side-by-side) or "unified" (inline)
    file_mode = "single", -- "all" stacks every file in a unified review buffer
    fold_unchanged = false, -- collapse unchanged code into folds while reviewing
    context = 3, -- unified: lines kept visible around each hunk
    panel = {
      position = "bottom", -- "bottom", "left", "right", or "float"
      layout = "flat", -- Files tab: "flat" paths or a "tree" grouped by directory (t toggles)
      prefetch = true, -- run opted-in custom tabs' prefetch hooks at review open
      -- size = 12, -- rows (bottom) or columns (left/right); default per position
    },
  },
  ui = {
    enable_mouse = true, -- set mouse=a; false leaves your setting untouched
    mouse_comments = true, -- gutter click or code double-click to comment
    editor = { -- the floating comment editor
      width = 72,
      height = 6,
      start_mode = "insert", -- mode the editor opens in: "insert" or "normal"
      submit_keys = { "<CR>" },
      cancel_keys = { "q" },
    },
    opacity = 0.0, -- float transparency: 0.0 opaque, 1.0 fully transparent
    always_show_popups = false, -- float mode: render popups beyond the viewport too
    display_mode = "eol", -- startup display mode: "float", "eol", "inline", "hidden"
    eol_expand = "float", -- eol expansion surface: "float" popups or the side "rail"
    icons = "auto", -- Nerd Font badges + filetype icons: "auto", true, false
  },
})
```

`ui.icons` controls icon rendering: `"auto"` (default) turns icons on only
when [mini.icons](https://github.com/echasnovski/mini.icons) or
[nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) is
installed (both are optional; neither is a dependency), `true` forces the
Nerd Font badges on without a provider, and `false` keeps everything plain
text (`[gh]`, `●`, `✓`).

Pjollrig uses built-in floating lists for send destinations, terminal panes,
and comments. Use `j`/`k` or the arrow keys to move,
Enter to choose, and Escape or `q` to cancel. Long lists scroll normally.
The send flow still chooses a sink first, then a pane when needed.
`ui.sink_picker` can override the sink list (for example,
`ui = { sink_picker = vim.ui.select }` to use your configured picker).

## Lua API

`require("pjollrig")` exposes:

- `setup(opts)` — merge config (see Configuration) and wire the autocmds.
- `add(opts?)` — comment on the current line / visual selection, or `opts.range`; `opts.body` skips the editor prompt.
- `jump("next"|"prev", opts?)` — cursor to the nearest comment in the buffer (`opts.count`); `next(opts?)` / `prev(opts?)` are shorthands.
- `edit(id, opts?)` / `delete(id, opts?)` / `resolve(id, opts?)` — mutate one comment by id (`opts.scope`, `opts.project_root` locate it).
- `undo_delete()` / `redo_delete()` — multi-level deletion undo/redo.
- `list(filter?, opts?)` — return records; `filter` takes predicates (`uri`, `uris`, `path_suffix`, `unresolved`, `author`, `exclude_imported`), `opts.root` overrides root resolution, `opts.sync = false` skips the position sync.
- `send(sink?, filter?, ctx?, opts?)` — dispatch listed comments to a sink (nil sink prompts through the picker).
- `register_sink(spec)` / `register_review_tab(spec)` / `register_review_source(resolver)` — the three extension registries.

Review sessions are driven from `require("pjollrig.review")`:
`start`, `open_pair`, `next`, `prev`, `set_diff_mode`, `finish`, `stop`,
`state`, `diffstat`, and `start_from_job`. See
[ARCHITECTURE.md](./ARCHITECTURE.md) for extension authoring (sinks,
panel tabs, review sources) and the `pjollrig.review.git` helpers
available to resolver authors.

## Storage

Project comments are stored in one SQLite database per project root (WAL
mode, a current `records` projection plus an append-only `events` log), so
separate Neovim sessions in the same project observe each other's changes.
Session comments for unrooted or special buffers share a `session.<format>`
file. Stores live under `store.dir`; by default that is:

```vim
:echo stdpath("state") . "/manicule/"
```

## Sinks

Sinks receive comment batches from `:PjollrigSend`.

Built-ins:

- `clipboard` copies formatted comments to the `+` register.
- `cmux` sends a markdown review batch to a cmux coding-agent surface
  (Claude Code, Codex, Amp, and Pi are discovered through cmux metadata)
  and clears the sent comments on a successful handoff (set
  `cmux.clear_on_success = false` to keep them until you verify fixes).
  Pasting and submission behavior is tuned with the `cmux`
  options shown in the configuration example above.
- `wezterm` pastes the markdown review into a selected split in Neovim's
  current WezTerm tab. See the workflow below.
- `socket` returns comments to an external review driver over a Unix socket;
  hidden from interactive sink pickers because it needs a caller-provided destination.

The bundled text sinks (`clipboard`, `cmux`, `wezterm`) also accept `pre_text` and
`post_text` strings inserted before and after the formatted comments.

### WezTerm

Run `:PjollrigSend wezterm` and choose the agent's split, even if there is
only one other split. Pjollrig remembers the pane for this Neovim session
(until plugin setup runs again). Later sends reuse it while it remains in
the same tab. If it closes or moves away, the picker opens again.
Use `:PjollrigSend wezterm pick` to choose a different destination.

The sink pastes through WezTerm's CLI without changing focus or the clipboard.
Bracketed paste is used when the receiving application enables it. Sent
comments are cleared on success, and you press Enter in the agent pane to
submit. Set
`sinks.wezterm.auto_submit = true` to submit automatically after
`submit_delay_ms` (default 120ms). A successful send confirms terminal delivery;
it does not confirm that the agent has processed the review.

Pane discovery and delivery run asynchronously with a per-command timeout
(`timeout_ms`, default 5000). The selected pane is checked again after the
picker closes. On paste failure, inspect the target before retrying because
some text may already have arrived. On submission failure, press Enter manually.

The CLI defaults to `wezterm` on PATH; set `sinks.wezterm.command` to an
executable path if necessary. `current_pane` can override `WEZTERM_PANE`.
From Lua, `require("pjollrig").send("wezterm", nil, { pick = true })`
forces selection. `pre_text`, `post_text`, and `clear_on_success` work as for
other text sinks. Use `sinks.wezterm = false` to disable the integration.

### Custom sinks

Register a custom sink:

```lua
require("pjollrig").register_sink({
  name = "mytool",
  label = "My Tool",
  pre_text = "Optional text before formatted comments.",
  post_text = "Optional text after formatted comments.",
  clear_on_success = true, -- default; false keeps comments after a send
  validate = function(ctx)
    if not ctx.token then
      return false, "missing token"
    end
    return true
  end,
  send = function(comments, ctx, cb)
    -- send comments somewhere
    cb(true)
  end,
})
```

`clear_on_success` defaults to true for every sink, bundled or custom: a
successful send hands the comments off and deletes them locally. Set it to
false on a sink whose delivery is a copy rather than a hand-off. Comments
edited while an asynchronous send is pending stay local; a comment whose
anchor merely moved because the file changed in the meantime is still cleared.

## Events

pjollrig emits native `User` autocmds:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "PjollrigAdded",
  callback = function(ev)
    vim.print(ev.data)
  end,
})
```

Events: `PjollrigAdded`, `PjollrigEdited`, `PjollrigDeleted`,
`PjollrigRestored`, `PjollrigResolved`, `PjollrigSent`, `PjollrigSynced`,
`PjollrigOrphaned`, `PjollrigRenamed`, and `PjollrigVisibility`.

## Notes

- Comments in git diff views are anchored to the working-tree side when the
  reference buffer can be identified.
- Quickfix, prompt, and command-line-window buffers reject new comments.
- Detailed edge cases and data flow are documented in
  [ARCHITECTURE.md](./ARCHITECTURE.md).
