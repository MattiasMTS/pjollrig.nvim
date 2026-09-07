local H = require("helpers")

local ctx

---Fake gh on PATH: logs every argv line to `<dir>/gh/argv.log`, copies any
---`--input` file to `<dir>/gh/api-input.json`, and answers `pr view`,
---`repo view`, and `api` with canned JSON. Drop a `<dir>/gh/no-pr` marker
---to make `pr view` fail like gh does outside a PR branch.
local function fake_gh(dir)
  local home = dir .. "/gh"
  local bin = home .. "/bin"
  vim.fn.mkdir(bin, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'echo "$*" >> "$dir/argv.log"',
    'if [ "$1 $2" = "pr view" ]; then',
    '  if [ -f "$dir/no-pr" ]; then',
    '    echo "no pull requests found for branch" >&2; exit 1;',
    "  fi;",
    "  echo '{\"number\":42}';",
    'elif [ "$1 $2" = "repo view" ]; then',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1" = "api" ]; then',
    '  case "$2" in',
    "  */replies)",
    '    if [ -f "$dir/fail-reply" ]; then rm "$dir/fail-reply"; echo "reply boom" >&2; exit 1; fi;;',
    "  esac;",
    '  while [ "$#" -gt 0 ]; do',
    '    if [ "$1" = "--input" ]; then shift; cp "$1" "$dir/api-input.json"; fi;',
    "    shift;",
    "  done;",
    "  echo '{}';",
    "else",
    "  exit 2;",
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return {
    bin = bin,
    home = home,
    argv = function()
      local ok, lines = pcall(vim.fn.readfile, home .. "/argv.log")
      return ok and lines or {}
    end,
    api_input = function()
      return vim.json.decode(table.concat(vim.fn.readfile(home .. "/api-input.json"), "\n"))
    end,
    set_no_pr = function()
      vim.fn.writefile({ "" }, home .. "/no-pr")
    end,
    set_fail_reply = function()
      vim.fn.writefile({ "" }, home .. "/fail-reply")
    end,
    count = function(needle)
      local n = 0
      local ok, lines = pcall(vim.fn.readfile, home .. "/argv.log")
      for _, line in ipairs(ok and lines or {}) do
        if line:find(needle, 1, true) then
          n = n + 1
        end
      end
      return n
    end,
  }
end

local function record(opts)
  opts = opts or {}
  return {
    body = opts.body or "needs a guard",
    project_root = opts.project_root or ctx.root,
    uri = opts.uri or ("file://" .. ctx.root .. "/src/a.lua"),
    range = opts.range or { start = { 4, 0 }, end_ = { 4, 0 } },
  }
end

local function send(spec, comments, send_ctx)
  local got_ok, got_err
  spec.send(comments, send_ctx or {}, function(ok, err)
    got_ok, got_err = ok, err
  end)
  vim.wait(2000, function()
    return got_ok ~= nil
  end)
  return got_ok, got_err
end

describe("pjollrig github sink", function()
  local saved_path

  before_each(function()
    ctx = H.setup()
    saved_path = vim.env.PATH
  end)
  after_each(function()
    vim.env.PATH = saved_path
    H.teardown(ctx)
    ctx = nil
  end)

  it("posts a PR review with correct JSON via gh api", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, { record({ body = "needs a guard" }) })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(argv:find("api repos/acme/widgets/pulls/42/reviews --method POST --input", 1, true))
    local body = gh.api_input()
    assert.are.equal("COMMENT", body.event)
    assert.are.equal(1, #body.comments)
    assert.are.equal("src/a.lua", body.comments[1].path)
    assert.are.equal(5, body.comments[1].line)
    assert.are.equal("RIGHT", body.comments[1].side)
    assert.are.equal("needs a guard", body.comments[1].body)
    assert.is_nil(body.comments[1].start_line)
  end)

  it("uses start_line + line for multi-line ranges", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, { record({ range = { start = { 4, 0 }, end_ = { 6, 0 } } }) })

    assert.is_true(ok, err)
    local comment = gh.api_input().comments[1]
    assert.are.equal(5, comment.start_line)
    assert.are.equal(7, comment.line)
    assert.are.equal("RIGHT", comment.side)
  end)

  it("honours opts.event and opts.pre_text", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({ event = "REQUEST_CHANGES", pre_text = "Please fix" })

    local ok, err = send(spec, { record() })

    assert.is_true(ok, err)
    local body = gh.api_input()
    assert.are.equal("REQUEST_CHANGES", body.event)
    assert.is_truthy(body.body:find("Please fix", 1, true))
  end)

  it("ctx.event overrides opts.event", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({ event = "COMMENT" })

    local ok, err = send(spec, { record() }, { event = "APPROVE" })

    assert.is_true(ok, err)
    assert.are.equal("APPROVE", gh.api_input().event)
  end)

  it("rejects an invalid ctx.event", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, { record() }, { event = "SHIP_IT" })

    assert.is_false(ok)
    assert.is_truthy(err:find("event", 1, true))
  end)

  it("rejects an invalid event at setup", function()
    local ok, err = pcall(function()
      require("pjollrig.sinks.github").setup({ event = "SHIP_IT" })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("event", 1, true))
  end)

  it("ctx.pr overrides gh pr view", function()
    local gh = fake_gh(ctx.artifact_root)
    -- Make `gh pr view` fail loudly: with ctx.pr set (as the pr review
    -- source sets it on the session ctx), the send must never consult
    -- the current branch's PR.
    gh.set_no_pr()
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, { record() }, { pr = 7 })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_nil(argv:find("pr view", 1, true))
    assert.is_truthy(argv:find("pulls/7/reviews", 1, true))
  end)

  it("fails with an actionable error when no PR exists for the branch", function()
    local gh = fake_gh(ctx.artifact_root)
    gh.set_no_pr()
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, { record() })

    assert.is_false(ok)
    assert.is_truthy(err:find("no open PR for this branch", 1, true))
    assert.is_truthy(err:find("ctx.pr", 1, true))
  end)

  it("skips unresolvable records and counts them in the review body", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, {
      record(),
      record({ body = "scratch note", uri = "term://scratch", project_root = nil }),
    })

    assert.is_true(ok, err)
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("src/a.lua", body.comments[1].path)
    assert.is_truthy(body.body:find("1 skipped", 1, true))
  end)

  it("skips imported GitHub comments and counts them in the summary", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local imported = record({ body = "from github" })
    imported.meta = { github = { id = 9, url = "https://example.test/r/9", imported = true } }
    local ok, err = send(spec, { record(), imported })

    assert.is_true(ok, err)
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("needs a guard", body.comments[1].body)
    assert.is_truthy(body.body:find("1 skipped: imported from GitHub", 1, true))
  end)

  it("posts meta.github_reply records via the replies endpoint", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local reply = record({ body = "sounds good" })
    reply.meta = { github_reply = { to = 9001, pr = 7 } }
    local ok, err = send(spec, { record(), reply })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(
      argv:find("api repos/acme/widgets/pulls/7/comments/9001/replies --method POST -f body=sounds good", 1, true)
    )
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("needs a guard", body.comments[1].body)
    assert.is_truthy(body.body:find("1 thread reply", 1, true))
  end)

  it("sends a reply-only batch without posting a review", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local reply = record({ body = "will do" })
    reply.meta = { github_reply = { to = 9001 } }
    local ok, err = send(spec, { reply })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(
      argv:find("api repos/acme/widgets/pulls/42/comments/9001/replies --method POST -f body=will do", 1, true)
    )
    assert.is_nil(argv:find("/reviews", 1, true))
  end)

  it("marks records sent so a re-send posts nothing new", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})
    local store = require("pjollrig.store")
    local rec = record()
    rec.id = "sent-1"
    rec.scope = "project"
    store.put(ctx.root, rec)
    assert(store.save(ctx.root))

    local ok, err = send(spec, { rec })

    assert.is_true(ok, err)
    assert.are.equal("number", type(store.get(ctx.root, "sent-1").meta.github_sent))

    local notified
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.INFO then
        notified = msg
      end
    end
    local ok2, err2 = send(spec, { rec })
    vim.notify = original_notify

    assert.is_true(ok2, err2)
    assert.is_truthy(notified and notified:find("already sent", 1, true), "expected an 'already sent' report")
    assert.are.equal(1, gh.count("/reviews"))
  end)

  it("retries only the unsent remainder after a partial reply failure", function()
    local gh = fake_gh(ctx.artifact_root)
    gh.set_fail_reply()
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})
    local store = require("pjollrig.store")
    local rev = record({ body = "needs a guard" })
    rev.id = "rev-1"
    rev.scope = "project"
    local reply = record({ body = "sounds good" })
    reply.id = "rep-1"
    reply.scope = "project"
    reply.meta = { github_reply = { to = 9001, pr = 7 } }
    store.put(ctx.root, rev)
    store.put(ctx.root, reply)
    assert(store.save(ctx.root))

    local ok, err = send(spec, { rev, reply })

    assert.is_false(ok)
    assert.is_truthy(err:find("reply boom", 1, true), err)
    assert.is_truthy(err:find("marked sent", 1, true), err)
    assert.are.equal("number", type(store.get(ctx.root, "rev-1").meta.github_sent))
    assert.is_nil(store.get(ctx.root, "rep-1").meta.github_sent)

    local ok2, err2 = send(spec, { rev, reply })

    assert.is_true(ok2, err2)
    assert.are.equal(1, gh.count("/reviews"), "review must not repost on retry")
    assert.are.equal(2, gh.count("/replies"), "retry posts only the failed reply")
    assert.are.equal("number", type(store.get(ctx.root, "rep-1").meta.github_sent))
  end)

  it("clears only delivered and already-sent records on a consuming send", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    -- A project buffer must be current so M.list resolves the project
    -- root and sees the store-backed records below.
    H.edit_project_file(ctx, "src/a.lua", {
      "local one = 1",
      "local two = 2",
      "local three = 3",
      "local four = 4",
      "local five = 5",
      "return one",
    })
    require("pjollrig").register_sink(require("pjollrig.sinks.github").setup({ clear_on_success = true }))
    local store = require("pjollrig.store")

    local posted = record({ body = "post me" })
    posted.id, posted.scope = "posted-1", "project"
    local already = record({ body = "sent earlier" })
    already.id, already.scope = "already-1", "project"
    already.meta = { github_sent = 1234567890 }
    local imported = record({ body = "from github" })
    imported.id, imported.scope = "imported-1", "project"
    imported.meta = { github = { id = 9, url = "https://example.test/r/9", imported = true } }
    local scratch = record({ body = "scratch note", uri = "term://scratch" })
    scratch.id, scratch.scope = "scratch-1", "project"
    for _, rec in ipairs({ posted, already, imported, scratch }) do
      store.put(ctx.root, rec)
    end
    assert(store.save(ctx.root))

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = tostring(msg), level = level })
    end
    require("pjollrig").send("github")
    -- The send path is async (gh runs via vim.system callbacks): the
    -- auto-clear fires after the sink's cb, and the skipped notify fires
    -- just before it — wait for the clear before restoring vim.notify.
    vim.wait(2000, function()
      return store.get(ctx.root, "posted-1") == nil
    end)
    vim.notify = original_notify

    -- Only the new record with a repository-relative path was posted.
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("post me", body.comments[1].body)

    -- Delivered now + delivered by an earlier send: cleared. Records the
    -- sink diverted out of the payload must survive the auto-clear.
    assert.is_nil(store.get(ctx.root, "posted-1"))
    assert.is_nil(store.get(ctx.root, "already-1"))
    assert.is_truthy(store.get(ctx.root, "imported-1"), "imported record must survive clear_on_success")
    assert.is_truthy(store.get(ctx.root, "scratch-1"), "no-path record must survive clear_on_success")

    -- The user is told what was withheld from the review.
    local skipped_msg
    for _, note in ipairs(notifications) do
      if note.msg:find("skipped", 1, true) then
        skipped_msg = note.msg
      end
    end
    assert.is_truthy(skipped_msg, "expected a notify about skipped records")
    assert.is_truthy(skipped_msg:find("1 without a repository-relative path", 1, true), skipped_msg)
    assert.is_truthy(skipped_msg:find("1 imported from GitHub", 1, true), skipped_msg)
  end)

  it("fails when no record resolves to a repository path", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = send(spec, { record({ uri = "term://scratch", project_root = nil }) })

    assert.is_false(ok)
    assert.is_truthy(err:find("resolvable", 1, true))
  end)

  it("validate fails without a gh executable", function()
    local emptybin = ctx.artifact_root .. "/emptybin"
    vim.fn.mkdir(emptybin, "p")
    vim.env.PATH = emptybin
    local spec = require("pjollrig.sinks.github").setup({})

    local ok, err = spec.validate({})

    assert.is_false(ok)
    assert.is_truthy(err:find("gh", 1, true))
  end)

  it("validate fails outside a git repository", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local nongit = ctx.artifact_root .. "/nongit"
    vim.fn.mkdir(nongit, "p")
    local ok, err = spec.validate({ cwd = nongit })

    assert.is_false(ok)
    assert.is_truthy(err:find("git", 1, true))
  end)

  it("registers as a builtin integration when gh is available", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    require("pjollrig.sinks")._reset()
    require("pjollrig.sinks").setup({ clipboard = false, cmux = false, socket = false })

    assert.are.same({ "github" }, require("pjollrig.sinks").list())
    local spec = require("pjollrig.sinks").get("github")
    assert.are.equal("integration", spec.type)
    assert.is_false(spec.clear_on_success)
    assert.is_true(spec.accepts_verdict)
    assert.are.equal("github_sent", spec.sent_marker)
  end)

  it("stays unregistered when gh is missing", function()
    local emptybin = ctx.artifact_root .. "/emptybin"
    vim.fn.mkdir(emptybin, "p")
    vim.env.PATH = emptybin
    require("pjollrig.sinks")._reset()
    require("pjollrig.sinks").setup({ clipboard = false, cmux = false, socket = false })

    assert.are.same({}, require("pjollrig.sinks").list())
  end)

  it("reports health with gh path", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("pjollrig.sinks.github").setup({})

    local health = spec.health()

    assert.is_true(health.available)
    assert.is_truthy(tostring(health.gh):find("/gh", 1, true))
  end)

  describe(":PjollrigSend verdicts", function()
    it("maps a verdict argument to ctx.event", function()
      vim.cmd("runtime plugin/pjollrig.lua")
      local calls = H.register_fake_sink("github", { accepts_verdict = true })

      vim.cmd("PjollrigSend github approve")
      vim.wait(200, function()
        return #calls > 0
      end)

      assert.are.equal(1, #calls)
      assert.are.equal("APPROVE", calls[1].ctx.event)
    end)

    it("errors when the sink does not consume verdicts, without dispatching", function()
      vim.cmd("runtime plugin/pjollrig.lua")
      local calls = H.register_fake_sink("clipboard")

      local errored
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          errored = msg
        end
      end
      vim.cmd("PjollrigSend clipboard approve")
      vim.notify = original_notify

      assert.is_truthy(errored, "expected an ERROR notification")
      assert.is_truthy(errored:find("clipboard", 1, true))
      assert.is_truthy(errored:find("verdict", 1, true))
      assert.are.equal(0, #calls)
    end)

    it("errors on an unknown verdict without dispatching", function()
      vim.cmd("runtime plugin/pjollrig.lua")
      local calls = H.register_fake_sink("github")

      local errored
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          errored = msg
        end
      end
      vim.cmd("PjollrigSend github ship-it")
      vim.notify = original_notify

      assert.is_truthy(errored, "expected an ERROR notification")
      assert.is_truthy(errored:find("ship-it", 1, true))
      assert.are.equal(0, #calls)
    end)

    it("completes the verdict words after `github `", function()
      vim.cmd("runtime plugin/pjollrig.lua")

      local comps = vim.fn.getcompletion("PjollrigSend github ", "cmdline")
      table.sort(comps)

      assert.are.same({ "approve", "comment", "request-changes" }, comps)
    end)

    it("still completes sink names for the first argument", function()
      vim.cmd("runtime plugin/pjollrig.lua")
      H.register_fake_sink("github")

      local comps = vim.fn.getcompletion("PjollrigSend ", "cmdline")

      assert.are.same({ "github" }, comps)
    end)
  end)
end)
