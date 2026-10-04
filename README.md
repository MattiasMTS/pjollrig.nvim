# pjollrig.nvim

**Review the diff. Leave a note. Cut the pjoller.**

> **pjollrig** · Swedish adjective · roughly **PYOLL-ri(g)**: silly, chatty.

Line comments on any Neovim buffer, sent to your coding agent. Requires Neovim 0.12+.

## Commands

| Command | |
| --- | --- |
| `:[range]Pjollrig add` | comment the line/range (float editor: `:w` saves, `<S-CR>` saves and closes, `q` discards) |
| `:Pjollrig edit` / `delete` / `resolve` | the comment under the cursor, else pick one |
| `:Pjollrig list [all]` | comments in the location list (`all` includes resolved) |
| `:Pjollrig send [sink]` | send unresolved comments; delivered ones are marked resolved |
| `:Pjollrig review [ref]` | changed files in the quickfix list; each opens as a native diff pair. Bare = uncommitted vs `HEAD` (incl. untracked); `ref` = vs `merge-base(HEAD, ref)`. No network. |
| `:Pjollrig review pr N` | GitHub PR without a checkout (needs `gh`): both sides are read-only buffers at the PR's commits; review threads are shown and listed (outdated ones: listed only), never sent |

Sinks: `pi` (`$PI_REVIEW_SOCKET`), `clipboard`, `cmux`, `wezterm`.

## Setup

```lua
require("pjollrig").setup({
  sinks = {
    pi = { auto_submit = false },
    cmux = { auto_submit = true }, -- only ever submits into an agent-looking surface
  },
})
```

Comments live in `stdpath("state")/pjollrig/<repo>.jsonl` (append-only; safe across several nvims).
Comments on scratch buffers stay in memory.

### Any diff tool

A comment's identity is `{root, path, side, rev?}`. A buffer whose `b:pjollrig` holds that table is used as is;
otherwise a buffer shown in a diff window next to exactly one repo file is that file's *old* side
(gitsigns, fugitive, diffview, `nvim -d`, `git difftool`). Such comments carry their line text, since there
is no pinned revision.

Review buffers are named `pjollrig://<old|new><root>//<sha>:<path>`; comments on them are pinned to that sha.
Use `:cnext`/`:cprev` to move between files and `:Pjollrig list` for comments.

Events: `User PjollrigAdded`, `User PjollrigSent`.
