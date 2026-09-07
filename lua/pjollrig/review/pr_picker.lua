-- pjollrig.nvim: open-PR picker for bare `:PjollrigReview pr`.
--
-- Lists open PRs via the gh CLI and offers them through `vim.ui.select`
-- so users don't need to know a PR number up front. The list is fetched
-- asynchronously — the command returns immediately and the picker opens
-- when gh answers. Cancelling the picker is a no-op.

local M = {}

---Fetch open PRs via `gh pr list`, asynchronously. `cb(prs)` runs on the
---main loop with nil when gh is missing, fails, or the repository has no
---open PRs — the caller treats all three the same.
---@param cb fun(prs: {number: integer, title: string, author: table}[]|nil)
local function open_prs(cb)
  if vim.fn.executable("gh") ~= 1 then
    cb(nil)
    return
  end
  local ok = pcall(vim.system, { "gh", "pr", "list", "--json", "number,title,author", "--limit", "50" }, {
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(nil)
        return
      end
      local decoded, prs = pcall(vim.json.decode, result.stdout or "")
      if not decoded or type(prs) ~= "table" or #prs == 0 then
        cb(nil)
        return
      end
      cb(prs)
    end)
  end)
  if not ok then
    cb(nil)
  end
end

---Pick an open PR and hand its number (as a string) to `on_choice`.
---Returns immediately; the picker opens once the PR list arrives.
---`on_choice` is not called when the user cancels.
---@param on_choice fun(number: string)
function M.pick(on_choice)
  vim.notify("pjollrig: fetching open PRs…", vim.log.levels.INFO)
  open_prs(function(prs)
    if not prs then
      vim.notify("pjollrig: no open PRs found (or gh unavailable)", vim.log.levels.ERROR)
      return
    end
    vim.ui.select(prs, {
      prompt = "Review PR",
      format_item = function(pr)
        local author = type(pr.author) == "table" and pr.author.login or "?"
        return ("#%s %s — %s"):format(pr.number, pr.title or "", author)
      end,
    }, function(choice)
      if not choice then
        return
      end
      on_choice(tostring(choice.number))
    end)
  end)
end

return M
