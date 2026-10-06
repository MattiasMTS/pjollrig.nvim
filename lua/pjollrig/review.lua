-- Review = a quickfix list of changed files. Entering one pairs it with a read-only
-- pjollrig://<side><root>//<rev>:<path> buffer in a native diff split (nvim.difftool pattern). Nothing staged on disk.
local M = {}
local api = vim.api
M.EMPTY = "4b825dc642cb6eb9a060e54bf8d69288fbee4904" -- the empty tree: placeholder side of A/D/? files

---Run argv (git, or sh around git) with a scrubbed env: no inherited repo/index, no prompts,
---no lazy fetch unless `fetch` (PR prefetch).
function M.git(root, argv, cb, fetch)
  local env = vim.fn.environ()
  env.GIT_DIR, env.GIT_WORK_TREE, env.GIT_INDEX_FILE, env.GIT_TERMINAL_PROMPT = nil, nil, nil, "0"
  env.GIT_NO_LAZY_FETCH = not fetch and "1" or nil
  local o = { cwd = root, env = env, clear_env = true, text = true }
  return vim.system(argv, o, cb and vim.schedule_wrap(cb))
end

---BufReadCmd: synchronous fill (an async fill would land qf/loclist jumps on an empty buffer), under lockmarks
---so the fill doesn't shift quickfix/loclist marks.
function M.read(buf)
  local side, root, rev, path = api.nvim_buf_get_name(buf):match("^pjollrig://(%a+)(/.-)//(%x+):(.+)$")
  local r = rev ~= M.EMPTY and M.git(root, { "git", "show", rev .. ":" .. path }):wait() or { code = 0, stdout = "" }
  local lines = r.code ~= 0 and { "[pjollrig] " .. vim.trim(r.stderr) }
    or r.stdout:find("\0", 1, true) and { "[pjollrig] binary file" }
    or vim.split(r.stdout:gsub("\n$", ""), "\n")
  -- buftype before filetype: no LSP attach; modifiable: a re-read (:e, re-pairing) refills a nomodifiable buffer
  vim.bo[buf].buftype, vim.bo[buf].swapfile, vim.bo[buf].modifiable = "nofile", false, true
  M._fill = function()
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.cmd("lockmarks lua require('pjollrig.review')._fill()")
  vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  vim.b[buf].pjollrig = { root = root, path = path, side = side, rev = rev }
  vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
end

-- BufWinEnter: the current qf entry carries its old side in user_data; when the entry's buffer lands in a
-- window, load both sides into a fixed window pair (L, R). No session map, no re-entrancy flag.
local L, R
local function valid(w)
  return w and api.nvim_win_is_valid(w)
end
function M.on_enter(buf)
  local q = vim.fn.getqflist({ idx = 0, items = 1, context = 1 })
  if q.context ~= "pjollrig" then
    return
  end
  local name, e = api.nvim_buf_get_name(buf), q.items[q.idx]
  for i, it in ipairs(e and e.bufnr ~= buf and q.items or {}) do -- RV-m1: another entry's side entered via :ll etc.
    local old = it.user_data.left == name
    if (old or it.bufnr == buf) and api.nvim_get_current_win() ~= L then
      return vim.schedule(function() -- after the jump has set the cursor
        local src, pos = api.nvim_get_current_win(), api.nvim_win_get_cursor(0)
        vim.fn.setqflist({}, "a", { idx = i })
        if old then -- put the entry's file here (BufWinEnter pairs it), else pair the buffer already shown
          api.nvim_win_set_buf(src, it.bufnr)
        else
          M.on_enter(buf)
        end
        vim.schedule(function() -- after the pairing; the old pane gets the loclist too, so :lnext works there
          local w, ll = old and L or R, vim.fn.getloclist(src, { items = 1, title = 1 })
          ll.idx = vim.fn.getloclist(src, { idx = 0 }).idx -- (a nonzero idx would return that one item)
          if #ll.items > 0 then
            vim.fn.setloclist(L, {}, " ", ll)
          end
          api.nvim_set_current_win(w)
          pcall(api.nvim_win_set_cursor, w, pos)
        end)
      end)
    end
  end
  if not (e and e.bufnr == buf and e.user_data) then
    return
  end
  local win = api.nvim_get_current_win()
  if win == L and valid(R) then -- :cnext/:lnext typed in the old pane: keep the pair's sides
    win = R
    api.nvim_set_current_win(R)
    api.nvim_win_set_buf(R, buf)
  end
  vim.schedule(function()
    if not (valid(win) and api.nvim_win_get_buf(win) == buf) then
      return
    end
    R = win
    if not valid(L) or L == R or api.nvim_win_get_tabpage(L) ~= api.nvim_win_get_tabpage(R) then
      L = api.nvim_win_call(R, function()
        vim.cmd("leftabove vsplit")
        return api.nvim_get_current_win()
      end)
    end
    vim.cmd("diffoff!")
    api.nvim_win_call(L, function()
      if api.nvim_buf_get_name(0) ~= e.user_data.left then -- already shown: no re-read
        vim.cmd.edit(vim.fn.fnameescape(e.user_data.left))
      end
      vim.cmd("diffthis")
    end)
    api.nvim_win_call(R, function()
      vim.cmd("diffthis")
    end)
  end)
