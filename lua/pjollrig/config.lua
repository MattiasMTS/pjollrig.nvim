-- pjollrig.nvim: configuration defaults + merge/validate.

local M = {}

---@alias pjollrig.SinkPicker fun(choices: pjollrig.SinkChoice[], opts: table, cb: function)

---@class pjollrig.UIEditorConfig
---@field width integer Floating comment editor width (columns)
---@field height integer Floating comment editor height (lines)
---@field start_mode "insert"|"normal" Mode the editor opens in
---@field submit_keys string[] Keys that submit the editor
---@field cancel_keys string[] Keys that cancel the editor

---@class pjollrig.UIConfig
---@field enable_mouse boolean Set Neovim mouse=a at setup; false leaves the existing setting untouched
---@field mouse_comments boolean Gutter click and code double-click commenting in normal mode
---@field editor pjollrig.UIEditorConfig Floating comment editor options
---@field opacity number Floating-window transparency (0.0 = opaque, 1.0 = fully transparent)
---@field always_show_popups boolean Always render comment popups vs only when the line is in the viewport
---@field display_mode "float"|"eol"|"inline"|"hidden" Startup comment display mode. "float" anchored popups, "eol" end-of-line virtual text expanding to the popup on the cursor line, "inline" bordered virtual-line boxes below commented lines (code pushed down, never covered), "hidden" anchors only. Runtime changes via `:PjollrigDisplay`.
---@field eol_expand "float"|"rail" Where the "eol" display mode's cursor expansion renders. "float" (default) opens the anchored popups over the buffer; "rail" renders the same cards into a real side window on the far right, so code can never be covered. Read at expansion time; config-at-setup (no runtime command in v1).
---@field icons boolean|"auto" Filetype icons + Nerd Font badges in review UI. "auto" (default) enables them iff an icon provider (mini.icons or nvim-web-devicons) is loadable; `true` forces Nerd Font glyphs even without a provider; `false` disables them.
---@field sink_picker? pjollrig.SinkPicker Custom picker for choosing a send sink

---@class pjollrig.StoreConfig
---@field dir string Directory where per-root store files live.
---@field format "mpack"|"json" Session store format.
---@field scope_by_branch boolean Scope the filename by the current git branch (main/master skipped).
---@field persist_unrooted boolean When true (default), unrooted file buffers route into the session store.
---@field canonicalize_symlinks boolean Resolve symlinks via `fs_realpath` before encoding URIs.
---@field root_markers string[] Markers passed to `vim.fs.root`.
---@field poll_interval_ms integer Milliseconds between local SQLite sync polls. Set <= 0 to disable.

---@class pjollrig.ReviewPanelConfig
---@field position "bottom"|"left"|"right"|"float" Where the review panel opens (default "bottom").
---@field size? integer Panel size override: rows for "bottom", columns for "left"/"right"; "float" ignores it.
---@field layout "flat"|"tree" How the panel's Files tab lists the session pairs (default "flat"). `t` in the panel toggles it for the session.
---@field prefetch boolean Eagerly run opted-in panel tabs' fetches when a review session opens (default true); false keeps every tab fetch lazy (on first show).

