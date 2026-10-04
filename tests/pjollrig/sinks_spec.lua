local H = require("helpers")
local P = require("pjollrig")
local K = require("pjollrig.sinks")
local S = require("pjollrig.store")
local uv = vim.uv

local clip = {}
vim.g.clipboard = {
  name = "test",
  copy = {
    ["+"] = function(lines)
      clip = lines
    end,
    ["*"] = function(lines)
      clip = lines
    end,
  },
  paste = {
    ["+"] = function()
      return clip
    end,
    ["*"] = function()
      return clip
    end,
  },
}

local sent
vim.api.nvim_create_autocmd("User", {
  pattern = "PjollrigSent",
  callback = function(ev)
    sent = ev.data
  end,
})
local function send(name)
  sent = nil
  K.send(name)
  vim.wait(8000, function()
    return sent ~= nil
  end, 10)
  return sent
end

local function pi_server(ack) -- records requests; ack=false stalls (got.client kept for a manual reply)
  local path, got, server = H.tmp() .. "/sink.sock", {}, uv.new_pipe(false)
  server:bind(path)
  server:listen(8, function()
    local c, buf = uv.new_pipe(false), ""
    server:accept(c)
    got.client = c
    c:read_start(function(_, chunk)
      buf = buf .. (chunk or "")
      local line = buf:match("^(.-)\n")
      if line and not got[1] then
        got[1] = vim.json.decode(line)
        if ack ~= false then
          c:write('{"ok":true}\n')
        end
      end
    end)
  end)
  vim.env.PI_REVIEW_SOCKET = path
  return got
end

local PATH, root = vim.env.PATH, nil
local function comment(body, lnum)
  vim.cmd.edit(root .. "/a.lua")
  vim.api.nvim_win_set_cursor(0, { lnum or 1, 0 })
  P.add({ body = body })
end

