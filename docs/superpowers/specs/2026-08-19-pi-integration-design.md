# manicule.nvim × pi integration — design

Status: approved design, pre-implementation.
Date: 2026-08-19.

## Goal

A `/diff` command in pi that opens a manicule-powered review of the agent's
changes in nvim, lets the user comment, and returns the comment batch into
pi's editor for inspection and submission — with incremental "since last
review" semantics like pi-review-loop, and a path to reusing the same
machinery for GitHub/Graphite PR review later.

## Decisions (accepted)

- Manicule stays sovereign. It works standalone; pi is one consumer via the
  generic sink/hook surface. Manicule never imports pi concepts.
- All pi-specific logic lives in a separate pi extension repo
  (working name `pi-manicule`), installable via `pi install git:...`.
- Diff surface: builtin `nvim.difftool` (nvim 0.12+) preferred, plain
  `:diffsplit` pairs as fallback. diffview.nvim is a possible later
  alternative surface, not v1.
- File *pairs*, not dir-diff: right side is the real worktree file so
  comments anchor natively to project URIs; left side is a read-only staged
  baseline copy (manicule already refuses comments on the reference side).
- Return channel: JSONL over a unix socket. Generic manicule `socket` sink,
  not pi-specific. Zero deps both sides (node `net`, nvim `vim.uv`).
- v1 display modes: fullscreen terminal handover + tmux/cmux pane.
  tmux popup, pi-overlay embedded nvim: later, behind the same interface.
- Checkpoints (reviewed-state memory) are owned by the pi extension and
  stored as pi session custom entries (pi-review-loop semantics).
- Scenario "pi inside nvim :terminal / $NVIM parent" is out of scope.

## Rejected alternatives

- msgpack-RPC as the return channel (welds return path to nvim, npm dep;
  input needs are covered by job file + `nvim --server --remote-expr`).
