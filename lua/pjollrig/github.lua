-- :Pjollrig review pr N — no checkout: both sides are read-only pjollrig:// buffers at the PR's commits.
-- Review threads are context only. They live in M.threads (memory), are painted and listed, and are never
-- stored or sent (send reads only the store).
local M = { threads = {} }
local api = vim.api
local R = require("pjollrig.review")
local ns = api.nvim_create_namespace("pjollrig-gh")

local QUERY = [[query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){
reviewThreads(first:100){nodes{path diffSide line isOutdated isResolved
comments(first:50){nodes{author{login} body}}}}}}}]]

-- Fetching is the point here: blob:none clones prefetch both sides in one batch (fetch=true).
local function step(root, argv, cb)
  R.git(root, argv, function(r)
    if r.code ~= 0 then
      return vim.notify(("pjollrig: %s %s: %s"):format(argv[1], argv[2], r.stderr), vim.log.levels.ERROR)
    end
    cb(r.stdout)
  end, true)
end

-- LEFT = merge-base(head, base) like GitHub's diff; the base is fetched by sha (its branch may be deleted).
local SCRIPT = [[b=$(git merge-base "$1" "$2") && printf '%s\0' "$b" && git diff --name-status -z -M "$b" "$1" &&
git diff --numstat -M "$b" "$1" >/dev/null]]

function M.start(n)
  local root = R.root()
  if not root then
    return
  elseif not tonumber(n) then
    return vim.notify("pjollrig: usage :Pjollrig review pr <number>", vim.log.levels.ERROR)
  end
  step(root, { "gh", "pr", "view", n, "--json", "headRefOid,baseRefOid" }, function(out)
    local pr = vim.json.decode(out)
    -- ponytail: refs/pjollrig/pr/N is never deleted and has no reflog, so after a force-push gc may prune the old
    -- head and its comments reopen as error placeholders (RV-m5). Per-head refs if that bites.
    local pull = ("+refs/pull/%s/head:refs/pjollrig/pr/%s"):format(n, n)
    step(root, { "git", "fetch", "-q", "--no-tags", "origin", pull, pr.baseRefOid }, function()
      step(root, { "sh", "-c", SCRIPT, "sh", pr.headRefOid, pr.baseRefOid }, function(o)
        local base, rest = o:match("^(%x+)%z(.*)$")
        local files = R.parse(rest)
        M.threads = {}
        R.open({ root = root, base = base, head = pr.headRefOid, title = "pr " .. n }, files)
        M.load(root, n, files, base, pr.headRefOid)
      end)
    end)
  end)
end

function M.load(root, n, files, base, head)
  local q =
    { "gh", "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", "n=" .. n, "-f", "query=" .. QUERY }
  step(root, q, function(out)
    local t = vim.json.decode(out, { luanil = { object = true } }).data.repository.pullRequest.reviewThreads
    local old = {}
    for _, f in ipairs(files) do
      old[f.path] = f.old
    end
    for _, th in ipairs(t.nodes) do
      local left, c = th.diffSide == "LEFT", th.comments.nodes
      M.threads[#M.threads + 1] = {
        root = root,
        path = left and old[th.path] or th.path, -- LEFT threads on renamed files carry the new path
        side = left and "old" or "new",
        rev = left and base or head,
        lnum = not th.isOutdated and (th.line or 1) or nil, -- file-level: 1; outdated: listed, never painted
        resolved = th.isResolved,
        text = ("[gh @%s%s] %s%s"):format(
          c[1] and c[1].author and c[1].author.login or "ghost",
          th.isResolved and ", resolved" or "",
          (c[1] and c[1].body or ""):match("[^\r\n]*"),
          #c > 1 and (" (+%d)"):format(#c - 1) or ""
        ),
      }
    end
    require("pjollrig").refresh()
  end)
end

function M.paint(buf, a)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, t in ipairs(M.threads) do
    if t.lnum and t.root == a.root and t.path == a.path and t.side == a.side and t.rev == a.rev then
      pcall(api.nvim_buf_set_extmark, buf, ns, t.lnum - 1, 0, {
        sign_text = "GH",
        sign_hl_group = t.resolved and "Comment" or "DiagnosticHint",
        virt_text = { { " " .. t.text, t.resolved and "Comment" or "DiagnosticVirtualTextHint" } },
        virt_text_pos = "eol",
        priority = 7,
      })
    end
  end
end

function M.items() -- loclist rows; read-only (not in the store, so edit/delete/resolve never see them)
  return vim.tbl_map(function(t)
    if not t.lnum then -- outdated: its line is gone from the head, so text only
      return { text = ("%s (outdated) %s"):format(t.path, t.text) }
    end
    return { filename = require("pjollrig").name(t.side, t.root, t.rev, t.path), lnum = t.lnum, text = t.text }
  end, M.threads)
end

return M