describe("sinks", function()
  local opts
  before_each(function()
    opts = { sinks = { pi = { auto_submit = false }, cmux = { auto_submit = true, submit_delay_ms = 1 } } }
    H.reset(opts)
    root = H.repo()
    vim.cmd.cd(root)
    vim.env.PATH, vim.env.CMUX_WORKSPACE_ID, vim.env.WEZTERM_PANE, vim.env.PI_REVIEW_SOCKET = PATH, nil, nil, nil
  end)

  it("format: pi-pinned bytes; ranges, @sha7 and unpinned old sides carry their anchor (R-R7, RV-M4)", function()
    local base = { path = "first.txt", side = "new", lnum = 1, end_lnum = 1, line = "x", body = "AUTO_SUBMIT_CHECK" }
    assert.are.equal("Pjollrig review (1 comment):\n\n## M1 first.txt:1\nAUTO_SUBMIT_CHECK", K.format({ base }))
    local recs = {
      vim.tbl_extend("force", base, { lnum = 2, end_lnum = 4, body = "a\n\nb" }),
      vim.tbl_extend("force", base, { side = "old", rev = "abcdef0123", body = "c" }),
      vim.tbl_extend("force", base, { side = "old", line = "  local x = 1", body = "d" }),
    }
    assert.are.equal(
      "Pjollrig review (3 comments):\n\n## M1 first.txt:2-4\na\n\nb\n\n## M2 first.txt:1 (old @abcdef0)\nc"
        .. "\n\n## M3 first.txt:1 (old)\n>   local x = 1\nd",
      K.format(recs)
    )
  end)

  it("pi: payload + live auto_submit; ack resolves and hides (R-R4, R-R7, RV-m7)", function()
    comment("AUTO_SUBMIT_CHECK")
    local got = pi_server()
    opts.sinks.pi.auto_submit = true -- the pi test flips this after setup
    assert.are.same({ sink = "pi", ok = true, count = 1 }, send("pi"))
    assert.are.same(
      { text = "Pjollrig review (1 comment):\n\n## M1 a.lua:1\nAUTO_SUBMIT_CHECK", auto_submit = true },
      got[1]
    )
    assert.are.equal(0, #P.list())
    assert.are.equal("pi", P.list({ all = true })[1].sent_to)
    require("pjollrig").setup() -- no sinks key: must not throw on send (RV-m7)
    comment("again")
    pi_server()
    assert.are.equal(true, send("pi").ok)
  end)

  it("pi: missing socket, stalled socket and mid-send edits keep comments unresolved (F14, F15)", function()
    comment("KEEP")
    vim.env.PI_REVIEW_SOCKET = H.tmp() .. "/nope.sock"
    assert.are.equal(false, send("pi").ok)
    opts.sinks.pi.timeout_ms = 200
    pi_server(false)
    assert.are.equal(false, send("pi").ok)
    assert.are.equal(1, #P.list())
    local got = pi_server(false)
    sent = nil
    K.send("pi")
    vim.wait(2000, function()
      return got[1] ~= nil
    end, 10)
    local r = P.list()[1]
    S.patch(root, { { r.id, { body = "edited while sending" } } })
    got.client:write('{"ok":true}\n')
    vim.wait(2000, function()
      return sent ~= nil
    end, 10)
    assert.are.equal(true, sent.ok)
    assert.are.equal("edited while sending", P.list()[1].body)
  end)

  it("cmux: auto-picks the one agent surface, chunks reassemble, submits (RV-M3)", function()
    local d = H.shims({
      cmux = 'echo "$@" >> "$(dirname "$0")/log"; case "$1" in tree) cat "$(dirname "$0")/tree";;'
        .. ' set-buffer) printf %s "$5" >> "$(dirname "$0")/pasted";; esac',
    })
    H.write(d .. "/tree", {
      '  surface surface:1 [terminal] "π - review" tty=a',
      '  surface surface:2 [terminal] "zsh"',
      '  surface surface:3 [terminal] "nvim" ◀ here',
    })
    vim.env.CMUX_WORKSPACE_ID = "WS"
    comment(("long line %d\n"):rep(150):format(unpack(vim.fn.range(150))):gsub("\n$", ""))
    vim.ui.select = function()
      error("must not ask")
    end
    assert.are.equal(true, send("cmux").ok)
    local log = table.concat(vim.fn.readfile(d .. "/log"), "\n")
    assert(log:find("tree --workspace WS", 1, true) and log:find("send-key --surface surface:1 enter", 1, true), log)
    assert(select(2, log:gsub("paste%-buffer", "")) > 1, "expected several chunks")
    assert.are.equal(K.format(P.list({ all = true })), table.concat(vim.fn.readfile(d .. "/pasted", "b"), "\n"))
  end)

  it("cmux: no agent surface -> asks, and never auto-submits into a shell (RV-M3)", function()
    local d =
      H.shims({ cmux = 'echo "$@" >> "$(dirname "$0")/log"; [ "$1" = tree ] && cat "$(dirname "$0")/tree"; true' })
    H.write(d .. "/tree", {
      '  surface surface:2 [terminal] "~/src/pi-mono"', -- cwd titles of shells: not agents (m2)
      '  surface surface:4 [terminal] "~/claude-notes"',
      '  surface surface:3 [terminal] "nvim" ◀ here',
    })
    vim.env.CMUX_WORKSPACE_ID = "WS"
    comment("x")
    local asked
    vim.ui.select = function(items, _, cb)
      asked = items
      cb(nil)
    end
    assert.are.same({ sink = "cmux", ok = false, err = "no target picked", count = 1 }, send("cmux")) -- n4
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end
    assert.are.equal(true, send("cmux").ok)
    assert.are.equal("surface:2", asked[1].ref)
    assert(not table.concat(vim.fn.readfile(d .. "/log"), "\n"):find("send-key", 1, true))
  end)

  it("cmux: a linked worktree sends to the workspace recorded by worktrunk", function()
    local d =
      H.shims({ cmux = 'echo "$@" >> "$(dirname "$0")/log"; [ "$1" = tree ] && echo \'s surface:1 "claude"\'; true' })
    local wt = H.tmp() .. "/wt"
    H.git(root, "worktree", "add", "-q", "-b", "mattiasmts/x", wt)
    H.write(root .. "/.git/wt/cmux/mattiasmts-x", { "OWNER" })
    vim.env.CMUX_WORKSPACE_ID = "HERE"
    root = vim.uv.fs_realpath(wt)
    vim.cmd.cd(root)
    comment("x")
    assert.are.equal(true, send("cmux").ok)
    assert.are.equal("tree --workspace OWNER", vim.fn.readfile(d .. "/log")[1])
  end)

  it("wezterm: agent pane gets the text over stdin plus a submit", function()
    local d = H.shims({
      wezterm = 'echo "$@" >> "$(dirname "$0")/log"; case "$2" in list) cat "$(dirname "$0")/panes";;'
        .. ' send-text) [ "$5" = --no-paste ] || cat >> "$(dirname "$0")/text";; esac',
    })
    H.write(d .. "/panes", {
      vim.json.encode({
        { pane_id = 1, title = "zsh" },
        { pane_id = 2, title = "claude" },
        { pane_id = 9, title = "nvim" },
      }),
    })
    vim.env.WEZTERM_PANE = "9"
    opts.sinks.wezterm = { auto_submit = true }
    comment("w")
    assert.are.equal(true, send("wezterm").ok)
    assert.are.equal(
      "Pjollrig review (1 comment):\n\n## M1 a.lua:1\nw",
      table.concat(vim.fn.readfile(d .. "/text", "b"), "\n")
    )
    assert(table.concat(vim.fn.readfile(d .. "/log"), "\n"):find("send-text --pane-id 2 --no-paste", 1, true))
  end)

  it("GitHub threads reach no sink payload and never the log (D-B1)", function()
    local d = H.shims({
      cmux = '[ "$1" = tree ] && echo \'s surface:1 "claude"\'; [ "$1" = set-buffer ] && printf %s "$5" >> "$(dirname "$0")/out"; true',
      wezterm = '[ "$2" = list ] && echo \'[{"pane_id":2,"title":"claude"}]\'; [ "$2" = send-text ] && cat >> "$(dirname "$0")/out"; true',
    })
    vim.env.CMUX_WORKSPACE_ID, vim.env.WEZTERM_PANE = "WS", "9"
    local thread =
      { id = "gh-SECRET", root = root, path = "a.lua", side = "new", lnum = 1, author = "x", body = "SECRET" }
    package.loaded["pjollrig.github"] = {
      threads = { thread },
      paint = function() end,
      items = function()
        return { { filename = root .. "/a.lua", lnum = 1, text = "[gh @x] SECRET" } }
      end,
    }
    local payloads = {}
    for _, name in ipairs({ "pi", "clipboard", "cmux", "wezterm" }) do
      comment("mine " .. name)
      local got = pi_server()
      assert.are.equal(true, send(name).ok, name)
      payloads[#payloads + 1] = got[1] and got[1].text or ""
    end
    vim.list_extend(payloads, clip)
    vim.list_extend(payloads, vim.fn.readfile(d .. "/out"))
    for _, p in ipairs(payloads) do
      assert(not p:find("SECRET"), p)
    end
    assert(table.concat(payloads):find("mine wezterm", 1, true))
    assert(not table.concat(vim.fn.readfile(S.path(root)), "\n"):find("SECRET"))
  end)

  it("chunks reproduce the text byte for byte", function()
    local text = ("x"):rep(2500) .. "\n" .. ("ab\n"):rep(700) .. "tail"
    local parts = K._chunks(text, 1024)
    assert.are.equal(text, table.concat(parts))
    for _, c in ipairs(parts) do
      assert(#c <= 1024)
    end
  end)
end)
