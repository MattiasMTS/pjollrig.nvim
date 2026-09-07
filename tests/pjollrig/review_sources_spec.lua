local H = require("helpers")

local ctx

local function fake_gh(dir, base_oid, head_oid, title)
  local bin = dir .. "/bin"
  vim.fn.mkdir(bin, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    'if [ "$1 $2" = "repo view" ]; then',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1" = "api" ]; then',
    "  echo '[]';",
    "else",
    ('  echo \'{"baseRefOid":"%s","headRefOid":"%s","title":"%s"}\';'):format(base_oid, head_oid, title or ""),
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return bin
end

---Fake gh on PATH answering `pr view`, `repo view`, and the PR review
---comments endpoint (`api .../comments --paginate`). Drop a
---`<home>/no-repo` marker to make `repo view` fail like gh does outside
---a GitHub remote.
local function fake_gh_pr(dir, opts)
  local home = dir .. "/gh-import"
  local bin = home .. "/bin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ opts.comments_json or "[]" }, home .. "/comments.json")
  local default_threads = vim.json.encode({
    data = { repository = { pullRequest = { reviewThreads = { nodes = {} } } } },
  })
  vim.fn.writefile({ opts.threads_json or default_threads }, home .. "/threads.json")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'if [ "$1 $2" = "pr view" ]; then',
    ('  echo \'{"baseRefOid":"%s","headRefOid":"%s"}\';'):format(opts.base_oid, opts.head_oid),
    'elif [ "$1 $2" = "repo view" ]; then',
    '  if [ -f "$dir/no-repo" ]; then echo "gh: no GitHub remote" >&2; exit 1; fi;',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1 $2" = "api graphql" ]; then',
    '  if [ -f "$dir/no-graphql" ]; then echo "gh: graphql boom" >&2; exit 1; fi;',
    '  case "$*" in',
    "  *cursor=CURSOR_PAGE_2*)",
    '    cat "$dir/threads2.json";;',
    "  *)",
    '    cat "$dir/threads.json";;',
    "  esac;",
    'elif [ "$1" = "api" ]; then',
    '  case "$*" in',
    "  *--slurp*)",
    '    if [ -f "$dir/no-slurp" ]; then echo "unknown flag: --slurp" >&2; exit 1; fi;',
    "    printf '['; cat \"$dir/comments.json\"; printf ']';;",
    "  *)",
    '    cat "$dir/comments.json";;',
    "  esac;",
    "else",
    "  exit 2;",
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return {
    bin = bin,
    home = home,
    set_no_repo = function()
      vim.fn.writefile({ "" }, home .. "/no-repo")
    end,
    set_no_slurp = function()
      vim.fn.writefile({ "" }, home .. "/no-slurp")
    end,
    set_no_graphql = function()
      vim.fn.writefile({ "" }, home .. "/no-graphql")
    end,
    set_threads = function(nodes)
      vim.fn.writefile({
        vim.json.encode({ data = { repository = { pullRequest = { reviewThreads = { nodes = nodes } } } } }),
      }, home .. "/threads.json")
    end,
    -- Two GraphQL pages: page 1 advertises hasNextPage with the cursor
    -- the fake script branches on, page 2 is final.
    set_thread_pages = function(page1_nodes, page2_nodes)
      vim.fn.writefile({
        vim.json.encode({
          data = {
            repository = {
              pullRequest = {
                reviewThreads = {
                  pageInfo = { hasNextPage = true, endCursor = "CURSOR_PAGE_2" },
                  nodes = page1_nodes,
                },
              },
            },
          },
        }),
      }, home .. "/threads.json")
      vim.fn.writefile({
        vim.json.encode({
          data = {
            repository = {
              pullRequest = {
                reviewThreads = {
                  pageInfo = { hasNextPage = false },
                  nodes = page2_nodes,
                },
              },
            },
          },
        }),
      }, home .. "/threads2.json")
    end,
  }
end

---A git repo with a checked-out PR branch plus a fake gh answering the
---comments endpoint with `comments` (default: one range comment and one
---outdated comment with line=null).
local function pr_repo_with_comments(comments, threads)
  local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1", "-- two", "-- three", "-- four", "-- five" } })
  local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
  git("checkout", "-q", "-b", "pr-branch")
  vim.fn.writefile({ "return 2", "-- two", "-- three", "-- four", "-- five" }, root .. "/a.lua")
  git("commit", "-aqm", "pr change")
  local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)
  local gh = fake_gh_pr(ctx.artifact_root, {
    base_oid = base_oid,
    head_oid = head_oid,
    comments_json = vim.json.encode(comments or {
      {
        id = 1002,
        path = "a.lua",
        line = 4,
        start_line = 2,
        body = "range comment",
        html_url = "https://example.test/r/1002",
        user = { login = "octocat" },
      },
      {
        id = 1003,
        path = "a.lua",
        line = vim.NIL,
        original_line = vim.NIL,
        body = "outdated comment",
        html_url = "https://example.test/r/1003",
        user = { login = "ghost" },
      },
    }),
    threads_json = threads and vim.json.encode({
      data = { repository = { pullRequest = { reviewThreads = { nodes = threads } } } },
    }) or nil,
  })
  return root, git, gh
