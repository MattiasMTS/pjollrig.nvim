local H = require("helpers")

local ctx

local function setup_env(opts)
  ctx = H.setup(opts)
  H.edit_project_file(ctx, "src/display.lua", {
    "local value = 1",
    "value = value + 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

local function floating_windows_containing(text)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      if cfg.relative and cfg.relative ~= "" then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local lines = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if lines:find(text, 1, true) then
          table.insert(wins, winid)
        end
      end
    end
  end
  return wins
end

local function wait_for_popup_count(text, expected)
  return vim.wait(1000, function()
    return #floating_windows_containing(text) == expected
  end, 10)
end

local function popup_title(winid)
  local title = vim.api.nvim_win_get_config(winid).title
  if type(title) == "string" then
    return title
  end
  if type(title) == "table" then
    local parts = {}
    for _, item in ipairs(title) do
      if type(item) == "string" then
        table.insert(parts, item)
      elseif type(item) == "table" and type(item[1]) == "string" then
        table.insert(parts, item[1])
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

---Concatenated text of every eol virt-text extmark on `row` (0-indexed),
---in the pjollrig namespace. Empty string when the row carries none.
local function eol_virt_text(bufnr, row)
  local ns = require("pjollrig.anchor").ns
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_text and details.virt_text_pos == "eol" then
      for _, chunk in ipairs(details.virt_text) do
        table.insert(out, chunk[1])
      end
    end
  end
  return table.concat(out, "")
end

---True when any row of `bufnr` carries eol virt text.
local function has_any_eol_virt_text(bufnr)
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    if eol_virt_text(bufnr, row) ~= "" then
      return true
    end
  end
  return false
end

---Rendered text of the virt_lines block(s) below `row` (0-indexed) in
---the pjollrig namespace: one string per virtual line (chunks joined).
---Empty list when the row carries none.
local function inline_virt_lines(bufnr, row)
  local ns = require("pjollrig.anchor").ns
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    for _, vline in ipairs(details.virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(vline) do
        table.insert(parts, chunk[1])
      end
      table.insert(out, table.concat(parts, ""))
    end
  end
  return out
end

---Raw `[text, hl]` chunk arrays of the virt_lines block(s) below `row`
---(0-indexed) in the pjollrig namespace: one entry per virtual line.
local function inline_virt_chunks(bufnr, row)
  local ns = require("pjollrig.anchor").ns
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    for _, vline in ipairs(details.virt_lines or {}) do
      table.insert(out, vline)
    end
  end
  return out
end

---Number of extmarks on `row` that carry a virt_lines block.
local function inline_block_count(bufnr, row)
  local ns = require("pjollrig.anchor").ns
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
  local count = 0
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_lines and #details.virt_lines > 0 then
      count = count + 1
    end
  end
  return count
end

---True when any row of `bufnr` carries a virt_lines block.
local function has_any_inline_virt_lines(bufnr)
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    if #inline_virt_lines(bufnr, row) > 0 then
      return true
    end
  end
  return false
end

---Move the cursor and deliver the CursorMoved event the plugin's
---viewport autocmd listens for. `nvim_win_set_cursor` alone does not
---fire autocmds, so tests deliver the event explicitly — same contract
---as a real interactive movement.
local function move_cursor(bufnr, line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
end

describe("pjollrig display config", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("rejects an invalid ui.display_mode value", function()
    local ok, err = pcall(require("pjollrig.config").setup, {
      ui = { display_mode = "sideways" },
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("ui.display_mode", 1, true))
    assert.is_truthy(tostring(err):find('"float", "eol", "inline", or "hidden"', 1, true))
  end)

  it("defaults to the eol display mode", function()
    assert.are.equal("eol", require("pjollrig.config").get().ui.display_mode)
    assert.are.equal("eol", require("pjollrig.ui.render").display_mode())
  end)

  it("rejects an invalid ui.eol_expand value", function()
    local ok, err = pcall(require("pjollrig.config").setup, {
      ui = { eol_expand = "sideways" },
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("ui.eol_expand", 1, true))
    assert.is_truthy(tostring(err):find('"float" or "rail"', 1, true))
  end)

  it("defaults ui.eol_expand to float", function()
    assert.are.equal("float", require("pjollrig.config").get().ui.eol_expand)
  end)

  it("rejects an unknown runtime mode without changing the current one", function()
    local render = require("pjollrig.ui.render")
    local mode, err = render.set_display_mode("bogus")
    assert.is_nil(mode)
    assert.is_truthy(tostring(err):find('"float", "eol", "inline", or "hidden"', 1, true))
    assert.are.equal("eol", render.display_mode())
  end)
end)

describe("pjollrig display command", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("completes the four display modes", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local all = vim.fn.getcompletion("PjollrigDisplay ", "cmdline")
    table.sort(all)
    assert.are.same({ "eol", "float", "hidden", "inline" }, all)
    assert.are.same({ "float" }, vim.fn.getcompletion("PjollrigDisplay f", "cmdline"))
  end)

  it("exposes <Plug>(pjollrig-display-cycle)", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    assert.is_true(vim.fn.maparg("<Plug>(pjollrig-display-cycle)", "n") ~= "")
  end)

  it("cycles float → eol → inline → hidden → float with live re-render", function()
    vim.cmd("runtime plugin/pjollrig.lua")
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()

    -- Keep the cursor OFF the comment line so eol mode stays collapsed.
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "cycle note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, ...)
      table.insert(notifications, tostring(msg))
      return original_notify(msg, ...)
    end

    -- Default eol: collapsed marker, no popup.
    assert.are.equal("eol", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.is_truthy(eol_virt_text(bufnr, 0):find("cycle note", 1, true))

    -- Explicit argument: float shows the popup and drops the marker.
    vim.cmd("PjollrigDisplay float")
    assert.are.equal("float", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 1))
    assert.are.equal("", eol_virt_text(bufnr, 0))

    -- Bare command cycles: float → eol.
    vim.cmd("PjollrigDisplay")
    assert.are.equal("eol", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.is_truthy(eol_virt_text(bufnr, 0):find("cycle note", 1, true))

    -- eol → inline: bordered virt_lines box below the anchor, no popup,
    -- no eol marker.
    vim.cmd("PjollrigDisplay")
    assert.are.equal("inline", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.are.equal("", eol_virt_text(bufnr, 0))
    assert.is_truthy(table.concat(inline_virt_lines(bufnr, 0), "\n"):find("cycle note", 1, true))

    -- inline → hidden: no popups, no virt text, no virt lines, anchors
    -- survive.
    vim.cmd("PjollrigDisplay")
    assert.are.equal("hidden", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.is_false(has_any_eol_virt_text(bufnr))
    assert.is_false(has_any_inline_virt_lines(bufnr))
    assert.is_true(next(render.mark_ids_for_buffer(bufnr)) ~= nil)

    -- hidden → float: wraparound, popup returns.
    vim.cmd("PjollrigDisplay")
    assert.are.equal("float", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 1))

    vim.notify = original_notify

    -- Every switch announced with the one-line notify.
    local announced = table.concat(notifications, "\n")
    for _, mode in ipairs({ "float", "eol", "inline", "hidden" }) do
      assert.is_truthy(announced:find("pjollrig: display = " .. mode, 1, true))
    end
  end)
end)

describe("pjollrig eol display mode", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("collapses to eol virt text with the truncated body and no popup", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "first line of the note\nsecond line stays hidden",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()
    local short = tostring(records[1].id):sub(1, 6)

    local text = eol_virt_text(bufnr, 0)
    assert.is_truthy(text:find("●", 1, true))
    assert.is_truthy(text:find("c" .. short, 1, true))
    assert.is_truthy(text:find("first line of the note", 1, true))
    -- Only the first body line renders collapsed.
    assert.is_nil(text:find("second line", 1, true))
    -- Single comment on the line: no n/m counter.
    assert.is_nil(text:find("1/1", 1, true))
    -- No popup window while collapsed.
    assert.is_true(wait_for_popup_count("first line of the note", 0))
  end)

  it("expands the real popup on the cursor line and closes it off-line", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "expand me now",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    assert.is_true(wait_for_popup_count("expand me now", 0))

    -- Cursor onto the comment line: the full float-mode popup opens.
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("expand me now", 1))
    local winid = floating_windows_containing("expand me now")[1]
    assert.is_truthy(popup_title(winid):find("1/1", 1, true))
    -- Edit/delete keymaps stay reachable exactly as in float mode: the
    -- cursor hit-test they route through resolves the record here.
    local records = require("pjollrig").list()
    assert.are.equal(records[1].id, require("pjollrig.ui.render").record_at_cursor(bufnr))

    -- Cursor off the line: popup closes, collapsed marker stays.
    move_cursor(bufnr, 1)
    assert.is_true(wait_for_popup_count("expand me now", 0))
    assert.is_truthy(eol_virt_text(bufnr, 1):find("expand me now", 1, true))
  end)

  it("shows the stack position collapsed and expands the vertical stack", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "stack alpha",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    require("pjollrig").add({
      body = "stack beta",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    -- Collapsed: both markers carry their same-line stack position.
    local text = eol_virt_text(bufnr, 1)
    assert.is_truthy(text:find("1/2", 1, true))
    assert.is_truthy(text:find("2/2", 1, true))
    assert.is_true(wait_for_popup_count("stack alpha", 0))

    -- Expanded: the same vertical stack float mode renders.
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("stack alpha", 1))
    assert.is_true(wait_for_popup_count("stack beta", 1))
    local first = floating_windows_containing("stack alpha")[1]
    local second = floating_windows_containing("stack beta")[1]
    local first_row = tonumber(vim.api.nvim_win_get_config(first).row) or 0
    local second_row = tonumber(vim.api.nvim_win_get_config(second).row) or 0
    assert.is_true(math.abs(first_row - second_row) >= 3)
  end)

  it("refreshes the expanded counter after a mutation on another line", function()
    local bufnr = vim.api.nvim_get_current_buf()
    require("pjollrig").add({
      body = "memo first",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("memo first", 1))
    assert.is_truthy(popup_title(floating_windows_containing("memo first")[1]):find("1/1", 1, true))

    -- A second record lands on ANOTHER line while the cursor stays put,
    -- so line 2's covering set is unchanged: the mutation's reconcile
    -- must drop any memoized display positions, and the refreshed
    -- expansion must read 1/2, not a stale 1/1.
    require("pjollrig").add({
      body = "memo second",
      range = { start = { 2, 0 }, end_ = { 2, 0 } },
    })
    assert.is_true(wait_for_popup_count("memo first", 1))
    assert.is_true(vim.wait(1000, function()
      local winid = floating_windows_containing("memo first")[1]
      return winid ~= nil and popup_title(winid):find("1/2", 1, true) ~= nil
    end, 10))
  end)

  it("keeps the expanded popup open while the comment editor is up", function()
    local bufnr = vim.api.nvim_get_current_buf()
    require("pjollrig").add({
      body = "edit without closing",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("edit without closing", 1))
    local popup_winid = floating_windows_containing("edit without closing")[1]

    -- Open the comment editor from the expanded popup's record. Focus
    -- moves into a pjollrig float; the BufLeave/WinLeave editor
    -- exception applies in eol mode too, so the popup must not close
    -- mid-edit. (The editor float shows the same body text, so assert
    -- on the popup's winid rather than a window count.)
    local records = require("pjollrig").list()
    require("pjollrig").edit(records[1].id)
    assert.is_true(vim.wait(1000, function()
      return require("pjollrig.ui.editor").is_active()
    end, 10))

    vim.wait(50, function()
      return false
    end, 10)
    assert.is_true(vim.api.nvim_win_is_valid(popup_winid))

    require("pjollrig.ui.editor").close_active()
    assert.is_true(vim.wait(1000, function()
      return not require("pjollrig.ui.editor").is_active()
    end, 10))
  end)

  it("truncates the collapsed body to the leftover window width", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = string.rep("x", 300),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local win_width = vim.api.nvim_win_get_width(0)
    local line_width = vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    local text = eol_virt_text(bufnr, 0)
    assert.is_truthy(text:find("…", 1, true))
    assert.is_true(vim.fn.strdisplaywidth(text) <= win_width - line_width - 1)
  end)

  it("truncates a double-width body on whole-glyph boundaries", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = string.rep("古", 200),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local win_width = vim.api.nvim_win_get_width(0)
    local line_width = vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    local text = eol_virt_text(bufnr, 0)
    assert.is_truthy(text:find("…", 1, true))
    assert.is_true(vim.fn.strdisplaywidth(text) <= win_width - line_width - 1)
    -- The truncated body is whole double-width glyphs followed by the
    -- single-cell ellipsis — a split glyph would leave stray bytes here.
    local body = text:match("· (.*)$")
    assert.is_truthy(body)
    assert.are.equal("…", body:sub(-3))
    local glyphs = body:sub(1, -4)
    assert.is_true(#glyphs > 0)
    assert.are.equal(0, #glyphs % 3)
    assert.are.equal(string.rep("古", #glyphs / 3), glyphs)
  end)

  it("relocates the expanded popup below the anchor on a long line", function()
    -- Eol-mode cursor expansion reuses the float placement path, so it
    -- inherits the occlusion-aware placement: on a line too long for the
    -- right margin, the expanded popup drops below the anchor instead of
    -- covering the code. Placement math assumes 'nowrap' — pin it.
    local win_width = vim.api.nvim_win_get_width(0)
    local long_line = "-- " .. string.rep("z", win_width + 60)
    H.edit_project_file(ctx, "src/eol-long.lua", {
      long_line,
      long_line,
      long_line,
      "return true",
    })
    vim.wo.wrap = false
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 4)
    require("pjollrig").add({
      body = "eol avoids margin",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("eol avoids margin", 0))

    -- Cursor onto the long commented line: the popup expands below the
    -- anchor row at the inline-box column, not in the right margin.
    move_cursor(bufnr, 1)
    assert.is_true(wait_for_popup_count("eol avoids margin", 1))
    local cfg = vim.api.nvim_win_get_config(floating_windows_containing("eol avoids margin")[1])
    assert.are.equal(0, cfg.bufpos[1])
    assert.are.equal(1, tonumber(cfg.row))
    assert.are.equal(1, tonumber(cfg.col))
  end)

  it("degrades to a bare marker when the line leaves no room", function()
    local win_width = vim.api.nvim_win_get_width(0)
    H.edit_project_file(ctx, "src/long.lua", {
      "-- " .. string.rep("y", win_width - 10),
      "return true",
    })
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 2)
    require("pjollrig").add({
      body = "body that cannot fit",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()
    local short = tostring(records[1].id):sub(1, 6)

    local text = eol_virt_text(bufnr, 0)
    assert.are.equal("● c" .. short, text)
  end)
end)

-- Origin badges on the collapsed eol marker: the leading chunk is the
-- record's origin badge — github-imported records (`meta.github`) show
-- the GitHub badge on PjollrigBadgeGithubEol, local records the local
-- one on PjollrigBadgeLocalEol (fg-only variants of the card badge
-- groups: the marker sits on the editor line, never on a card). With
-- icons disabled the local ASCII fallback IS today's `●`, so the
-- icons-off default look stays byte-identical to before badges existed.
describe("pjollrig eol origin badges", function()
  before_each(setup_env)

  after_each(function()
    package.preload["mini.icons"] = nil
    package.loaded["mini.icons"] = nil
    pcall(function()
      require("pjollrig.ui.icons")._reset()
    end)
    teardown_env()
  end)

  ---First eol virt-text chunk (`[text, hl]`) on `row` (0-indexed), in
  ---the pjollrig namespace. Nil when the row carries no eol marker.
  local function first_eol_chunk(bufnr, row)
    local ns = require("pjollrig.anchor").ns
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if details.virt_text and details.virt_text_pos == "eol" then
        return details.virt_text[1]
      end
    end
    return nil
  end

  ---A github-imported record shaped like `review/import.lua` stores it:
  ---the `meta.github` table marks the origin.
  local function github_record(bufnr)
    return {
      id = "ghimport-1",
      uri = require("pjollrig.uri").for_bufnr(bufnr),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "imported note",
      author = "octocat",
      created_at = os.time(),
      updated_at = os.time(),
      resolved = false,
      meta = { github = { id = 99, imported = true } },
    }
  end

  ---Force glyph mode without the real plugins: stub a provider module
  ---via package.preload (the icons_spec pattern) and re-probe.
  local function enable_glyph_mode()
    package.preload["mini.icons"] = function()
      return {
        get = function()
          return "X", "MiniIconsAzure", false
        end,
      }
    end
    require("pjollrig.config").get().ui.icons = "auto"
    require("pjollrig.ui.icons")._reset()
  end

  it("marks imported records with the ASCII github badge when icons are off", function()
    require("pjollrig.config").get().ui.icons = false
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    local record = github_record(bufnr)
    render.reconcile(bufnr, { record }, { record })

    assert.are.equal("[gh] cghimpo · imported note", eol_virt_text(bufnr, 0))
    -- The badge chunk carries the fg-only eol GitHub badge group (no
    -- card surface — the marker sits on the editor line).
    local chunk = first_eol_chunk(bufnr, 0)
    assert.are.equal("[gh] ", chunk[1])
    assert.are.equal("PjollrigBadgeGithubEol", chunk[2])
  end)

  it("marks imported records with the github glyph when a provider is loadable", function()
    enable_glyph_mode()
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    local record = github_record(bufnr)
    render.reconcile(bufnr, { record }, { record })

    local chunk = first_eol_chunk(bufnr, 0)
    assert.are.equal("\u{F09B} ", chunk[1])
    assert.are.equal("PjollrigBadgeGithubEol", chunk[2])
  end)

  it("marks local records with the local glyph when a provider is loadable", function()
    enable_glyph_mode()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "local glyph note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local chunk = first_eol_chunk(bufnr, 0)
    assert.are.equal("\u{F0B79} ", chunk[1])
    assert.are.equal("PjollrigBadgeLocalEol", chunk[2])
  end)

  it("keeps today's ● marker byte-identically for local records with icons off", function()
    require("pjollrig.config").get().ui.icons = false
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "plain local note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()
    local short = tostring(records[1].id):sub(1, 6)

    assert.are.equal("● c" .. short .. " · plain local note", eol_virt_text(bufnr, 0))
  end)
end)

describe("pjollrig inline display mode", function()
  before_each(function()
    setup_env()
    require("pjollrig.ui.render").set_display_mode("inline")
  end)
  after_each(teardown_env)

  it("renders a bordered virt_lines box below the anchor, no popup", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    require("pjollrig").add({
      body = "boxed body first\nboxed body second",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("pjollrig").list()
    local short = tostring(records[1].id):sub(1, 6)

    local lines = inline_virt_lines(bufnr, 0)
    -- Card order: top border (title), quoted anchor excerpt, author +
    -- relative time, blank separator, two body lines, hint, bottom
    -- border.
    assert.are.equal(8, #lines)
    assert.is_truthy(lines[1]:find("┌", 1, true))
    assert.is_truthy(lines[1]:find("c" .. short .. " 1/1", 1, true))
    assert.is_truthy(lines[2]:find('▍ "local value = 1"', 1, true))
    assert.is_truthy(lines[3]:find("· just now", 1, true))
    -- The separator row is border + padding only.
    assert.is_truthy((lines[4]:gsub("│", "")):match("^%s*$"))
    assert.is_truthy(lines[5]:find("boxed body first", 1, true))
    assert.is_truthy(lines[6]:find("boxed body second", 1, true))
    assert.is_truthy(lines[7]:find("edit gca | delete gcd", 1, true))
    assert.is_truthy(lines[#lines]:find("└", 1, true))
    for _, line in ipairs(lines) do
      assert.is_truthy(line:find("│", 1, true) or line:find("─", 1, true))
    end

    -- Card rows split into per-chunk highlights: the quote's `▍ ` bar
    -- is its own accent chunk ahead of the dim quote text, the author
    -- name is bold and separate from the dim time tail, body rows keep
    -- the box body group, and the hint row is the quietest (border
    -- gray). Helpers find a row's chunk by text / by group since the
    -- frame adds indent/border/padding chunks around the card content.
    local chunks = inline_virt_chunks(bufnr, 0)
    local function hl_of(row_chunks, needle)
      for _, chunk in ipairs(row_chunks) do
        if chunk[1]:find(needle, 1, true) then
          return chunk[2]
        end
      end
      return nil
    end
    local function text_of(row_chunks, hl)
      for _, chunk in ipairs(row_chunks) do
        if chunk[2] == hl then
          return chunk[1]
        end
      end
      return nil
    end
    assert.are.equal("PjollrigCommentQuoteBar", hl_of(chunks[2], "▍"))
    assert.are.equal("PjollrigInlineQuote", hl_of(chunks[2], '"local value = 1"'))
    assert.are.equal("▍ ", text_of(chunks[2], "PjollrigCommentQuoteBar"))
    -- Author row: bold author-name chunk + dim `· just now` tail.
    assert.is_truthy(text_of(chunks[3], "PjollrigCommentAuthor"))
    assert.are.equal("PjollrigInlineMeta", hl_of(chunks[3], "· just now"))
    assert.is_truthy(text_of(chunks[3], "PjollrigInlineMeta"):find("· just now", 1, true))
    assert.is_nil(text_of(chunks[3], "PjollrigCommentAuthor"):find("·", 1, true))
    assert.are.equal("PjollrigInlineBody", hl_of(chunks[5], "boxed body first"))
    assert.are.equal("PjollrigCommentHint", hl_of(chunks[7], "edit gca | delete gcd"))

    -- The code lines themselves are untouched — the box is virtual only.
    assert.are.same(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    -- No eol marker and no popup window in inline mode.
    assert.are.equal("", eol_virt_text(bufnr, 0))
    assert.is_true(wait_for_popup_count("boxed body first", 0))
  end)

  it("renders a same-line stack as one block, in stack order with 1/2 2/2", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "stack alpha",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    require("pjollrig").add({
      body = "stack beta",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    -- Expected order = the shared stack comparator (created_at, then id).
    local records = require("pjollrig").list()
    table.sort(records, function(a, b)
      local ac = tonumber(a.created_at) or 0
      local bc = tonumber(b.created_at) or 0
      if ac ~= bc then
        return ac < bc
      end
      return tostring(a.id or "") < tostring(b.id or "")
    end)
    local first_short = tostring(records[1].id):sub(1, 6)
    local second_short = tostring(records[2].id):sub(1, 6)

    -- ONE virt_lines block on the anchor line carries both boxes.
    assert.are.equal(1, inline_block_count(bufnr, 1))
    local joined = table.concat(inline_virt_lines(bufnr, 1), "\n")
    local first_title = joined:find("c" .. first_short .. " 1/2", 1, true)
    local second_title = joined:find("c" .. second_short .. " 2/2", 1, true)
    assert.is_truthy(first_title)
    assert.is_truthy(second_title)
    assert.is_true(first_title < second_title)
    local first_body = joined:find(records[1].body, 1, true)
    local second_body = joined:find(records[2].body, 1, true)
    assert.is_true(first_body > first_title and first_body < second_title)
    assert.is_true(second_body > second_title)
    assert.is_true(wait_for_popup_count("stack alpha", 0))
  end)

  it("keeps edit/delete reachable from the anchor line without a popup", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "act on me",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    -- Cursor onto the commented line: unlike eol, NO popup expands — the
    -- box already shows the full body + footer hints.
    move_cursor(bufnr, 2)
    vim.wait(200, function()
      return #floating_windows_containing("act on me") > 0
    end, 10)
    assert.are.equal(0, #floating_windows_containing("act on me"))

    -- The `<Plug>` edit/delete keymaps route through the same cursor
    -- hit-test as float/eol mode and still resolve the record here.
    local records = require("pjollrig").list()
    assert.are.equal(records[1].id, require("pjollrig.ui.render").record_at_cursor(bufnr))
  end)

  it("wraps a long body line to the box width", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    local body = ("wrap "):rep(40):gsub("%s+$", "")
    require("pjollrig").add({
      body = body,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local win_width = vim.api.nvim_win_get_width(0)
    local lines = inline_virt_lines(bufnr, 0)
    assert.is_true(#lines > 0)
    local body_line_count = 0
    for _, line in ipairs(lines) do
      -- Every rendered virtual line fits the window (no clipping).
      assert.is_true(vim.fn.strdisplaywidth(line) <= win_width)
      if line:find("wrap", 1, true) then
        body_line_count = body_line_count + 1
      end
    end
    -- The single long body line wrapped across several box lines.
    assert.is_true(body_line_count >= 2)
  end)

  it("hard-breaks a double-width body across box lines without splitting glyphs", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    -- One long spaceless CJK "word" (160 cells): forces the wrap path's
    -- hard-break char walk, where a glyph split would show as broken
    -- bytes and an off-by-one width.
    require("pjollrig").add({
      body = string.rep("古", 80),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local win_width = vim.api.nvim_win_get_width(0)
    local lines = inline_virt_lines(bufnr, 0)
    assert.is_true(#lines > 0)
    local body_line_count = 0
    for _, line in ipairs(lines) do
      -- Every rendered virtual line fits the window (no clipping).
      assert.is_true(vim.fn.strdisplaywidth(line) <= win_width)
      if line:find("古", 1, true) then
        body_line_count = body_line_count + 1
      end
    end
    -- Wrapped across several box lines, with every glyph intact.
    assert.is_true(body_line_count >= 2)
    local joined = table.concat(lines, "\n")
    local _, glyph_count = joined:gsub("古", "")
    assert.are.equal(80, glyph_count)
  end)

  it("anchors a multi-line record's box at the range start line", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "range note",
      range = { start = { 0, 0 }, end_ = { 1, 0 } },
    })

    assert.is_truthy(table.concat(inline_virt_lines(bufnr, 0), "\n"):find("range note", 1, true))
    assert.are.same({}, inline_virt_lines(bufnr, 1))
  end)

  it("clears the boxes on :PjollrigToggle and restores them on toggle back", function()
    local render = require("pjollrig.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("pjollrig").add({
      body = "toggle me away",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(has_any_inline_virt_lines(bufnr))

    render.toggle()
    assert.is_false(has_any_inline_virt_lines(bufnr))

    render.toggle()
    assert.is_true(has_any_inline_virt_lines(bufnr))
    assert.is_truthy(table.concat(inline_virt_lines(bufnr, 0), "\n"):find("toggle me away", 1, true))
  end)
end)