---@class pjollrig.ReviewConfig
---@field diff_mode "split"|"unified" Diff rendering for `:PjollrigReview`. "split" opens a side-by-side `:diffsplit` pair; "unified" paints the diff inline on the worktree buffer.
---@field file_mode "single"|"all" Single-file diffs or a continuous unified review (default single).
---@field fold_unchanged boolean Collapse unchanged regions into folds (default false; split mode gets nofoldenable when off).
---@field context integer Unified mode only: lines of context kept around each hunk (and the fold's minimum size).
---@field panel pjollrig.ReviewPanelConfig Review panel placement.

---@class pjollrig.SinksConfig
---@field clipboard boolean|table Enable the bundled clipboard sink (default true). Accepts `pre_text`, `post_text`, and `clear_on_success` (default true; false keeps comments after a copy).
---@field wezterm boolean|table Enable WezTerm when its CLI and current pane are available. Accepts auto_submit (default false), submit_delay_ms, pre_text, post_text, and clear_on_success (default true; false keeps comments after a send).
---@field cmux boolean|table Enable the bundled cmux integration (defaults to `{ enabled = true }`). Built-in text sinks accept optional `pre_text` and `post_text` strings. cmux also accepts `auto_submit` and `submit_delay_ms`.
---@field socket boolean|table Enable the bundled socket sink (default true). Accepts `ack_timeout_ms`.

---@type pjollrig.Config
local defaults = {
  store = {
    -- Keep the pre-rename state directory so existing comments stay available.
    dir = vim.fn.stdpath("state") .. "/manicule/",
    -- "mpack" | "json". mpack is smaller/faster and tolerates Lua
    -- nil/array quirks. Used by the session store.
    format = "mpack",
    -- Annotations should stay visible across branches by default; pjollrig
    -- stores notes the user wants anchored, not editing state.
    scope_by_branch = false,
    -- When true (default), unrooted file buffers and special buftypes
    -- (terminal, help, scratch, …) route into the session-scoped
    -- store. Set to false to reject adds outside a project with a
    -- notify.
    persist_unrooted = true,
    -- Resolve symlinks through `fs_realpath` before encoding URIs so a
    -- file accessed via a symlink still matches records saved against
    -- the real path. Disable if you want URIs to reflect the access
    -- path instead.
    canonicalize_symlinks = true,
    -- Markers passed to `vim.fs.root` when resolving the project key.
    root_markers = { ".git", ".hg", "package.json" },
    -- SQLite-backed project stores are polled for external events from
    -- other Neovim sessions. Polling is intentionally boring and local.
    poll_interval_ms = 750,
  },
  sinks = {
    -- `clipboard = false` disables the generic clipboard sink.
    -- `cmux.enabled = false` disables the bundled cmux integration.
    -- When enabled, cmux registers only when the integration is available.
  },
  -- Review session (`:PjollrigReview`) rendering.
  review = {
    -- "split"   — side-by-side `:diffsplit`: read-only baseline left,
    --             worktree file right (comments go on the right).
    -- "unified" — one window showing the worktree file with the diff
    --             painted on: added lines highlighted, removed lines
    --             drawn as virtual text where they used to sit. The
    --             buffer IS the file, so comments anchor natively; the
    --             cost is that removed lines are not commentable
    --             (same as the read-only baseline side in split mode).
    diff_mode = "split",
    file_mode = "single",
    -- Collapse unchanged code into folds while reviewing. Off by default:
    -- the full file stays visible; opt in for a hunks-only view. In split
    -- mode `false` disables the native diff folds in both windows.
    fold_unchanged = false,
    -- Unified mode: context lines kept around each hunk.
    context = 3,
    -- Review panel placement. "bottom" (default) is a full-width split
    -- below the diff; "left"/"right" are full-height side splits
    -- ("right" places outermost, so it coexists with the comments
    -- rail); "float" is a centered floating window that takes focus on
    -- open (`q` closes it). `size` overrides the per-position default:
    -- rows for "bottom" (default min(12, #files + 2)), columns for
    -- "left"/"right" (default 30% of the screen clamped to [30, 46]);
    -- "float" ignores it (60% cols x 40% rows). `layout` picks how the
    -- Files tab lists the session pairs: "flat" (default) is one full
    -- path per line, "tree" groups them by directory with collapsible
    -- rollup rows; `t` in the panel toggles it for the session.
    -- Custom tabs may opt into prefetch on session open. Set false to
    -- leave their fetches lazy until first show.
    panel = {
      position = "bottom",
      layout = "flat",
      prefetch = true,
    },
  },
  -- Floating editor + popup UI options.
  ui = {
    enable_mouse = true,
    mouse_comments = true,
    -- The floating comment editor: size, the mode it opens in, and the
    -- submit/cancel keys.
    editor = {
      width = 72,
      height = 6,
      start_mode = "insert",
      submit_keys = { "<CR>" },
      cancel_keys = { "q" },
    },
    opacity = 0.0,
    -- true = always show popups for visible records; false = only when
    -- the record's line is in the viewport (float display mode only).
    always_show_popups = false,
    -- How comment records paint: "float" anchored popups, "eol"
    -- end-of-line virtual text that expands to the full popup while the
    -- cursor is on the line, "inline" bordered virtual-line boxes below
    -- commented lines (code pushed down, never covered), "hidden"
    -- anchors/line-number tint only. "eol" is the default because floats
    -- cover code on long lines; this is only the startup mode — cycle
    -- live with `:PjollrigDisplay`.
    display_mode = "eol",
    -- Where the "eol" mode's cursor expansion renders: "float" keeps
    -- today's anchored popups (they hover over the buffer, with
    -- occlusion-aware placement); "rail" renders the same cards into a
    -- real side window on the far right — a split, so covering code is
    -- structurally impossible. Config-at-setup; read where the
    -- expansion dispatches.
    eol_expand = "float",
    -- Filetype icons and Nerd Font badges in the review UI. "auto"
    -- enables them iff mini.icons or nvim-web-devicons is loadable;
    -- `true` forces glyphs on (your font has them even without a
    -- provider plugin); `false` keeps everything plain text.
    icons = "auto",
  },
}

---Current, merged configuration. Populated by `M.setup`.
---@type pjollrig.Config
local current = vim.deepcopy(defaults)

---Return the current merged config.
---
---The returned table is the LIVE config, not a copy: targeted runtime
---overrides mutate it in place and are picked up by every later read.
---That is the intentional runtime-override channel — e.g.
---`review.set_diff_mode` writes `review.diff_mode` here so the switch
---also becomes the default for later sessions in this Neovim instance
---(there is no `config.set`). Treat everything else as read-only by
---convention.
---@return pjollrig.Config
function M.get()
  return current
end

---Pre-release renames: old key -> new key. `M.setup` errors loudly when
---an old key is present so users get a pointer instead of a silently
---ignored option. No aliasing — the old keys are gone.
local renamed_keys = {
  ["review.mode"] = "review.diff_mode",
  ["review.prefetch"] = "review.panel.prefetch",
  ["store.branch"] = "store.scope_by_branch",
  ["ui.display"] = "ui.display_mode",
  ["ui.expand"] = "ui.eol_expand",
  ["ui.sticky"] = "ui.always_show_popups",
  ["ui.width"] = "ui.editor.width",
  ["ui.height"] = "ui.editor.height",
  ["ui.editor_mode"] = "ui.editor.start_mode",
  ["ui.submit_keys"] = "ui.editor.submit_keys",
  ["ui.cancel_keys"] = "ui.editor.cancel_keys",
}

---@param opts table
local function reject_renamed_keys(opts)
  for old, new in pairs(renamed_keys) do
    if vim.tbl_get(opts, unpack(vim.split(old, ".", { plain = true }))) ~= nil then
      error(("pjollrig: %s was renamed to %s"):format(old, new))
    end
  end
end

---Merge user opts into defaults and run shallow validation.
---@param opts pjollrig.Config|nil
---@return pjollrig.Config
function M.setup(opts)
  opts = opts or {}
  vim.validate("opts", opts, "table")
  reject_renamed_keys(opts)
  vim.validate("store", opts.store, "table", true)
  vim.validate("sinks", opts.sinks, "table", true)
  vim.validate("review", opts.review, "table", true)
  vim.validate("ui", opts.ui, "table", true)
  if opts.store then
    vim.validate("store.dir", opts.store.dir, "string", true)
    vim.validate("store.format", opts.store.format, "string", true)
    vim.validate("store.scope_by_branch", opts.store.scope_by_branch, "boolean", true)
    vim.validate("store.persist_unrooted", opts.store.persist_unrooted, "boolean", true)
    vim.validate("store.canonicalize_symlinks", opts.store.canonicalize_symlinks, "boolean", true)
    vim.validate("store.root_markers", opts.store.root_markers, "table", true)
    vim.validate("store.poll_interval_ms", opts.store.poll_interval_ms, "number", true)
    if opts.store.format ~= nil and opts.store.format ~= "mpack" and opts.store.format ~= "json" then
      error(('pjollrig: store.format must be "mpack" or "json", got %q'):format(tostring(opts.store.format)))
    end
  end
  if opts.sinks then
    -- Each sink may be a boolean (enable/disable) or a table of sink
    -- options; allow both forms.
    vim.validate("sinks.clipboard", opts.sinks.clipboard, { "boolean", "table" }, true)
    vim.validate("sinks.cmux", opts.sinks.cmux, { "boolean", "table" }, true)
    vim.validate("sinks.wezterm", opts.sinks.wezterm, { "boolean", "table" }, true)
    vim.validate("sinks.socket", opts.sinks.socket, { "boolean", "table" }, true)
  end
  if opts.review then
    vim.validate("review.file_mode", opts.review.file_mode, "string", true)
    if opts.review.file_mode ~= nil and opts.review.file_mode ~= "single" and opts.review.file_mode ~= "all" then
      error('pjollrig: review.file_mode must be "single" or "all"')
    end
    vim.validate("review.diff_mode", opts.review.diff_mode, "string", true)
    vim.validate("review.fold_unchanged", opts.review.fold_unchanged, "boolean", true)
    vim.validate("review.context", opts.review.context, "number", true)
    if opts.review.diff_mode ~= nil and opts.review.diff_mode ~= "split" and opts.review.diff_mode ~= "unified" then
      error(('pjollrig: review.diff_mode must be "split" or "unified", got %q'):format(tostring(opts.review.diff_mode)))
    end
    local context = opts.review.context
    if context ~= nil and (context ~= context or context < 0 or context ~= math.floor(context)) then
      error(("pjollrig: review.context must be a non-negative integer, got %s"):format(tostring(context)))
    end
    vim.validate("review.panel", opts.review.panel, "table", true)
    if opts.review.panel then
      vim.validate("review.panel.position", opts.review.panel.position, "string", true)
      vim.validate("review.panel.size", opts.review.panel.size, "number", true)
      vim.validate("review.panel.prefetch", opts.review.panel.prefetch, "boolean", true)
      local position = opts.review.panel.position
      if
        position ~= nil
        and position ~= "bottom"
        and position ~= "left"
        and position ~= "right"
        and position ~= "float"
      then
        error(
          ('pjollrig: review.panel.position must be "bottom", "left", "right", or "float", got %q'):format(
            tostring(position)
          )
        )
      end
      local size = opts.review.panel.size
      if size ~= nil and (size ~= size or size < 1 or size ~= math.floor(size)) then
        error(("pjollrig: review.panel.size must be a positive integer, got %s"):format(tostring(size)))
      end
      vim.validate("review.panel.layout", opts.review.panel.layout, "string", true)
      local layout = opts.review.panel.layout
      if layout ~= nil and layout ~= "flat" and layout ~= "tree" then
        error(('pjollrig: review.panel.layout must be "flat" or "tree", got %q'):format(tostring(layout)))
      end
    end
  end
  if opts.ui then
    vim.validate("ui.enable_mouse", opts.ui.enable_mouse, "boolean", true)
    vim.validate("ui.mouse_comments", opts.ui.mouse_comments, "boolean", true)
    vim.validate("ui.editor", opts.ui.editor, "table", true)
    if opts.ui.editor then
      vim.validate("ui.editor.width", opts.ui.editor.width, "number", true)
      vim.validate("ui.editor.height", opts.ui.editor.height, "number", true)
      vim.validate("ui.editor.start_mode", opts.ui.editor.start_mode, "string", true)
      vim.validate("ui.editor.submit_keys", opts.ui.editor.submit_keys, "table", true)
      vim.validate("ui.editor.cancel_keys", opts.ui.editor.cancel_keys, "table", true)
    end
    vim.validate("ui.opacity", opts.ui.opacity, "number", true)
    vim.validate("ui.always_show_popups", opts.ui.always_show_popups, "boolean", true)
    vim.validate("ui.display_mode", opts.ui.display_mode, "string", true)
    vim.validate("ui.eol_expand", opts.ui.eol_expand, "string", true)
    vim.validate("ui.icons", opts.ui.icons, { "boolean", "string" }, true)
    vim.validate("ui.sink_picker", opts.ui.sink_picker, "function", true)
    local opacity = opts.ui.opacity
    if opacity ~= nil and (opacity ~= opacity or opacity < 0 or opacity > 1) then
      error(("pjollrig: ui.opacity must be between 0.0 and 1.0, got %s"):format(tostring(opacity)))
    end
    local display_mode = opts.ui.display_mode
    if
      display_mode ~= nil
      and display_mode ~= "float"
      and display_mode ~= "eol"
      and display_mode ~= "inline"
      and display_mode ~= "hidden"
    then
      error(
        ('pjollrig: ui.display_mode must be "float", "eol", "inline", or "hidden", got %q'):format(
          tostring(display_mode)
        )
      )
    end
    local eol_expand = opts.ui.eol_expand
    if eol_expand ~= nil and eol_expand ~= "float" and eol_expand ~= "rail" then
      error(('pjollrig: ui.eol_expand must be "float" or "rail", got %q'):format(tostring(eol_expand)))
    end
    local icons = opts.ui.icons
    if icons ~= nil and icons ~= true and icons ~= false and icons ~= "auto" then
      error(('pjollrig: ui.icons must be "auto", true, or false, got %q'):format(tostring(icons)))
    end
  end
  -- `tbl_deep_extend("force", …)` replaces list/array values wholesale
  -- rather than concatenating them, so a user-supplied
  -- `ui.editor.submit_keys`, `ui.editor.cancel_keys`, or
  -- `store.root_markers` fully *replaces* the defaults — which is the
  -- behaviour users expect for key-lists and root markers.
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  -- Ensure the state dir exists once at setup so later saves don't race
  -- the mkdir and `:echo stdpath('state').'/manicule/'` resolves to a real
  -- directory even before the user adds a comment.
  vim.fn.mkdir(current.store.dir, "p")

  return current
end

return M
