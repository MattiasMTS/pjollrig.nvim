local H = require("helpers")

local ctx

describe("pjollrig review git plumbing", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("lists modified, added, deleted, and untracked files vs a base", function()
    local G = require("pjollrig.review.git")
    local root, git = H.git_repo(ctx, {
      ["src/a.lua"] = { "return 1" },
      ["src/gone.lua"] = { "return 0" },
    })
    -- modify a.lua, delete gone.lua, add untracked new.lua
    vim.fn.writefile({ "return 2" }, root .. "/src/a.lua")
    vim.fn.delete(root .. "/src/gone.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/new.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local changed = assert(G.changed_files(root, base))
    local by_path = {}
    for _, entry in ipairs(changed) do
      by_path[entry.path] = entry.status
    end
    assert.are.equal("M", by_path["src/a.lua"])
    assert.are.equal("D", by_path["src/gone.lua"])
    assert.are.equal("A", by_path["src/new.lua"])
  end)

  it("returns literal paths for names git would C-quote and stages their baselines", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, {
      ["å.txt"] = { "base umlaut" },
      ["a b.txt"] = { "base space" },
    })
    vim.fn.writefile({ "changed umlaut" }, root .. "/å.txt")
    vim.fn.writefile({ "changed space" }, root .. "/a b.txt")

    local base = assert(G.rev_parse(root, "HEAD"))
    local changed = assert(G.changed_files(root, base))
    local by_path = {}
    for _, entry in ipairs(changed) do
      by_path[entry.path] = entry.status
    end
    -- With core.quotePath=true (the default) a non -z diff reports
    -- `"\303\245.txt"`; the entry must carry the literal path instead.
    assert.are.equal("M", by_path["å.txt"])
    assert.are.equal("M", by_path["a b.txt"])

    local files = G.stage_baseline(root, base, changed, ctx.artifact_root .. "/quoted-staged")
    local pair_by_path = {}
    for _, pair in ipairs(files) do
      pair_by_path[pair.path] = pair
    end
    assert.are.equal("base umlaut", table.concat(vim.fn.readfile(pair_by_path["å.txt"].left), "\n"))
    assert.are.equal("base space", table.concat(vim.fn.readfile(pair_by_path["a b.txt"].left), "\n"))
  end)

  it("keeps the record stream aligned across two-path rename records", function()
    local G = require("pjollrig.review.git")
    -- `--no-renames` means R/C records never appear today, but the parser
    -- must not corrupt the stream if the flags ever change: R/C statuses
    -- carry a score suffix and TWO paths (source, destination).
    local out = table.concat({ "M", "a.txt", "R100", "old name.txt", "new name.txt", "D", "gone.txt" }, "\0") .. "\0"
    local entries = G.parse_name_status(out)
    assert.are.equal(3, #entries)
    assert.are.equal("a.txt", entries[1].path)
    assert.are.equal("M", entries[1].status)
    assert.are.equal("new name.txt", entries[2].path)
    assert.are.equal("M", entries[2].status)
    assert.are.equal("gone.txt", entries[3].path)
    assert.are.equal("D", entries[3].status)
  end)

  it("stages baseline file versions into a directory", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, { ["src/a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/src/a.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/new.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local dir = ctx.artifact_root .. "/staged"
    local files = G.stage_baseline(root, base, {
      { path = "src/a.lua", status = "M" },
      { path = "src/new.lua", status = "A" },
    }, dir)

    assert.are.equal(2, #files)
    local by_path = {}
    for _, pair in ipairs(files) do
      by_path[pair.path] = pair
    end
    -- Modified: left holds the committed content, right is the worktree file.
    assert.are.equal("return 1", table.concat(vim.fn.readfile(by_path["src/a.lua"].left), "\n"))
    assert.are.equal(root .. "/src/a.lua", by_path["src/a.lua"].right)
    -- Added: left is an empty staged file so diff shows all-added.
    assert.are.equal(0, vim.fn.getfsize(by_path["src/new.lua"].left))
  end)

  it("stages tracked baselines with two subprocesses", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, {
      ["src/modified file.lua"] = { "return 1" },
      ["src/deleted.lua"] = { "return 0" },
    })
    vim.fn.writefile({ "return 2" }, root .. "/src/modified file.lua")
    vim.fn.delete(root .. "/src/deleted.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/added.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local original_run, original_spawn = G.run, G.spawn
    local calls = {}
    G.run = function(argv, opts)
      table.insert(calls, argv)
      return original_run(argv, opts)
    end
    G.spawn = function(argv, opts)
      table.insert(calls, argv)
      return original_spawn(argv, opts)
    end
    local ok, files = pcall(G.stage_baseline, root, base, {
      { path = "src/modified file.lua", status = "M" },
      { path = "src/deleted.lua", status = "D" },
      { path = "src/added.lua", status = "A" },
    }, ctx.artifact_root .. "/bulk-staged")
    G.run, G.spawn = original_run, original_spawn

    assert.is_true(ok)
    assert.are.equal(2, #calls)
    assert.are.equal("git", calls[1][1])
    assert.are.equal(root, calls[1][3])
    assert.are.equal("--literal-pathspecs", calls[1][4])
    assert.are.equal("archive", calls[1][5])
    assert.are.equal("-o", calls[1][6])
    assert.are.equal("tar", calls[2][1])
    assert.are.equal("-xf", calls[2][2])
    assert.are.equal(3, #files)
    assert.are.equal("return 1", table.concat(vim.fn.readfile(files[1].left), "\n"))
    assert.are.equal("return 0", table.concat(vim.fn.readfile(files[2].left), "\n"))
    assert.are.equal(0, vim.fn.getfsize(files[3].left))
  end)

  it("materializes a multi-file batch at a ref into a directory", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, {
      ["src/a.lua"] = { "base a" },
      ["src/sub/b.lua"] = { "base b" },
    })
    vim.fn.writefile({ "changed a" }, root .. "/src/a.lua")
    vim.fn.writefile({ "changed b" }, root .. "/src/sub/b.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local original_run, original_spawn = G.run, G.spawn
    local calls = {}
    G.run = function(argv, opts)
      table.insert(calls, argv)
      return original_run(argv, opts)
    end
    G.spawn = function(argv, opts)
      table.insert(calls, argv)
      return original_spawn(argv, opts)
    end
    local dir = ctx.artifact_root .. "/materialized"
    local ok, err = pcall(G.materialize, root, base, { "src/a.lua", "src/sub/b.lua" }, dir)
    G.run, G.spawn = original_run, original_spawn

    assert.is_true(ok, tostring(err))
    -- One archive + one tar for the whole batch, no per-file git show.
    assert.are.equal(2, #calls)
    assert.are.equal("base a", table.concat(vim.fn.readfile(dir .. "/src/a.lua"), "\n"))
    assert.are.equal("base b", table.concat(vim.fn.readfile(dir .. "/src/sub/b.lua"), "\n"))
  end)

  it("fans out chunked archive subprocesses before extracting", function()
    local G = require("pjollrig.review.git")
    local root, git = H.git_repo(ctx)
    local paths = {}
    -- Identical content on purpose: 201 paths force two archive chunks
    -- while producing ONE loose blob object, keeping the fixture repo
    -- small (macOS teardown of large fresh object trees is flaky-noisy).
    for i = 1, 201 do
      local rel = ("f%03d.txt"):format(i)
      vim.fn.writefile({ "shared content" }, root .. "/" .. rel)
      paths[i] = rel
    end
    git("add", ".")
    git("commit", "-qm", "fanout files")

    local base = assert(G.rev_parse(root, "HEAD"))
    local original_run, original_spawn = G.run, G.spawn
    local order = {}
    G.run = function(argv, opts)
      table.insert(order, argv[1])
      return original_run(argv, opts)
    end
    G.spawn = function(argv, opts)
      table.insert(order, argv[1] .. "-spawn")
      return original_spawn(argv, opts)
    end
    local dir = ctx.artifact_root .. "/fanout"
    local ok, err = pcall(G.materialize, root, base, paths, dir)
    G.run, G.spawn = original_run, original_spawn

    assert.is_true(ok, tostring(err))
    -- 201 paths split into a 200-path and a 1-path chunk. The chunks are
    -- independent, so BOTH archives spawn before the first tar runs
    -- (archive N+1 overlaps tar N instead of serializing).
    assert.are.same({ "git-spawn", "git-spawn", "tar", "tar" }, order)
    -- One file from each chunk actually extracted.
    assert.are.equal("shared content", table.concat(vim.fn.readfile(dir .. "/f001.txt"), "\n"))
    assert.are.equal("shared content", table.concat(vim.fn.readfile(dir .. "/f201.txt"), "\n"))
  end)

  it("self-heals an archive chunk containing a path absent from the base", function()
    local G = require("pjollrig.review.git")
    local uv = vim.uv
    local root = H.git_repo(ctx, {
      ["src/a.lua"] = { "return 1" },
      ["src/b.lua"] = { "return 2" },
    })
    local base = assert(G.rev_parse(root, "HEAD"))
    local files = G.stage_baseline(root, base, {
      { path = "src/a.lua", status = "M" },
      { path = "src/bogus.lua", status = "M" },
      { path = "src/b.lua", status = "D" },
    }, ctx.artifact_root .. "/bogus-staged")

    local by_path = {}
    for _, pair in ipairs(files) do
      by_path[pair.path] = pair
    end
    assert.are.equal("return 1", table.concat(vim.fn.readfile(by_path["src/a.lua"].left), "\n"))
    assert.are.equal("return 2", table.concat(vim.fn.readfile(by_path["src/b.lua"].left), "\n"))
    assert.are.equal("file", assert(uv.fs_lstat(by_path["src/bogus.lua"].left)).type)
    assert.are.equal(0, vim.fn.getfsize(by_path["src/bogus.lua"].left))
  end)

  it("stages a baseline symlink blob as a regular file", function()
    local G = require("pjollrig.review.git")
    local uv = vim.uv
    local root, git = H.git_repo(ctx, { ["target.txt"] = { "target content" } })
    local ok, linked = pcall(uv.fs_symlink, "target.txt", root .. "/link.txt")
    if not ok or not linked then
      pending("platform cannot create symlinks")
      return
    end
    git("add", "link.txt")
    git("commit", "-qm", "add symlink")

    local base = assert(G.rev_parse(root, "HEAD"))
    local files = G.stage_baseline(root, base, {
      { path = "link.txt", status = "M" },
    }, ctx.artifact_root .. "/symlink-staged")

    assert.are.equal("file", assert(uv.fs_lstat(files[1].left)).type)
    assert.are.equal("target.txt", table.concat(vim.fn.readfile(files[1].left), "\n"))
  end)

  it("expands untracked files inside fully untracked directories", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    -- A fully untracked directory: `git status --porcelain` collapses it
    -- to `?? newdir/`, so changed_files must expand it to real files.
    vim.fn.mkdir(root .. "/newdir/sub", "p")
    vim.fn.writefile({ "x" }, root .. "/newdir/one.lua")
    vim.fn.writefile({ "y" }, root .. "/newdir/sub/two.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local changed = assert(G.changed_files(root, base))
    local by_path = {}
    for _, entry in ipairs(changed) do
      by_path[entry.path] = entry.status
    end
    assert.are.equal("A", by_path["newdir/one.lua"])
    assert.are.equal("A", by_path["newdir/sub/two.lua"])
    assert.is_nil(by_path["newdir/"])
  end)

  it("computes merge-base", function()
    local G = require("pjollrig.review.git")
    local root, git = H.git_repo(ctx, { ["a.txt"] = { "one" } })
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "two" }, root .. "/a.txt")
    git("commit", "-aqm", "feature change")
    local main = assert(G.rev_parse(root, "main"))
    local mb = assert(G.merge_base(root, "HEAD", "main"))
    assert.are.equal(main, mb)
  end)
end)

describe("pjollrig review git async plumbing", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  ---Drive an async plumbing call from a spec: returns a `wait()` that
  ---blocks until the callback landed and returns its arguments.
  local function settled()
    local done = false
    local args
    return function(...)
      args = { ... }
      done = true
    end, function()
      vim.wait(10000, function()
        return done
      end, 5)
      assert.is_true(done, "async callback never fired")
      return unpack(args, 1, 2)
    end
  end

  it("changed_files_async matches the sync result, untracked dirs included", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, { ["mod.lua"] = { "return 1" }, ["del.lua"] = { "gone" } })
    vim.fn.writefile({ "return 2" }, root .. "/mod.lua")
    vim.fn.delete(root .. "/del.lua")
    vim.fn.mkdir(root .. "/newdir/sub", "p")
    vim.fn.writefile({ "one" }, root .. "/newdir/one.lua")
    vim.fn.writefile({ "two" }, root .. "/newdir/sub/two.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local sync = assert(G.changed_files(root, base))
    local cb, wait = settled()
    G.changed_files_async(root, base, cb)
    local entries, err = wait()
    assert.is_nil(err)
    assert.are.same(sync, entries)
  end)

  it("materialize_async stages the same tree as the sync pass and self-heals bogus paths", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, {
      ["src/a.lua"] = { "base a" },
      ["src/sub/b.lua"] = { "base b" },
    })
    local base = assert(G.rev_parse(root, "HEAD"))
    local dir = ctx.artifact_root .. "/async-materialized"

    local cb, wait = settled()
    G.materialize_async(root, base, { "src/a.lua", "src/sub/b.lua", "src/bogus.lua" }, dir, cb)
    local err = wait()
    assert.is_nil(err)
    assert.are.equal("base a", table.concat(vim.fn.readfile(dir .. "/src/a.lua"), "\n"))
    assert.are.equal("base b", table.concat(vim.fn.readfile(dir .. "/src/sub/b.lua"), "\n"))
    -- Absent at the ref: self-heal stages an empty regular file.
    assert.are.equal(0, vim.fn.getfsize(dir .. "/src/bogus.lua"))
  end)

  it("materialize_async fans out chunked archives and serializes extraction", function()
    local G = require("pjollrig.review.git")
    local root, git = H.git_repo(ctx)
    local paths = {}
    -- 201 identical-content paths force two archive chunks (the sync
    -- fan-out spec's fixture shape).
    for i = 1, 201 do
      local rel = ("f%03d.txt"):format(i)
      vim.fn.writefile({ "shared content" }, root .. "/" .. rel)
      paths[i] = rel
    end
    git("add", ".")
    git("commit", "-qm", "fanout files")
    local base = assert(G.rev_parse(root, "HEAD"))

    -- Observe subprocess traffic through the async seam. Archives may
    -- COMPLETE in any order, but both must spawn before any tar does,
    -- and the two tars must never overlap.
    local original_run_async = G.run_async
    local order = {}
    local tars_running = 0
    G.run_async = function(argv, opts, cb)
      local is_tar = argv[1] == "tar"
      table.insert(order, is_tar and "tar" or "git")
      if is_tar then
        tars_running = tars_running + 1
        assert.are.equal(1, tars_running, "concurrent tar extractions into one tree")
      end
      return original_run_async(argv, opts, function(result, spawn_err)
        if is_tar then
          tars_running = tars_running - 1
        end
        cb(result, spawn_err)
      end)
    end
    local cb, wait = settled()
    G.materialize_async(root, base, paths, ctx.artifact_root .. "/async-fanout", cb)
    local err = wait()
    G.run_async = original_run_async

    assert.is_nil(err)
    assert.are.same({ "git", "git" }, { order[1], order[2] }, "archives did not fan out first")
    assert.are.equal(4, #order, "expected 2 archives + 2 tars, got: " .. table.concat(order, ","))
    local dir = ctx.artifact_root .. "/async-fanout"
    assert.are.equal("shared content", table.concat(vim.fn.readfile(dir .. "/f001.txt"), "\n"))
    assert.are.equal("shared content", table.concat(vim.fn.readfile(dir .. "/f201.txt"), "\n"))
  end)

  it("stage_baseline_async builds the same pairs as the sync variant", function()
    local G = require("pjollrig.review.git")
    local root = H.git_repo(ctx, {
      ["src/modified.lua"] = { "return 1" },
      ["src/deleted.lua"] = { "return 0" },
    })
    vim.fn.writefile({ "return 2" }, root .. "/src/modified.lua")
    vim.fn.delete(root .. "/src/deleted.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/added.lua")
    local base = assert(G.rev_parse(root, "HEAD"))
    local entries = {
      { path = "src/added.lua", status = "A" },
      { path = "src/deleted.lua", status = "D" },
      { path = "src/modified.lua", status = "M" },
    }

    local sync = G.stage_baseline(root, base, entries, ctx.artifact_root .. "/sync-staged")
    local cb, wait = settled()
    G.stage_baseline_async(root, base, entries, ctx.artifact_root .. "/async-staged", cb)
    local files, err = wait()
    assert.is_nil(err)
    assert.are.equal(#sync, #files)
    for i, pair in ipairs(files) do
      assert.are.equal(sync[i].path, pair.path)
      assert.are.equal(sync[i].status, pair.status)
      assert.are.equal(sync[i].right, pair.right)
      assert.are.same(
        vim.fn.filereadable(sync[i].left) == 1 and vim.fn.readfile(sync[i].left) or "missing",
        vim.fn.filereadable(pair.left) == 1 and vim.fn.readfile(pair.left) or "missing"
      )
    end
  end)
end)
