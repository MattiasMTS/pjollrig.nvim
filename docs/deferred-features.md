# Deferred integrations

Current scope: fast, local diff review with persistent comments and local delivery.
Keep the existing diff/display modes, mouse controls, clipboard, cmux, WezTerm,
Unix-socket driver and extension APIs. GitHub Actions CI, docs generation and
LuaRocks publishing are not part of this downscope and remain enabled.

These features are deferred, not abandoned:

- **GitHub review:** PR picker/resolver, comment import, thread replies/resolution,
  review submission/verdicts, and PR/CI-checks panel tabs.
- **Claude transcript review:** discover sessions, select assistant turns and
  review their text as documents.

The implementation and its tests are preserved in commit
[`90798e3`](https://github.com/MattiasMTS/pjollrig.nvim/tree/90798e30ed50d5522e83eb67c968585cbb283b6d).
Relevant paths at that commit: `lua/pjollrig/review/{chat,github,import,pr_picker}.lua`,
`review/tabs/{github,checks}.lua`, `sinks/github.lua`, and the matching tests.
Resolver/completion wiring lived in `review/{sources,complete}.lua` and commands
in `plugin/pjollrig.lua`. Historical `docs/superpowers/` plans are archival.

Reintroduce independently when there is a concrete need. Prefer the existing
source/tab/sink extension points, load only when requested, and keep remote
processes, transcript scans and availability probes off local review startup.
Measure command-return and content-ready latency separately; a fast loading
screen alone does not meet the performance goal.

No existing comment data or cached documents are deleted. Old imported comments
retain their origin labels and remain excluded from `PjollrigReviewFinish`;
there is no builtin fetch, reply, resolve, or GitHub send action.
