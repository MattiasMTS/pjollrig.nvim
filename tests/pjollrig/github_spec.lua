local H = require("helpers")
local P = require("pjollrig")
local api = vim.api
local gh_ns = api.nvim_create_namespace("pjollrig-gh")

local function open_pr(n)
  vim.fn.setqflist({}, " ", { title = "none" })
  vim.cmd("Pjollrig review pr " .. n)
  assert(
    vim.wait(15000, function()
      return vim.fn.getqflist({ context = 1 }).context == "pjollrig" and #require("pjollrig.github").threads > 0
    end, 10),
    "PR review did not open"
  )
  vim.wait(50)
end

local function thread(path, side, line, body, extra)
  return vim.tbl_extend("force", {
    path = path,
    diffSide = side,
    line = line,
    isResolved = false,
    comments = { nodes = { { author = { login = "alice" }, body = body } } },
  }, extra or {})
end

describe("github", function()
  local origin, clone, full, head, base
  before_each(function()
    H.reset()
    origin = H.repo({ ["mod.txt"] = { "a", "b", "c" }, ["old.lua"] = { "x", "y", "z", "w" } })
    H.git(origin, "config", "uploadpack.allowFilter", "true")
    H.git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")
    H.git(origin, "checkout", "-q", "-b", "pr")
    H.write(origin .. "/mod.txt", { "a", "B", "c" })
    H.git(origin, "mv", "old.lua", "new.lua")
    H.git(origin, "commit", "-qam", "pr")
    head = H.git(origin, "rev-parse", "HEAD")
    H.git(origin, "update-ref", "refs/pull/7/head", head)
    H.git(origin, "checkout", "-q", "main")
    H.git(origin, "branch", "-D", "pr") -- the PR branch itself is gone; refs/pull/N/head remains
    clone = H.tmp() .. "/c"
    H.git(H.tmp(), "clone", "-q", "--filter=blob:none", "file://" .. origin, clone)
    clone = vim.uv.fs_realpath(clone)
    full = H.tmp() .. "/f" -- no lazy fetch here to paper over a base that was never fetched
    H.git(H.tmp(), "clone", "-q", "file://" .. origin, full)
    H.write(origin .. "/later.txt", { "main moved on" }) -- after the clone: the base tip is fetched by sha (RV-m4)
    H.git(origin, "add", ".")
    H.git(origin, "commit", "-qm", "later")
    base = H.git(origin, "rev-parse", "HEAD")
    vim.cmd.cd(clone)
    local d = H.shims({
      gh = 'd=$(dirname "$0"); case "$1 $2" in "pr view") cat "$d/pr.json";; "api graphql") echo "$@" > "$d/gql";'
        .. ' cat "$d/threads.json";; esac',
    })
    H.write(d .. "/pr.json", { vim.json.encode({ headRefOid = head, baseRefOid = base }) })
    H.write(d .. "/threads.json", {
      vim.json.encode({
        data = {
          repository = {
            pullRequest = {
              reviewThreads = {
                pageInfo = { hasNextPage = false },
                nodes = {
                  thread("mod.txt", "RIGHT", 2, "RIGHT on B"),
                  thread("new.lua", "LEFT", 3, "LEFT on z\nmore", { isResolved = true }),
                  thread("mod.txt", "RIGHT", vim.NIL, "file level"),
                  thread("mod.txt", "RIGHT", vim.NIL, "stale", { isOutdated = true, originalLine = 3 }),
                },
              },
            },
          },
        },
      }),
    })
  end)

  it("no checkout: read-only pjollrig:// panes at merge-base and head, prefetched (D-B2, RV-M2, RV-m4)", function()
    local status = H.git(clone, "status", "--porcelain")
    open_pr(7)
    assert.are.equal(status, H.git(clone, "status", "--porcelain"))
    assert.are.equal(head, H.git(clone, "rev-parse", "refs/pjollrig/pr/7"))
    local mb = H.git(clone, "merge-base", head, base)
    local q = vim.tbl_map(function(e)
      return e.text .. " " .. api.nvim_buf_get_name(e.bufnr)
    end, vim.fn.getqflist())
    assert.are.same({
      "M " .. P.name("new", clone, head, "mod.txt"),
      "R old.lua → " .. P.name("new", clone, head, "new.lua"),
    }, q)
    H.git(clone, "remote", "set-url", "origin", "file:///nonexistent") -- every blob must already be local
    vim.cmd("cnext")
    vim.wait(50)
    local wins = api.nvim_tabpage_list_wins(0)
    local l, r = api.nvim_win_get_buf(wins[1]), api.nvim_win_get_buf(wins[2])
    assert.are.equal(P.name("old", clone, mb, "old.lua"), api.nvim_buf_get_name(l))
    assert.are.same({ "x", "y", "z", "w" }, api.nvim_buf_get_lines(l, 0, -1, false))
    assert.are.same({ "x", "y", "z", "w" }, api.nvim_buf_get_lines(r, 0, -1, false))
    assert.are.same({ "nofile", false }, { vim.bo[r].buftype, vim.bo[r].modifiable })
    local m = api.nvim_buf_get_extmarks(l, gh_ns, 0, -1, { details = true })
    assert.are.equal(1, #m) -- U1: a LEFT thread on a renamed file is painted on the old path
    assert.are.same(
      { 2, "GH", " [gh @alice, resolved] LEFT on z" },
      { m[1][2], vim.trim(m[1][4].sign_text), m[1][4].virt_text[1][1] }
    )
    assert(vim.fn.readfile(vim.fn.fnamemodify(vim.fn.exepath("gh"), ":h") .. "/gql")[1]:find("owner={owner}", 1, true))
  end)

  it(
    "threads: listed in the loclist, never editable, never stored (D-B1); full clone fetches the base by sha",
    function()
      clone = vim.uv.fs_realpath(full)
      vim.cmd.cd(clone)
      assert(not H.git(clone, "rev-list", "--all"):find(base, 1, true), "the base tip must not be local yet")
      open_pr(7)
      local r = api.nvim_get_current_buf()
      local m = api.nvim_buf_get_extmarks(r, gh_ns, 0, -1, { details = true })
      assert.are.same(
        { { 0, " [gh @alice] file level" }, { 1, " [gh @alice] RIGHT on B" } },
        vim.tbl_map(function(x)
          return { x[2], x[4].virt_text[1][1] }
        end, m)
      )
      api.nvim_win_set_cursor(0, { 2, 0 })
      local notified, notify = nil, vim.notify
      vim.notify = function(msg)
        notified = msg
      end
      vim.cmd("Pjollrig edit")
      vim.cmd("Pjollrig resolve")
      vim.notify = notify
      assert.are.equal("pjollrig: no comments", notified)
      P.add({ body = "mine on the PR head" })
      P.loclist()
      local texts = vim.tbl_map(function(e)
        return e.text
      end, vim.fn.getloclist(0))
      assert.are.same({
        "mine on the PR head",
        "[gh @alice] RIGHT on B",
        "[gh @alice, resolved] LEFT on z",
        "[gh @alice] file level",
        "mod.txt (outdated) [gh @alice] stale", -- m7: its line is gone, so never painted at a guess
      }, texts)
      local log = table.concat(vim.fn.readfile(require("pjollrig.store").path(clone)), "\n")
      assert(not log:find("RIGHT on B", 1, true) and log:find("mine on the PR head", 1, true))
      assert.are.equal(head, P.list()[1].rev)
    end
  )
end)