end

describe("pjollrig review sources", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("resolves a bare invocation to HEAD-vs-worktree", function()
    local S = require("pjollrig.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")

    local job = assert(S.resolve({}, { cwd = root, stage_dir = ctx.artifact_root .. "/s1" }))
    assert.are.equal("HEAD", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal(root .. "/a.lua", job.files[1].right)
  end)

  it("resolves a branch name via merge-base (only your changes)", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    -- main moves ahead AFTER we branch; its change must not appear.
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")
    git("checkout", "-q", "main")
    vim.fn.writefile({ "-- main moved" }, root .. "/main-only.lua")
    git("add", "main-only.lua")
    git("commit", "-qm", "main work")
    git("checkout", "-q", "feature")

    local job = assert(S.resolve({ "main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s2" }))
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
  end)

  it("resolves two directories without git", function()
    local S = require("pjollrig.review.sources")
    local left = ctx.artifact_root .. "/L"
    local right = ctx.artifact_root .. "/R"
    vim.fn.mkdir(left .. "/sub", "p")
    vim.fn.mkdir(right .. "/sub", "p")
    vim.fn.writefile({ "old" }, left .. "/sub/m.txt")
    vim.fn.writefile({ "new" }, right .. "/sub/m.txt")
    vim.fn.writefile({ "same" }, left .. "/same.txt")
    vim.fn.writefile({ "same" }, right .. "/same.txt")
    vim.fn.writefile({ "gone" }, left .. "/gone.txt")
    vim.fn.writefile({ "added" }, right .. "/added.txt")

    local job = assert(S.resolve({ left, right }, {}))
    local by_path = {}
    for _, pair in ipairs(job.files) do
      by_path[pair.path] = pair.status
    end
    assert.are.equal("M", by_path["sub/m.txt"])
    assert.are.equal("D", by_path["gone.txt"])
    assert.are.equal("A", by_path["added.txt"])
    assert.is_nil(by_path["same.txt"])
  end)

  it("dirs resolver never walks or diffs .git subtrees", function()
    local S = require("pjollrig.review.sources")
    local left = ctx.artifact_root .. "/GL"
    local right = ctx.artifact_root .. "/GR"
    for _, dir in ipairs({ left, right }) do
      vim.fn.mkdir(dir .. "/.git/objects", "p")
      vim.fn.mkdir(dir .. "/sub/.git", "p")
    end
    -- Differing git internals on both sides, at the top AND nested: none
    -- of them may surface as diff pairs.
    vim.fn.writefile({ "ref: refs/heads/a" }, left .. "/.git/HEAD")
    vim.fn.writefile({ "ref: refs/heads/b" }, right .. "/.git/HEAD")
    vim.fn.writefile({ "L" }, left .. "/.git/objects/pack")
    vim.fn.writefile({ "RR" }, right .. "/.git/objects/pack")
    vim.fn.writefile({ "left only" }, left .. "/sub/.git/config")
    vim.fn.writefile({ "old" }, left .. "/sub/code.lua")
    vim.fn.writefile({ "new!" }, right .. "/sub/code.lua")

    local job = assert(S.resolve({ left, right }, {}))
    assert.are.equal(1, #job.files)
    assert.are.equal("sub/code.lua", job.files[1].path)
  end)

  it("dirs resolver stages every right-only file under one owned dir", function()
    local S = require("pjollrig.review.sources")
    local left = ctx.artifact_root .. "/SL"
    local right = ctx.artifact_root .. "/SR"
    vim.fn.mkdir(left, "p")
    vim.fn.mkdir(right .. "/sub", "p")
    vim.fn.writefile({ "one" }, right .. "/one.lua")
    vim.fn.writefile({ "two" }, right .. "/sub/two.lua")

    local job = assert(S.resolve({ left, right }, {}))
    assert.are.equal(2, #job.files)
    -- ONE stage dir for all right-only files (not one mkdtemp per file),
    -- reported in the job so review.stop() can delete it.
    assert.are.equal("table", type(job.stage_dirs))
    assert.are.equal(1, #job.stage_dirs)
    local dir = job.stage_dirs[1]
    assert.are.equal(1, vim.fn.isdirectory(dir))
    for _, pair in ipairs(job.files) do
      assert.are.equal("A", pair.status)
      assert.are.equal(dir, pair.left:sub(1, #dir), "staged left outside the owned dir: " .. pair.left)
    end
    vim.fn.delete(dir, "rf")
  end)

  it("dirs resolver reports no stage dirs when nothing needed staging", function()
    local S = require("pjollrig.review.sources")
    local left = ctx.artifact_root .. "/NL"
    local right = ctx.artifact_root .. "/NR"
    vim.fn.mkdir(left, "p")
    vim.fn.mkdir(right, "p")
    vim.fn.writefile({ "old" }, left .. "/m.txt")
    vim.fn.writefile({ "new" }, right .. "/m.txt")

    local job = assert(S.resolve({ left, right }, {}))
    assert.are.equal(1, #job.files)
    assert.is_nil(job.stage_dirs)
  end)

  it("git resolver owns its stage dir only when it created it", function()
    local S = require("pjollrig.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")

    -- Caller-provided stage dir: the caller's to manage, never reported.
    local provided = assert(S.resolve({}, { cwd = root, stage_dir = ctx.artifact_root .. "/prov" }))
    assert.is_nil(provided.stage_dirs)

    -- Self-created stage dir: reported so review.stop() can delete it.
    local owned = assert(S.resolve({}, { cwd = root }))
    assert.are.equal("table", type(owned.stage_dirs))
    assert.are.equal(1, #owned.stage_dirs)
    assert.are.equal(1, vim.fn.isdirectory(owned.stage_dirs[1]))
    assert.are.equal(1, owned.files[1].left:find(owned.stage_dirs[1], 1, true))
    vim.fn.delete(owned.stage_dirs[1], "rf")
  end)

  it("resolves a remote-tracking ref via merge-base", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    -- Simulate a fetched remote branch with a ref under refs/remotes.
    git("update-ref", "refs/remotes/origin/main", vim.trim(git("rev-parse", "HEAD").stdout))
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")

    local job = assert(S.resolve({ "origin/main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s4" }))
    assert.are.equal("origin/main", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
  end)

  it("errors outside a git repo for ref arguments", function()
    local S = require("pjollrig.review.sources")
    local job, err = S.resolve({ "main" }, { cwd = ctx.artifact_root })
    assert.is_nil(job)
    assert.is_truthy(err)
  end)

  it("resolves pr <n> via gh with head checked out", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)

    local bin = fake_gh(ctx.artifact_root, base_oid, head_oid, "Fix the frobnicator")
    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path

    local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s3" })
    vim.env.PATH = saved_path

    assert.is_nil(err)
    assert.are.equal("pr 42: Fix the frobnicator", job.label)
    -- The PR number must reach the session's sink context, or
    -- :PjollrigReviewFinish github falls back to `gh pr view` on the
    -- current branch and posts to the wrong PR.
    assert.are.same({ pr = 42 }, job.ctx)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal(root .. "/a.lua", job.files[1].right)
  end)

  it("resolves pr <n> with head not checked out, staging literal C-quotable paths", function()
    local S = require("pjollrig.review.sources")
    local root, git = H.git_repo(ctx, { ["å.txt"] = { "base content" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "head content" }, root .. "/å.txt")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    -- Review the PR WITHOUT checking it out: both sides get staged.
    git("checkout", "-q", "main")

    local bin = fake_gh(ctx.artifact_root, base_oid, head_oid)
    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path

    local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s19" })
    vim.env.PATH = saved_path

    assert.is_nil(err)
    assert.are.same({ pr = 42 }, job.ctx)
    assert.are.equal(1, #job.files)
    -- With core.quotePath=true a non -z diff reports `"\303\245.txt"`;
    -- the staged pair must use the literal path on both sides.
    assert.are.equal("å.txt", job.files[1].path)
    assert.are.equal("M", job.files[1].status)
    assert.are.equal("base content", table.concat(vim.fn.readfile(job.files[1].left), "\n"))
    assert.are.equal("head content", table.concat(vim.fn.readfile(job.files[1].right), "\n"))
  end)

  describe("pr comment import", function()
    local saved_path

    before_each(function()
      saved_path = vim.env.PATH
    end)
    after_each(function()
      vim.env.PATH = saved_path
      pcall(function()
        require("pjollrig.review").stop()
      end)
    end)

    it("imports PR review comments as records and skips line=null comments", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s5" })

      assert.is_nil(err)
      assert.is_truthy(job)
      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      local r = records[1]
      assert.are.equal(require("pjollrig.uri").for_path(root .. "/a.lua"), r.uri)
      assert.are.same({ start = { 1, 0 }, end_ = { 3, 0 } }, r.range)
      assert.are.equal("range comment", r.body)
      assert.are.equal("octocat", r.author)
      assert.are.equal("project", r.scope)
      assert.are.equal(root, r.project_root)
      assert.are.equal(1002, r.meta.github.id)
      assert.are.equal("https://example.test/r/1002", r.meta.github.url)
      assert.is_true(r.meta.github.imported)
    end)

    it("stamps the anchored worktree excerpt on imported comments", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 4001,
          path = "a.lua",
          line = 2,
          body = "single line comment",
          html_url = "https://example.test/r/4001",
          user = { login = "octocat" },
        },
        {
          id = 4002,
          path = "a.lua",
          line = 4,
          start_line = 2,
          body = "range comment",
          html_url = "https://example.test/r/4002",
          user = { login = "octocat" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s24" }))

      local by_id = {}
      for _, r in ipairs(require("pjollrig.store").all(root)) do
        by_id[r.meta.github.id] = r
      end
      -- Head worktree line 2 is "-- two"; the range comment (2..4) gets
      -- the multi-line continuation ellipsis, exactly like the add path.
      assert.are.equal("-- two", by_id[4001].meta.excerpt)
      assert.are.equal("-- two…", by_id[4002].meta.excerpt)

      -- The excerpt is STORED, not a live read: changing the anchored
      -- worktree line afterwards leaves the citation on what was
      -- commented on (mirrors the add-path capture).
      vim.fn.writefile({ "return 2", "-- changed", "-- three", "-- four", "-- five" }, root .. "/a.lua")
      local record = require("pjollrig.store").get(root, by_id[4001].id)
      assert.are.equal("-- two", record.meta.excerpt)
    end)

    it("backfills the excerpt onto existing imported records on re-import", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s25" }))
      local store = require("pjollrig.store")
      local record = store.all(root)[1]
      -- Simulate a record imported before excerpt capture existed.
      record.meta.excerpt = nil
      store.put_record(record)
      assert(store.save(root))

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s26" }))

      assert.are.equal("-- two…", store.all(root)[1].meta.excerpt)
    end)

    it("records thread ids and the PR number on imported comments", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 1002,
          path = "a.lua",
          line = 2,
          body = "thread root",
          html_url = "https://example.test/r/1002",
          user = { login = "octocat" },
        },
        {
          id = 1004,
          path = "a.lua",
          line = 2,
          in_reply_to_id = 1002,
          body = "a reply",
          html_url = "https://example.test/r/1004",
          user = { login = "hubber" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s12" }))

      local by_id = {}
      for _, r in ipairs(require("pjollrig.store").all(root)) do
        by_id[r.meta.github.id] = r
      end
      assert.are.equal(1002, by_id[1002].meta.github.thread_id)
      assert.are.equal(1002, by_id[1004].meta.github.thread_id)
      assert.are.equal(42, by_id[1002].meta.github.pr)
    end)

    it("maps review thread node ids and resolved flags onto imported records", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments(nil, {
        { id = "RT_1", isResolved = true, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s13" }))

      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal("RT_1", records[1].meta.github.thread_node)
      assert.is_true(records[1].meta.github.resolved)
    end)

    it("does not warn about thread support when there are no comments", function()
      local S = require("pjollrig.review.sources")
      -- Empty comment stream AND a failing GraphQL endpoint: the thread
      -- fetch (which now runs concurrently with the comment fetch) must
      -- stay silent when there is nothing to import.
      local root, _, gh = pr_repo_with_comments({})
      gh.set_no_graphql()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local warned
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warned = msg
        end
        return original_notify(msg, level)
      end
      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s23" })
      vim.notify = original_notify

      assert.is_nil(err)
      assert.is_truthy(job)
      assert.is_nil(warned, "no comments to import, yet a warning fired: " .. tostring(warned))
      assert.are.equal(0, #require("pjollrig.store").all(root))
    end)

    it("imports without resolve support when the thread query fails", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      gh.set_no_graphql()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local warned
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warned = msg
        end
        return original_notify(msg, level)
      end
      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s14" })
      vim.notify = original_notify

      assert.is_nil(err)
      assert.is_truthy(job)
      assert.is_truthy(warned, "expected a WARN about resolve support")
      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      assert.is_nil(records[1].meta.github.thread_node)
    end)

    it("preserves comment bodies containing `][` byte-for-byte", function()
      local S = require("pjollrig.review.sources")
      local body = "see [ref][1] and t[1][2]"
      local root, _, gh = pr_repo_with_comments({
        {
          id = 2001,
          path = "a.lua",
          line = 1,
          body = body,
          html_url = "https://example.test/r/2001",
          user = { login = "octocat" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s10" }))

      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal(body, records[1].body)
    end)

    it("falls back to manual paging when gh lacks --slurp", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      gh.set_no_slurp()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s11" }))

      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal("range comment", records[1].body)
    end)

    it("skips LEFT-side and null-line comments instead of anchoring them to head lines", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 3001,
          path = "a.lua",
          side = "RIGHT",
          line = 4,
          body = "head comment",
          html_url = "https://example.test/r/3001",
          user = { login = "octocat" },
        },
        {
          -- Anchored to base line 5: head line 5 is an unrelated line,
          -- so this must not import at head coordinates.
          id = 3002,
          path = "a.lua",
          side = "LEFT",
          line = 5,
          original_line = 5,
          body = "base-side comment",
          html_url = "https://example.test/r/3002",
          user = { login = "octocat" },
        },
        {
          -- Outdated position: line=null with original_line pointing at
          -- a superseded head commit — must not anchor via original_line.
          id = 3003,
          path = "a.lua",
          side = "RIGHT",
          line = vim.NIL,
          original_line = 3,
          body = "outdated comment",
          html_url = "https://example.test/r/3003",
          user = { login = "octocat" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local notified = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        notified[#notified + 1] = msg
        return original_notify(msg, level)
      end
      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s17" })
      vim.notify = original_notify

      assert.is_nil(err)
      assert.is_truthy(job)
      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal(3001, records[1].meta.github.id)
      assert.are.same({ start = { 3, 0 }, end_ = { 3, 0 } }, records[1].range)
      local summary
      for _, msg in ipairs(notified) do
        if msg:find("imported", 1, true) then
          summary = msg
        end
      end
      assert.is_truthy(summary, "expected an import summary notify")
      assert.is_truthy(summary:find("2 skipped", 1, true), "expected the skip count in: " .. summary)
    end)

    it("paginates review threads past the first GraphQL page", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 1002,
          path = "a.lua",
          side = "RIGHT",
          line = 4,
          body = "second page thread",
          html_url = "https://example.test/r/1002",
          user = { login = "octocat" },
        },
      })
      gh.set_thread_pages({
        { id = "RT_1", isResolved = false, comments = { nodes = { { databaseId = 9999 } } } },
      }, {
        { id = "RT_2", isResolved = true, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s18" }))

      local records = require("pjollrig.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal("RT_2", records[1].meta.github.thread_node)
      assert.is_true(records[1].meta.github.resolved)
    end)

    it("backfills thread data onto existing records on re-import", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s15" }))
      local store = require("pjollrig.store")
      local records = store.all(root)
      assert.are.equal(1, #records)
      assert.is_nil(records[1].meta.github.thread_node)

      gh.set_threads({
        { id = "RT_9", isResolved = true, comments = { nodes = { { databaseId = 1002 } } } },
      })
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s16" }))

      records = store.all(root)
      assert.are.equal(1, #records)
      assert.are.equal("RT_9", records[1].meta.github.thread_node)
      assert.is_true(records[1].meta.github.resolved)

      -- Resolve now works on the backfilled record: RT_9 is resolved, so
      -- gr sends unresolveReviewThread and flips the local flag. The
      -- mutation runs through an async vim.system, so wait for the
      -- callback to land before asserting.
      require("pjollrig.review.github").toggle_resolve({ id = records[1].id, project_root = root })
      vim.wait(2000, function()
        return store.get(root, records[1].id).meta.github.resolved == false
      end)
      assert.is_false(store.get(root, records[1].id).meta.github.resolved)
    end)

    it("toggles thread resolution asynchronously without blocking", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments(nil, {
        { id = "RT_1", isResolved = false, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s20" }))
      local store = require("pjollrig.store")
      local record = store.all(root)[1]
      assert.is_nil(record.meta.github.resolved)

      local messages = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = tostring(msg), level = level })
      end
      require("pjollrig.review.github").toggle_resolve({ id = record.id, project_root = root })
      -- gh runs via an async vim.system: the local flag must not have
      -- flipped yet when toggle_resolve returns.
      local flipped_synchronously = store.get(root, record.id).meta.github.resolved == true
      vim.wait(2000, function()
        return store.get(root, record.id).meta.github.resolved == true
      end)
      vim.notify = original_notify

      assert.is_false(flipped_synchronously)
      assert.is_true(store.get(root, record.id).meta.github.resolved)
      -- Pending feedback fires immediately, success once gh confirms.
      assert.are.equal("pjollrig: resolving thread...", messages[1].msg)
      local resolved_notified = false
      for _, entry in ipairs(messages) do
        if entry.msg == "pjollrig: thread resolved" then
          resolved_notified = true
        end
      end
      assert.is_true(resolved_notified)
    end)

    it("keeps the local flag and reports the error when the mutation fails", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments(nil, {
        { id = "RT_1", isResolved = false, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s21" }))
      local store = require("pjollrig.store")
      local record = store.all(root)[1]
      gh.set_no_graphql()

      local err_msg
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          err_msg = tostring(msg)
        end
      end
      require("pjollrig.review.github").toggle_resolve({ id = record.id, project_root = root })
      vim.wait(2000, function()
        return err_msg ~= nil
      end)
      vim.notify = original_notify

      assert.are.equal("pjollrig: gh resolveReviewThread failed: gh: graphql boom", err_msg)
      assert.is_nil(store.get(root, record.id).meta.github.resolved)
    end)

    it("routes thread mutations through the configured github sink command", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments(nil, {
        { id = "RT_1", isResolved = false, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s22" }))
      local store = require("pjollrig.store")
      local record = store.all(root)[1]

      -- Decoy `gh` on PATH that always fails: the mutation must go
      -- through `sinks.github.command` (the same knob the github sink
      -- reads), not a hardcoded PATH lookup of `gh`.
      local decoy_bin = ctx.artifact_root .. "/decoy-bin"
      vim.fn.mkdir(decoy_bin, "p")
      vim.fn.writefile({ "#!/bin/sh", "exit 9" }, decoy_bin .. "/gh")
      vim.fn.system({ "chmod", "+x", decoy_bin .. "/gh" })
      vim.env.PATH = decoy_bin .. ":" .. saved_path
      require("pjollrig.config").get().sinks.github = { command = gh.bin .. "/gh" }

      require("pjollrig.review.github").toggle_resolve({ id = record.id, project_root = root })
      vim.wait(2000, function()
        return store.get(root, record.id).meta.github.resolved == true
      end)

      assert.is_true(store.get(root, record.id).meta.github.resolved)
    end)

    it("re-resolving the same PR does not duplicate imported records", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s6" }))
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s7" }))

      assert.are.equal(1, #require("pjollrig.store").all(root))
    end)

    it("still returns a job when the comment fetch fails", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      gh.set_no_repo()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s8" })

      assert.is_nil(err)
      assert.is_truthy(job)
      assert.are.equal(1, #job.files)
      assert.are.equal(0, #require("pjollrig.store").all(root))
    end)

    it("finish() batch excludes imported records", function()
      local S = require("pjollrig.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local job = assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s9" }))
      assert.are.equal(1, #require("pjollrig.store").all(root))

      local sent
      require("pjollrig").register_sink({
        name = "capture",
        send = function(comments, _, cb)
          sent = comments
          cb(true)
        end,
      })

      local R = require("pjollrig.review")
      assert.is_true(R.start({ files = job.files, label = job.label, sink = "capture" }))

      -- Focus the right (worktree) window and add one local comment.
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].buftype ~= "quickfix" and vim.bo[bufnr].modifiable then
          vim.api.nvim_set_current_win(winid)
          break
        end
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ui = require("pjollrig.ui")
      local original_prompt = ui.prompt
      ui.prompt = function(_opts, cb)
        cb("local comment")
      end
      require("pjollrig").add()
      ui.prompt = original_prompt

      R.finish()
      vim.wait(500, function()
        return sent ~= nil
      end)
      R.stop()

      assert.is_truthy(sent)
      assert.are.equal(1, #sent)
      assert.are.equal("local comment", sent[1].body)
    end)
  end)
end)

describe("pjollrig review source registration", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("register() validates the resolver shape", function()
    local S = require("pjollrig.review.sources")
    local ok, err = pcall(S.register, { match = function() end, resolve = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("name", 1, true))

    ok, err = pcall(S.register, { name = "x", match = "not a function", resolve = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("match", 1, true))

    ok, err = pcall(S.register, { name = "x", match = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("resolve", 1, true))

    assert.is_false(pcall(S.register, nil))
  end)

  it("pjollrig.register_review_source registers a resolver that shadows builtins", function()
    -- The magic first arg keeps the resolver inert for every other spec
    -- (registration is process-global; there is no registry reset).
    local marker = "hub-spec-" .. tostring(math.random(1e6))
    require("pjollrig").register_review_source({
      name = "hub-spec",
      match = function(fargs)
        return fargs[1] == marker
      end,
      resolve = function()
        return { files = { { left = "/l", right = "/r", status = "M", path = "r" } }, label = "hub-spec" }
      end,
    })
    -- Prepend-shadows: the fresh resolver wins over the builtin git
    -- resolver, which also matches single-argument invocations.
    local job = assert(require("pjollrig.review.sources").resolve({ marker }, {}))
    assert.are.equal("hub-spec", job.label)
  end)
end)
