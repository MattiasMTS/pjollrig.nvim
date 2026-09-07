# Review-mode performance

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
