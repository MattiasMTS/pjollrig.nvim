# Review-mode performance

## Local-only startup (PR3 downscope)

After removing the GitHub and Claude-transcript integrations, the built-in
review path runs no remote requests or synchronous subprocess waits. Custom
tab/source extensions remain responsible for their own latency.

Three-run medians on macOS, Neovim v0.13.0-nightly, compared with `90798e3`:

| Changed files / view | Before command | After command | Before content | After content |
|---|---:|---:|---:|---:|
| 6 / single | 7.9 ms | 6.8 ms | 109 ms | 92 ms |
| 6 / all-files | 8.3 ms | 6.9 ms | 93 ms | 86 ms |
| 2,000 / single | 7.8 ms | 7.2 ms | 734 ms | 741 ms |
| 2,000 / all-files | 9.0 ms | 7.0 ms | 1,886 ms | 1,416 ms |

Method: fresh headless Neovim process per sample, clean isolated local repository,
60 lines per file, roughly equal modified/deleted/untracked additions, a real
empty comment store, default panel and no external sink delivery. Setup and
fixture creation excluded; cold review-module loading included. Command time
ends when `:PjollrigReview` returns with the resolving shell open. Content time
ends after the first pair is attached, or after the combined view contains its
commentable rows; it is **not** physical screen-paint latency. All-files readiness
is conservatively polled. Three samples are directional and load-sensitive, not
a guaranteed speedup. Large single-file-view readiness is effectively unchanged.

The GitHub checks tab previously performed a synchronous upstream probe even
for local reviews; that path is gone. Claude transcript code was already lazy,
so its removal mainly reduces maintenance, not local startup time. All-files
coloring now uses one native highlight range per contiguous run instead of one
extmark per changed line, with a real-UI regression for range boundaries.

Limits remain: staging every baseline and rendering very large combined views
are not instant. A traced 2,000-file all-files run still spent about 187 ms in
final buffer/fold refresh and 121 ms in the resolve/attach continuation. Model
construction yields in ~8 ms batches; final full-buffer/fold work remains linear.
The default single-file view avoids building every file's visible diff.

The existing async-command regression checks responsiveness with deliberately
slow Git processes. `scripts/bench-review` below measures staging and panel work,
not command-to-content latency.

## Staging and panel benchmarks

Measured with `scripts/bench-review` on macOS using Neovim v0.13.0-nightly and Git 2.55.0. The harness creates 2,000 changed files (667 modified, 666 added, 667 deleted) and 500 comments. Numbers are machine- and load-dependent — the resolve/stage rows are dominated by git subprocesses, so run-to-run variance of 30-50% on the same machine is normal. Treat the "Before" column (measured on the same machine as "After", in the same session) as the comparison baseline, not an absolute.

| Benchmark | Before | After | Speedup |
|---|---:|---:|---:|
| `sources.resolve({ "main" })` | 16,994.403 ms | 895.259 ms | 19.0x |
| `stage_baseline` | 17,672.247 ms | 521.580 ms | 33.9x |
| panel `build_file_rows` | 79,774.292 ms | 4.216 ms | 18,922x |
| panel `build_file_rows` (icons) | — | 1.384 ms | — |

The baseline now stages tracked files through chunked `git archive` and `tar` subprocesses instead of one `git show` process per file (the archive fan-out change — the bulk of the `stage_baseline` and `resolve` speedups). Panel comment counts come from one filtered list call and a URI count map.

Per-file diffstat counts (`panel_diffstat_ms`) read both sides of all 2,000 pairs and `vim.diff` the modified ones in ~92 ms; a session computes them once, on the first panel render, and caches the result — worktree edits during the session don't update the counts until the next `:PjollrigReview`.

The icons row measures `build_file_rows` with a stubbed icon provider and `ui.icons = true` — headless `--clean` loads no real provider, so without the stub the icon branch is silently skipped and the plain panel number is a floor. It runs as a warm second pass (the plain row runs cold first), so the two panel rows are not directly comparable to each other; the icons row exists to catch regressions in the icon branch specifically. `icons.file_icon` results are memoized per path and the `enabled()` verdict is computed once, so repeated panel renders after the first pay no provider cost.

The bench stubs the comment store (`package.loaded["pjollrig"]`) by design: source resolution, baseline staging, and panel row building are the targets, not SQLite I/O — the panel numbers are therefore a floor for a session with a live store.

Rail expansion renders (`ui.eol_expand = "rail"`) are guarded by a same-state key over the covering records, anchor, and rail width: column-only cursor moves and insert-mode keystrokes no longer rewrite the rail buffer or re-add its extmarks, and repeated clears on uncommented lines are no-ops. Scroll re-alignment still happens — the alignment padding is re-probed (one `screenpos` call) on every dispatch.

Review baseline staging requires the `tar` executable at runtime.