end

---name-status -z: "S\0path\0" or "R097\0old\0new\0" (3 fields; a pairwise parser desyncs), then "?\0" + untracked.
function M.parse(out)
  local t, i, files, seen = vim.split(out, "\0", { plain = true }), 1, {}, {}
  while t[i] and t[i] ~= "" do
    if t[i] == "?" then -- untracked tail; skip nested repos ("sub/")
      for j = i + 1, #t do
        if t[j] ~= "" and not t[j]:match("/$") and not seen[t[j]] then -- `git rm --cached f`: D only
          files[#files + 1] = { status = "?", path = t[j], old = t[j] }
        end
      end
      break
    end
    local st, a = t[i], t[i + 1]
    local b = st:match("^[RC]") and t[i + 2]
    files[#files + 1], seen[b or a] = { status = st:sub(1, 1), path = b or a, old = a }, true
    i = i + (b and 3 or 2)
  end
  return files
end

-- Bare = uncommitted vs HEAD (+untracked); <ref> = vs merge-base(HEAD, ref). One spawn, no network (Q8):
-- refresh + diff-index never reads base blobs (a blob:none clone would lazy-fetch them), no rename detection.
local SCRIPT = [[
if [ -z "$1" ]; then b=$(git rev-parse -q --verify HEAD || echo $2); else b=$(git merge-base HEAD "$1") || exit 1; fi
git update-index -q --refresh >/dev/null; printf '%s\0' "$b"
git diff-index --name-status -z --no-renames "$b" && printf '?\0' && git ls-files -z --others --exclude-standard]]

function M.root()
  local root = require("pjollrig").git_root(vim.uv.fs_realpath(vim.fn.getcwd()))
  if not root then
    vim.notify("pjollrig: not in a git repo", vim.log.levels.ERROR)
  end
  return root
end

function M.start(ref)
  local root = M.root()
  if not root then
    return
  end
  M.git(root, { "sh", "-c", SCRIPT, "sh", ref or "", M.EMPTY }, function(r)
    if r.code ~= 0 then
      return vim.notify("pjollrig: " .. r.stderr, vim.log.levels.ERROR)
    end
    local base, rest = r.stdout:match("^(%x+)%z(.*)$")
    M.open({ root = root, base = base, title = ref or "HEAD" }, M.parse(rest))
  end)
end

---@param s {root:string, base:string, head?:string, title:string}  head=nil: the new side is the worktree
function M.open(s, files)
  local name, items = require("pjollrig").name, {}
  for _, f in ipairs(files) do -- always two panes; a missing side is an empty placeholder
    local old = name("old", s.root, (f.status == "A" or f.status == "?") and M.EMPTY or s.base, f.old)
    local new = s.head and name("new", s.root, s.head, f.path) or (s.root .. "/" .. f.path)
    new = f.status == "D" and name("new", s.root, M.EMPTY, f.path) or new
    local text = f.status .. (f.old ~= f.path and (" " .. f.old .. " →") or "")
    items[#items + 1] = { filename = new, module = f.path, lnum = 1, user_data = { left = old }, text = text }
  end
  if #items == 0 then
    return vim.notify("pjollrig: no changes vs " .. s.title)
  end
  local title = ("pjollrig review %s@%s"):format(s.title, s.base:sub(1, 7))
  vim.fn.setqflist({}, " ", { title = title, items = items, context = "pjollrig" })
  L, R = nil, nil
  vim.cmd("tabnew | botright copen 6 | wincmd p | cfirst")
end

return M
