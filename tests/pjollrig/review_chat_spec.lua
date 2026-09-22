-- Chat review resolver: `:PjollrigReview chat` reviews an assistant turn
-- from a Claude Code session transcript as a markdown document. Fixture
-- transcripts are written into a temp projects dir behind the module's
-- `_set_projects_dir` seam, so nothing here reads ~/.claude. Event lines
-- mirror the real format (see review/chat.lua's header): the `type` key
-- is NOT first on assistant/user lines, sidechain and bookkeeping events
-- are interleaved, and one line is deliberately broken JSON.

local H = require("helpers")

local ctx
local projects
local saved_cwd, saved_select

local CWD_A = "/tmp/proj-a"
local CWD_B = "/tmp/proj-b"
local ID_A1 = "aaaa1111-0000-4000-8000-000000000001"
local ID_A2 = "aaaa2222-0000-4000-8000-000000000002"
local ID_B1 = "bbbb1111-0000-4000-8000-000000000001"

local function slug(cwd)
  return (cwd:gsub("[^A-Za-z0-9]", "-"))
end

local function chat()
  return require("pjollrig.review.chat")
end

local function cache_dir()
  return vim.fn.stdpath("cache") .. "/manicule/chat"
end

---One transcript event with the real top-level envelope; `parentUuid`
---leads so `"type"` is not a line prefix.
local function envelope(cwd, ts, extra)
  return vim.tbl_extend("force", {
    parentUuid = vim.NIL,
    isSidechain = false,
    cwd = cwd,
    sessionId = "fixture",
    version = "2.1.0",
    gitBranch = "ms/feature",
    timestamp = ts,
    uuid = ("u-%s"):format(ts),
  }, extra or {})
end

local function user(cwd, ts, content, extra)
  return vim.tbl_extend("force", envelope(cwd, ts, extra), {
    type = "user",
    message = { role = "user", content = content },
  })
end

local function assistant(cwd, ts, blocks, extra)
  return vim.tbl_extend("force", envelope(cwd, ts, extra), {
    type = "assistant",
    message = { role = "assistant", type = "message", model = "claude", content = blocks },
  })
end

local function text(s)
  return { type = "text", text = s }
end

local function tool_use(name)
  return { type = "tool_use", id = "toolu_1", name = name, input = { command = "ls -la" } }
end

local function tool_result(body)
  return { type = "tool_result", tool_use_id = "toolu_1", content = body or "ok" }
end

local function ai_title(title)
  return { type = "ai-title", aiTitle = title, sessionId = "fixture" }
end

local function write_session(cwd, id, events, mtime)
  local dir = projects .. "/" .. slug(cwd)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. id .. ".jsonl"
  local lines = {}
  for i, event in ipairs(events) do
    lines[i] = type(event) == "string" and event or vim.json.encode(event)
  end
  vim.fn.writefile(lines, path)
  if mtime then
    assert(vim.uv.fs_utime(path, mtime, mtime))
  end
  return path
end

local BLOCK_A =
  "Root cause found and reproduced.\n\n- cmux set-buffer drops writes under load\n- the paste then fails with Buffer not found"
local BLOCK_B = "Retrying the paste once fixes it; adding a regression test next."
local LONG_2 =
  "Fixed it.\n\nAdded `paste_retries` (default 2) to the cmux sink, with tests covering the dropped-buffer path and the retry budget.\n\nAll green, stylua clean."
local LONG_A1 =
  "Plan for the chat resolver:\n\n1. list sessions from ~/.claude/projects, newest first\n2. extract the assistant turns\n3. materialize markdown and open a review pair"
local LONG_B1 =
  "Other project summary.\n\n- first point about the other project\n- second point about the other project\n- third point, long enough to be kept"

---Newest session for CWD_A: ai-title (last one wins), a real prompt with
---an image block, narration + tool_use fragments, a two-event turn whose
---text blocks join with a blank line (thinking/tool_use skipped), a
---sidechain event, a short "Done." turn, bookkeeping noise, one broken
---line. Kept turns newest-first: LONG_2 (1), BLOCK_A + BLOCK_B (2).
local function events_a2(cwd)
  return {
    ai_title("Draft title"),
    { type = "last-prompt", leafUuid = "x", sessionId = "fixture" },
    { type = "permission-mode", permissionMode = "bypassPermissions", sessionId = "fixture" },
    user(cwd, "2026-09-02T10:00:00.000Z", {
      text("I got this error, why ? [Image #1]"),
      { type = "image", source = { type = "base64", media_type = "image/png", data = "iVBORw0KGgo=" } },
    }),
    assistant(cwd, "2026-09-02T10:00:05.000Z", { text("Using systematic debugging to investigate this error.") }),
    assistant(cwd, "2026-09-02T10:00:06.000Z", { tool_use("Bash") }),
    user(cwd, "2026-09-02T10:00:07.000Z", { tool_result('output mentioning "type":"assistant" literally') }),
    assistant(cwd, "2026-09-02T10:01:00.000Z", { { type = "thinking", thinking = "private" }, text(BLOCK_A) }),
    assistant(cwd, "2026-09-02T10:01:05.000Z", { text(BLOCK_B), tool_use("Edit") }),
    user(cwd, "2026-09-02T10:05:00.000Z", "sure fix pjollrig"),
    assistant(cwd, "2026-09-02T10:05:30.000Z", {
      text(
        "Subagent report that must never surface.\n\nline two of the sidechain\nline three of the sidechain\nline four"
      ),
    }, { isSidechain = true }),
    assistant(cwd, "2026-09-02T10:06:00.000Z", { text("Done.") }),
    user(cwd, "2026-09-02T10:07:00.000Z", "thanks"),
    assistant(cwd, "2026-09-02T10:08:00.000Z", { text(LONG_2) }),
    ai_title("Error diagnosis"),
    '{"type":"assistant", "broken": tru',
    { type = "attachment", attachment = { type = "output_style" }, sessionId = "fixture" },
    { type = "file-history-snapshot", messageId = "m", snapshot = { trackedFileBackups = {} } },
  }
end

---Older session for CWD_A: no ai-title, so the title falls back to the
---first prompt's first line; a different branch; one kept turn.
local function events_a1(cwd)
  return {
    user(cwd, "2026-09-01T09:00:00.000Z", "Plan the chat resolver\n\nDetails follow.", { gitBranch = "ms/plan" }),
    assistant(cwd, "2026-09-01T09:01:00.000Z", { text(LONG_A1) }, { gitBranch = "ms/plan" }),
  }
end

---Session under another slug: neither ai-title nor a text prompt (the only
---user event is a tool_result), so the title falls back to the id.
local function events_b1(cwd)
  return {
    user(cwd, "2026-09-01T12:00:00.000Z", { tool_result() }, { gitBranch = "main" }),
    assistant(cwd, "2026-09-01T12:00:10.000Z", { text(LONG_B1) }, { gitBranch = "main" }),
  }
end

---The standard three-session fixture. `now` anchors the mtimes so the
---newest-first order is A2, B1, A1.
local function fixture(cwd_a, cwd_b)
  cwd_a = cwd_a or CWD_A
  cwd_b = cwd_b or CWD_B
  local now = os.time()
  return {
    a1 = write_session(cwd_a, ID_A1, events_a1(cwd_a), now - 3600),
    a2 = write_session(cwd_a, ID_A2, events_a2(cwd_a), now),
    b1 = write_session(cwd_b, ID_B1, events_b1(cwd_b), now - 1800),
  }
end

---Stub the floating picker: `choose(items, opts)` returns the item to pick (nil
---cancels); every call is recorded with its prompt and formatted rows.
local function stub_select(choose)
  local calls = {}
  require("pjollrig.ui.select").select = function(items, opts, on_choice)
    local rows = {}
    for i, item in ipairs(items) do
      rows[i] = opts.format_item and opts.format_item(item) or tostring(item)
    end
    table.insert(calls, { prompt = opts.prompt, items = items, rows = rows })
    on_choice(choose(items, opts, #calls))
  end
  return calls
end

local function resolve_sync(fargs, opts)
  return require("pjollrig.review.sources").resolve(fargs, opts)
end

describe("pjollrig review chat", function()
  before_each(function()
    ctx = H.setup()
    projects = ctx.artifact_root .. "/projects"
    vim.fn.mkdir(projects, "p")
    chat()._set_projects_dir(projects)
    saved_cwd = vim.uv.cwd()
    saved_select = require("pjollrig.ui.select").select
    require("pjollrig.review.complete")._reset()
  end)
  after_each(function()
    pcall(function()
      require("pjollrig.review").stop()
    end)
    require("pjollrig.ui.select").select = saved_select
    vim.cmd.cd(saved_cwd)
    chat()._set_projects_dir(nil)
    require("pjollrig.review.complete")._reset()
    H.rimraf(cache_dir())
    H.teardown(ctx)
    ctx = nil
  end)

  describe("sessions", function()
    it("lists the cwd's sessions newest first with title, branch, and size", function()
      local files = fixture()
      local sessions = assert(chat().list_sessions({ cwd = CWD_A }))
      assert.are.equal(2, #sessions)

      assert.are.equal(ID_A2, sessions[1].id)
      assert.are.equal(files.a2, sessions[1].path)
      assert.are.equal("Error diagnosis", sessions[1].title, "last ai-title must win")
      assert.are.equal("ms/feature", sessions[1].branch)
      assert.is_true(sessions[1].size > 0)
      assert.is_true(sessions[1].mtime > sessions[2].mtime)

      assert.are.equal(ID_A1, sessions[2].id)
      assert.are.equal("Plan the chat resolver", sessions[2].title, "title falls back to the first prompt's first line")
      assert.are.equal("ms/plan", sessions[2].branch)
    end)

    it("`all` spans every project slug, still newest first", function()
      fixture()
      local sessions = assert(chat().list_sessions({ cwd = CWD_A, all = true }))
      assert.are.same({ ID_A2, ID_B1, ID_A1 }, { sessions[1].id, sessions[2].id, sessions[3].id })
      assert.are.equal(ID_B1, sessions[2].title, "title falls back to the id without ai-title or a text prompt")
      assert.are.equal("main", sessions[2].branch)
    end)

    it("returns an empty list for a cwd without transcripts", function()
      fixture()
      assert.are.same({}, chat().list_sessions({ cwd = "/tmp/never-used" }))
    end)

    it("errors clearly when the projects dir is missing", function()
      local missing = projects .. "/does-not-exist"
      chat()._set_projects_dir(missing)
      local sessions, err = chat().list_sessions({ cwd = CWD_A })
      assert.is_nil(sessions)
      assert.is_truthy(err:find(missing, 1, true), err)
    end)
  end)

  describe("turns", function()
    it("extracts joined text turns newest first, skipping tool blocks, sidechains, and short turns", function()
      fixture()
      local sessions = assert(chat().list_sessions({ cwd = CWD_A }))
      local turns = assert(chat().list_turns(sessions[1]))
      assert.are.equal(2, #turns)

      -- Newest first: the final answer is turn 1.
      assert.are.equal(LONG_2, turns[1].text)
      assert.are.equal("2026-09-02T10:08:00.000Z", turns[1].timestamp)
      assert.are.equal("Fixed it.", turns[1].first_line)
      assert.are.equal(5, turns[1].line_count)

      -- Two consecutive assistant events join with a blank line; the
      -- thinking and tool_use blocks around them leave no trace.
      assert.are.equal(BLOCK_A .. "\n\n" .. BLOCK_B, turns[2].text)
      assert.are.equal("2026-09-02T10:01:00.000Z", turns[2].timestamp, "turn timestamp is its first event's")
      assert.are.equal("Root cause found and reproduced.", turns[2].first_line)
      assert.are.equal(6, turns[2].line_count)

      for _, turn in ipairs(turns) do
        assert.is_nil(turn.text:find("Subagent report", 1, true), "sidechain text leaked into a turn")
        assert.is_nil(turn.text:find("ls -la", 1, true), "tool_use input leaked into a turn")
        assert.is_nil(turn.text:find("private", 1, true), "thinking block leaked into a turn")
        assert.is_nil(turn.text:find("Done.", 1, true), "short turn was kept")
      end
    end)

    it("numbers over kept turns so the dropped short turn leaves no gap", function()
      fixture()
      local sessions = assert(chat().list_sessions({ cwd = CWD_A }))
      local turns = assert(chat().list_turns(sessions[1]))
      assert.are.same({ 1, 2 }, { turns[1].index, turns[2].index })
    end)

    it("materializes the turn text alone as a markdown document under the cache dir", function()
      fixture()
      local sessions = assert(chat().list_sessions({ cwd = CWD_A }))
      local turns = assert(chat().list_turns(sessions[1]))
      local path = chat().materialize(sessions[1], turns[2])

      assert.are.equal(cache_dir() .. "/" .. ID_A2:sub(1, 8) .. "-turn-2.md", path)
      -- No header: markdown conceals HTML comments, which rendered as
      -- blank lines above the turn and shifted every commented line.
      assert.are.same(vim.split(BLOCK_A .. "\n\n" .. BLOCK_B, "\n", { plain = true }), vim.fn.readfile(path))
    end)

    it("counts non-blank lines toward MIN_LINES: a URL plus one sentence is not a report", function()
      -- Two text blocks join with a blank line: three lines, two of them
      -- text, well over MIN_CHARS. The join line must not make it kept.
      local url = "https://github.com/MattiasMTS/pjollrig.nvim/pull/3/files#diff-0123456789abcdef0123456789abcdef"
      local sentence = "The review is open on the PR with both comments attached; nothing else changed."
      assert.is_true(#url + 2 + #sentence >= chat().MIN_CHARS)
      local path = write_session(CWD_A, ID_A1, {
        user(CWD_A, "2026-09-01T09:00:00.000Z", "post the review"),
        assistant(CWD_A, "2026-09-01T09:00:01.000Z", { text(url), text(sentence) }),
        user(CWD_A, "2026-09-01T09:01:00.000Z", "and the plan?"),
        assistant(CWD_A, "2026-09-01T09:01:01.000Z", { text(LONG_A1) }),
      })
      local turns = assert(chat().list_turns({ path = path, id = ID_A1, title = "x" }))
      assert.are.equal(1, #turns)
      assert.are.equal(LONG_A1, turns[1].text)
      assert.are.equal(5, turns[1].line_count, "line_count stays the total: it is the picker's `(n lines)`")
    end)

    it("rejects a transcript whose assistant events have an unexpected shape", function()
      local path = write_session(CWD_A, ID_A1, {
        user(CWD_A, "2026-09-01T09:00:00.000Z", "hello"),
        -- `message` is a string instead of {content = [...]}.
        vim.tbl_extend("force", envelope(CWD_A, "2026-09-01T09:00:01.000Z"), {
          type = "assistant",
          message = "a long enough answer\nspanning several lines\nof plain text without any block structure at all",
        }),
      })
      local turns, err = chat().list_turns({ path = path, id = ID_A1, title = "x" })
      assert.is_nil(turns)
      assert.is_truthy(err:find("transcript format not recognized", 1, true), err)
    end)

    it("yields no turns for a session without assistant events", function()
      local path = write_session(CWD_A, ID_A1, { user(CWD_A, "2026-09-01T09:00:00.000Z", "hello") })
      assert.are.same({}, chat().list_turns({ path = path, id = ID_A1, title = "x" }))
    end)
  end)

  describe("resolver", function()
    it("`chat <n>` resolves the newest session's nth kept turn", function()
      fixture()
      local job = assert(resolve_sync({ "chat", "2" }, { cwd = CWD_A }))
      assert.are.equal("chat: Error diagnosis", job.label)
      assert.are.equal(1, #job.files)
      local pair = job.files[1]
      -- A document pair: no baseline side, nothing staged, no diff.
      assert.are.equal("doc", pair.status)
      assert.is_nil(pair.left)
      assert.are.equal(cache_dir() .. "/" .. ID_A2:sub(1, 8) .. "-turn-2.md", pair.right)
      assert.are.equal(ID_A2:sub(1, 8) .. "-turn-2.md", pair.path)
      assert.is_truthy(vim.fn.readfile(pair.right)[1]:find("Root cause found", 1, true))
      assert.is_nil(job.stage_dirs, "a chat job owns no stage dirs")
    end)

    it("resolve_async never fires in the caller's frame", function()
      fixture()
      local fired = false
      local job, err
      require("pjollrig.review.sources").resolve_async({ "chat", "1" }, { cwd = CWD_A }, function(j, e)
        job, err, fired = j, e, true
      end)
      assert.is_false(fired, "chat resolve_async completed synchronously")
      vim.wait(5000, function()
        return fired
      end, 5)
      assert.is_nil(err)
      assert.are.equal("chat: Error diagnosis", job.label)
      assert.is_truthy(vim.endswith(job.files[1].right, "-turn-1.md"))
    end)

    it("`chat <n>` past the kept turns fails with a clear error", function()
      fixture()
      local job, err = resolve_sync({ "chat", "9" }, { cwd = CWD_A })
      assert.is_nil(job)
      assert.is_truthy(err:find("no turn 9", 1, true), err)
      assert.is_truthy(err:find("Error diagnosis", 1, true), err)
    end)

    it("rejects a non-numeric turn argument", function()
      fixture()
      local job, err = resolve_sync({ "chat", "latest" }, { cwd = CWD_A })
      assert.is_nil(job)
      assert.is_truthy(err:find("chat [all|<turn>]", 1, true), err)
    end)

    it("bare `chat` drives the session picker then the turn picker", function()
      fixture()
      local calls = stub_select(function(items, _, nth)
        return nth == 1 and items[2] or items[1]
      end)
      local job = assert(resolve_sync({ "chat" }, { cwd = CWD_A }))
      assert.are.equal(2, #calls)

      -- Session rows: `Title · <age> · <branch> · <size>`.
      assert.are.equal(2, #calls[1].items)
      assert.is_truthy(
        calls[1].rows[1]:match("^Error diagnosis · just now · ms/feature · [%d.]+ %a*B$"),
        calls[1].rows[1]
      )
      assert.is_truthy(
        calls[1].rows[2]:match("^Plan the chat resolver · 1h ago · ms/plan · [%d.]+ %a*B$"),
        calls[1].rows[2]
      )

      -- Turn rows: `HH:MM  <first line>  (<n> lines)`.
      assert.are.equal(1, #calls[2].items)
      assert.is_truthy(
        calls[2].rows[1]:match("^%d%d:%d%d  Plan for the chat resolver:  %(5 lines%)$"),
        calls[2].rows[1]
      )

      assert.are.equal("chat: Plan the chat resolver", job.label)
      assert.are.equal(cache_dir() .. "/" .. ID_A1:sub(1, 8) .. "-turn-1.md", job.files[1].right)
    end)

    it("a single session for the cwd skips the session picker", function()
      fixture()
      local calls = stub_select(function(items)
        return items[1]
      end)
      local job = assert(resolve_sync({ "chat" }, { cwd = CWD_B }))
      assert.are.equal(1, #calls)
      assert.is_truthy(calls[1].prompt:lower():find("turn", 1, true), calls[1].prompt)
      assert.are.equal("chat: " .. ID_B1, job.label)
    end)

    it("`chat all` offers sessions across every project", function()
      fixture()
      local calls = stub_select(function(items)
        return items[1]
      end)
      local job = assert(resolve_sync({ "chat", "all" }, { cwd = CWD_B }))
      assert.are.equal(3, #calls[1].items)
      assert.are.equal("chat: Error diagnosis", job.label)
    end)

    it("cancelling a picker fails the resolve", function()
      fixture()
      stub_select(function()
        return nil
      end)
      local job, err = resolve_sync({ "chat" }, { cwd = CWD_A })
      assert.is_nil(job)
      assert.is_truthy(err:find("cancelled", 1, true), err)
    end)

    it("fails with the path when the projects dir is missing", function()
      local missing = projects .. "/nope"
      chat()._set_projects_dir(missing)
      local job, err = resolve_sync({ "chat", "1" }, { cwd = CWD_A })
      assert.is_nil(job)
      assert.is_truthy(err:find(missing, 1, true), err)
    end)

    it("fails when the cwd has no sessions", function()
      fixture()
      local job, err = resolve_sync({ "chat" }, { cwd = "/tmp/never-used" })
      assert.is_nil(job)
      assert.is_truthy(err:find("no Claude Code sessions", 1, true), err)
    end)

    it(":PjollrigReview chat opens a review over the picked turn", function()
      vim.cmd("runtime plugin/pjollrig.lua")
      local dir = ctx.artifact_root .. "/proj"
      vim.fn.mkdir(dir, "p")
      vim.cmd.cd(dir)
      local cwd = vim.uv.cwd()
      fixture(cwd, CWD_B)
      stub_select(function(items, _, nth)
        return nth == 1 and items[1] or items[2]
      end)

      local R = require("pjollrig.review")
      vim.cmd("PjollrigReview chat")
      -- Shell first: the command returned with the session resolving and
      -- the pickers still to run in the scheduled step.
      local state = assert(R.state(), "no session after :PjollrigReview chat")
      assert.is_true(state.resolving)

      vim.wait(5000, function()
        local s = R.state()
        return s ~= nil and not s.resolving
      end, 10)
      state = assert(R.state())
      assert.is_nil(state.resolving)
      assert.are.equal("chat: Error diagnosis", state.label)
      assert.are.equal(1, #state.files)
      local right = cache_dir() .. "/" .. ID_A2:sub(1, 8) .. "-turn-2.md"
      assert.are.equal("doc", state.files[1].status)
      assert.is_nil(state.files[1].left)
      assert.are.equal(right, state.files[1].right)
      assert.are.equal(right, vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
      assert.are.equal("markdown", vim.bo.filetype)
      -- Opened as a document, not an all-added diff: no diff window,
      -- prose wrapping on, first line of the turn on the first row.
      assert.is_false(vim.wo.diff)
      assert.is_true(vim.wo.wrap)
      assert.is_true(vim.wo.linebreak)
      assert.are.equal("Root cause found and reproduced.", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)

    it(":PjollrigReview chat <n> needs no picker", function()
      vim.cmd("runtime plugin/pjollrig.lua")
      local dir = ctx.artifact_root .. "/proj"
      vim.fn.mkdir(dir, "p")
      vim.cmd.cd(dir)
      fixture(vim.uv.cwd(), CWD_B)
      require("pjollrig.ui.select").select = function()
        error("no picker expected for `chat 1`")
      end

      local R = require("pjollrig.review")
      vim.cmd("PjollrigReview chat 1")
      vim.wait(5000, function()
        local s = R.state()
        return s ~= nil and not s.resolving
      end, 10)
      local state = assert(R.state())
      assert.are.equal("chat: Error diagnosis", state.label)
      assert.is_truthy(vim.endswith(state.files[1].right, "-turn-1.md"))
    end)
  end)

  describe("completion", function()
    it("first argument offers chat", function()
      local items = require("pjollrig.review.complete").candidates("", "PjollrigReview ")
      assert.is_true(vim.tbl_contains(items, "chat"))
      assert.are.same({ "chat" }, require("pjollrig.review.complete").candidates("ch", "PjollrigReview ch"))
    end)

    it("`chat` position completes all plus the newest session's kept turn numbers", function()
      local dir = ctx.artifact_root .. "/proj"
      vim.fn.mkdir(dir, "p")
      vim.cmd.cd(dir)
      fixture(vim.uv.cwd(), CWD_B)
      local C = require("pjollrig.review.complete")
      assert.are.same({ "all", "1", "2" }, C.candidates("", "PjollrigReview chat "))
      assert.are.same({ "all" }, C.candidates("a", "PjollrigReview chat a"))
    end)

    it("`chat` position degrades to all when there are no transcripts", function()
      chat()._set_projects_dir(projects .. "/nope")
      assert.are.same({ "all" }, require("pjollrig.review.complete").candidates("", "PjollrigReview chat "))
    end)
  end)
end)