- Dir-diff as the primitive (would need staged-path remapping; pairs don't).
- Embedding nvim in a pi TUI overlay for v1 (requires PTY + VT emulator
  component in pi-tui; pi-review-loop chose a browser window for the same
  reason).
- Manicule owning checkpoints (review state belongs to the pi session so it
  branches with session branching).

## Architecture

```text
┌──────────────── manicule.nvim (this repo) ────────────────┐
│ NEW lua/manicule/review.lua                               │
│   core: start{files, label, sink, sink_ctx} / finish()    │
│   start_from_job(path)  — reads job.json                  │
│   resolvers: <dir> <dir> | <git-ref> | pr <n> (gh CLI)    │
│   :ManiculeReview <args> command                          │
│ NEW lua/manicule/sinks/socket.lua                         │
│   JSONL over unix socket, generic                         │
│ everything else unchanged (store, anchors, quickfix)      │
└───────────────────────────────────────────────────────────┘

┌──────────────── pi-manicule (new repo) ───────────────────┐
│ /diff command registration                                │
│ checkpoint store      → session custom entries            │
│ baseline materializer → checkpoint blobs/HEAD → tmpdir    │
│ spawn strategies      → fullscreen | tmux | cmux          │
│ socket server (JSONL) → receives comment batch            │
│ feedback composer     → markdown → pi editor              │
└───────────────────────────────────────────────────────────┘
```

## manicule additions

### `lua/manicule/review.lua`

- Core API: `start{files, label, sink, sink_ctx}` where
  `files = { {left, right, status = "M"|"A"|"D"}, ... }`.
  Opens the pair list (quickfix), renders diffs via `nvim.difftool`
  (`packadd nvim.difftool`, `require("difftool")`) or `:diffsplit`
  fallback, provides next/prev-file navigation.
- `start_from_job(path)`: reads a JSON job file (schema below) and calls
  `start`. Single entrypoint used by external drivers (pi) at spawn and at
  remote refresh.
- `finish()`: collects the session's unsent comments and dispatches to the
  configured sink (`sinks.dispatch`). Wired to `VimLeavePre` auto-flush
  (quit = submit when comments exist; quit with none = cancel) and callable
  explicitly via `:ManiculeSend <sink>`.
- Resolver registry for `:ManiculeReview <args>`:
  - `<dir> <dir>` → passthrough.
  - `<git-ref>` → left = materialized `merge-base(HEAD, ref)` tree (tuicr
    semantics: show only your changes), right = worktree. Bare command
    defaults to `HEAD` (uncommitted changes).
  - `pr <n>` → `gh` CLI resolves base/head (octo.nvim pattern: shell out,
    no auth code). Optional dependency, loaded only for this resolver.
  - Registry is open: `graphite`, `jj` etc. slot in later.
- Shared util: materialize `ref → tmpdir` (`git archive | tar -x` or
  worktree), used by git/pr resolvers.

### `lua/manicule/sinks/socket.lua`

- Sink spec `{ name = "socket", ... }`; target path from `sink_ctx.socket`.
- Connect via `vim.uv.new_pipe()`, write JSONL messages, await ack.
- On write failure: dump `submit.json` next to the job file (drivers may
  read it on process exit). Comments are never lost either way —
  `clear_on_success` deletes records only after ack.

## pi extension (pi-manicule)

### Commands

| Command | Baseline |
|---|---|
| `/diff` | last checkpoint on active session branch, else HEAD captured at first open ("since review") |
| `/diff head` | current HEAD (full working-tree change set) |

### Checkpoints

Session custom entry `manicule/checkpoint`:

```json
{ "head": "<sha>",
  "blobs": { "path": "<gzip-b64 content | null (deleted)>" },
  "reviewedPaths": ["..."],
  "feedback": "<composed markdown>" }
```

- Written when a `submit` message arrives — including an empty submit
  ("mark all reviewed").
- Custom entries don't enter model context; session branching branches
  review state; `--no-session` degrades to per-process state.

### Launch lifecycle

```text
/diff
 1. resolve baseline → changed set (incl. untracked + deleted)
 2. stage baseline versions → /tmp/manicule-pi/<id>/left/
 3. write job.json; listen on /tmp/manicule-pi/<id>/sock
 4. strategy.spawn(job)  or  strategy.refresh(job) if alive
```

`job.json`:

```json
{ "id": "<id>",
  "label": "since-review" | "vs-head",
  "return_socket": "/tmp/manicule-pi/<id>/sock",
  "files": [ {"left": "<staged>", "right": "<worktree>", "status": "M"} ] }
```

Spawn command (all strategies):
`nvim -c "lua require('manicule.review').start_from_job('<job.json>')"`,
pane strategies add `--listen <nvim-sock>` for later remote refresh via
`nvim --server <nvim-sock> --remote-expr`.

### Wire protocol (JSONL over unix socket)

```json
{"type":"hello","pid":123,"job":"<id>"}
{"type":"submit","label":"since-review",
 "comments":[{"path":"lua/x.lua","lnum":12,"end_lnum":14,
              "body":"...","side":"working"}]}
{"type":"ack"}   // extension → nvim
```

Handshake timeout (no `hello`) ⇒ actionable error (manicule missing /
misconfigured nvim).

### Spawn strategies

Interface: `{ available(); spawn(job); refresh(job); teardown() }`.

- **fullscreen**: suspend pi TUI → run nvim on the same tty → await exit →
  resume. Mechanism today: `ctx.ui.custom()` exposes the raw `TUI`
  instance → `tui.stop()` / `tui.start()` (what pi's own Ctrl+G external
  editor does internally, `interactive-mode.js` `handleOpenExternalEditor`).
  Undocumented: wrap in one ~20-line function, file an upstream PR for
  `ctx.ui.runExternal(cmd)`, delete the hack when merged. Warn when the
  agent is mid-turn (it keeps running invisibly).
- **tmux**: `tmux split-window -h "nvim ..."`; alive check via job socket /
  `nvim --server` ping; `/diff` again refreshes in place. Persistent daily
  driver, closest to pi-review-loop's always-open window.
- **cmux**: `cmux new-split`/`new-surface` then `cmux send "nvim ..."`
  (same pattern as manicule's existing cmux sink). cmux has no popup.
- **auto** (default): cmux env → cmux; tmux env → tmux; else fullscreen.

Settings: `display` (`auto|fullscreen|tmux|cmux`), `nvimCommand`,
`nvimArgs`, strategy-specific args.

### Feedback path

1. Compose markdown grouped by file (`path:line — body`).
2. `ctx.ui.setEditorText(...)` — user inspects/edits, submits normally.
   Never auto-sent to the model.
3. Append checkpoint entry.

## Error handling

| Failure | Behavior |
|---|---|
| not a git repo | `/diff` errors immediately |
| no `hello` within timeout | error names the fix (install/configure manicule) |
| nvim < 0.12 | `:diffsplit` fallback — degraded, not broken |
| nvim exits nonzero | notify with stderr tail; TUI resume in `finally` |
| socket write fails | `submit.json` fallback; records retained until ack |
| stale tmpdirs/sockets | swept on next `/diff` |
| deleted files | listed; comments become file-level notes |

## Testing

- **manicule** (`mini.test`, integration-first per repo policy):
  `start_from_job` with fixture dirs; git resolver against throwaway repos;
  `gh` resolver with a fake `gh` on PATH; socket sink against an in-process
  fake pipe server; VimLeavePre flush behavior.
- **pi-manicule** (node): checkpoint round-trip (store → materialize);
  composer snapshots; socket server against a scripted fake nvim (shell
  script emitting JSONL); spawn strategies with stubbed `tmux`/`cmux`.
- Manual e2e script per display mode.

## Future (design constraints only, no v1 work)

```text
       resolvers (in)                     sinks (out)
 dirs · git-ref · pr · graphite    socket(pi) · clipboard ·
            │                       cmux · github(gh api)
            └───────▶ review core ◀────────┘
```

- GitHub PR review = existing `pr` resolver + a `github` sink posting via
  `gh api` (octo.nvim precedent). Zero core changes.
- Graphite/jj = additional resolvers.
- tmux popup + pi-overlay embedded nvim (PTY + VT component) = additional
  spawn strategies.
- Other coding agents = implement the same JSONL socket; the protocol is
  agent-agnostic.

## Open questions

- Upstream pi PR (`ctx.ui.runExternal`) timing — hack ships first either way.
- Exact `nvim.difftool` Lua API surface for pair-list mode (verify against
  0.12 docs during implementation; quickfix-driven `:diffsplit` pairs are
  the guaranteed path).
