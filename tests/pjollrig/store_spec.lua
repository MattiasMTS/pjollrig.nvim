-- Exercises the session-scope store round-trip and a few invariants of
-- the polymorphic dispatcher (project + session merge semantics).

local tmp_state
local tmp_root

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  require("pjollrig.store")._reset()
  require("pjollrig").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      canonicalize_symlinks = false,
      poll_interval_ms = 0,
    },
  })
end

local function new_store_client()
  return dofile(vim.fn.getcwd() .. "/lua/pjollrig/store.lua")
end

local function teardown_env()
  require("pjollrig.store")._reset()
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
end

describe("pjollrig.store session scope", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("session_put then session_save lands records on disk and reloads", function()
    local store = require("pjollrig.store")
    local uv = vim.uv

    local record = {
      id = "abc123",
      uri = "term://foo/1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session note",
      author = "t@example.com",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    store.session_put(record)
    local ok, err = store.session_save()
    assert.is_true(ok)
    assert.is_nil(err)

    -- File exists.
    assert.is_truthy(uv.fs_stat(store.session_path()))

    -- Reset cache and reload — records should come back.
    store._reset()
    local reloaded = store.session_all()
    assert.are.equal(1, #reloaded)
    assert.are.equal("abc123", reloaded[1].id)
    assert.are.equal("session note", reloaded[1].body)
    assert.are.equal("term://foo/1", reloaded[1].uri)

    -- session_for_uri filters.
    local hits = store.session_for_uri("term://foo/1")
    assert.are.equal(1, #hits)
    assert.are.equal("abc123", hits[1].id)

    assert.are.same({}, store.session_for_uri("file:///nope"))
  end)

  it("writes versioned session envelopes", function()
    local store = require("pjollrig.store")
    store.session_put({
      id = "enveloped",
      uri = "term://enveloped/1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "stored in envelope",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    assert.is_true(store.session_save())

    local encoded = table.concat(vim.fn.readfile(store.session_path()), "\n")
    local payload = vim.json.decode(encoded)
    assert.are.equal(store.schema_version(), payload.version)
    assert.are.equal("enveloped", payload.records[1].id)
  end)

  it("session_remove drops the record and survives save/reload", function()
    local store = require("pjollrig.store")
    store.session_put({
      id = "one",
      uri = "file:///a",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "a",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "two",
      uri = "file:///b",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "b",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_save()
    assert.are.equal(2, #store.session_all())

    local removed = store.session_remove("one")
    assert.is_truthy(removed)
    assert.are.equal("one", removed.id)
    store.session_save()

    store._reset()
    local reloaded = store.session_all()
    assert.are.equal(1, #reloaded)
    assert.are.equal("two", reloaded[1].id)
  end)

  it("put_record routes by scope", function()
    local store = require("pjollrig.store")
    local proj = {
      id = "p1",
      uri = "file://" .. tmp_root .. "/x.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "proj",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    local sess = {
      id = "s1",
      uri = "term://1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "sess",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    store.put_record(proj)
    store.put_record(sess)
    assert.are.equal(proj, store.get(tmp_root, "p1"))
    assert.are.equal(1, #store.session_all())
    assert.are.equal("s1", store.session_all()[1].id)
  end)

  it("flush_all flushes both caches", function()
    local store = require("pjollrig.store")
    local uv = vim.uv
    store.put(tmp_root, {
      id = "p1",
      uri = "file://" .. tmp_root .. "/a.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "a",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "s1",
      uri = "term://1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "b",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.flush_all()
    assert.is_truthy(uv.fs_stat(store.path(tmp_root)))
    assert.is_truthy(uv.fs_stat(store.session_path()))
  end)

  it("uses WAL for the SQLite project store", function()
    local store = require("pjollrig.store")
    store.load(tmp_root)

    local info = store.sqlite_info(tmp_root)
    assert.is_true(info.available)
    assert.are.equal("wal", info.journal_mode)
    assert.is_truthy(vim.uv.fs_stat(store.path(tmp_root)))
  end)

  it("does not consume a peer event committed just after reading the projection", function()
    local sqlite = require("pjollrig.sqlite")
    local original_open = sqlite.open
    local injected, peer = false, nil
    sqlite.open = function(path)
      local db, err = original_open(path)
      if db then
        local original_rows = db.rows
        db.rows = function(self, sql, params)
          local rows, rows_err = original_rows(self, sql, params)
          if not injected and sql:find("SELECT data FROM records", 1, true) then
            injected = true
            peer = new_store_client()
            peer.put(tmp_root, {
              id = "between-reads",
              uri = "file://" .. tmp_root .. "/peer.lua",
              scope = "project",
              project_root = tmp_root,
              range = { start = { 0, 0 }, end_ = { 0, 0 } },
              body = "committed after the projection read",
              created_at = 1,
              updated_at = 1,
            })
            assert.is_true(peer.save(tmp_root))
          end
          return rows, rows_err
        end
      end
      return db, err
    end
    local ok, err = pcall(function()
      local store = require("pjollrig.store")
      assert.are.equal(0, #store.load(tmp_root))
      assert.is_true(injected)
      local records = store.all(tmp_root)
      assert.are.equal(1, #records)
      assert.are.equal("between-reads", records[1].id)
    end)
    sqlite.open = original_open
    if peer then
      peer._reset()
    end
    assert.is_true(ok, err)
  end)

  it("syncs project records written by another store client", function()
    local store_a = require("pjollrig.store")
    local store_b = new_store_client()
    local record = {
      id = "from-b",
      uri = "file://" .. tmp_root .. "/peer.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "peer note",
      author = "",
      created_at = 1,
      updated_at = 1,
      resolved = false,
      meta = {},
    }

    assert.are.equal(0, #store_a.load(tmp_root))
    store_b.put(tmp_root, record)
    assert.is_true(store_b.save(tmp_root))

    local synced = store_a.all(tmp_root)
    assert.are.equal(1, #synced)
    assert.are.equal("from-b", synced[1].id)
    assert.are.equal("peer note", synced[1].body)
  end)

  it("merges stale clients at field granularity instead of record last-writer-wins", function()
    local store_a = require("pjollrig.store")
    local initial = {
      id = "merge-me",
      uri = "file://" .. tmp_root .. "/merge.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "original",
      author = "",
      created_at = 1,
      updated_at = 1,
      resolved = false,
      meta = {},
    }

    store_a.put(tmp_root, initial)
    assert.is_true(store_a.save(tmp_root))

    local store_stale_body_editor = new_store_client()
    local store_range_editor = new_store_client()
    local stale = store_stale_body_editor.load(tmp_root)[1]
    local ranged = store_range_editor.load(tmp_root)[1]

    ranged.range = { start = { 4, 0 }, end_ = { 5, 0 } }
    ranged.updated_at = 2
    store_range_editor.mark_dirty(tmp_root)
    assert.is_true(store_range_editor.save(tmp_root))

    stale.body = "body from stale client"
    stale.updated_at = 3
    store_stale_body_editor.mark_dirty(tmp_root)
    assert.is_true(store_stale_body_editor.save(tmp_root))

    local fresh = new_store_client()
    local merged = fresh.load(tmp_root)[1]
    assert.are.equal("body from stale client", merged.body)
    assert.are.same({ start = { 4, 0 }, end_ = { 5, 0 } }, merged.range)

    local events = fresh._events(tmp_root)
    local kinds = {}
    for _, event in ipairs(events) do
      table.insert(kinds, event.kind)
    end
    assert.are.same({ "comment_created", "comment_range_updated", "comment_body_updated" }, kinds)
  end)

  it("all_for_uri merges project + session records keyed on same URI", function()
    local store = require("pjollrig.store")
    -- Point store.root() at the fake root by opening a buffer inside
    -- it, so all_for_uri's root resolution lands here. The buffer's
    -- resolved root may canonicalize differently from `tmp_root`
    -- (macOS aliases /var/folders ↔ /private/var/folders), so grab
    -- whatever `store.root()` resolves to and use that as the key.
    vim.cmd.edit(tmp_root .. "/merge.lua")
    local resolved_root = store.root()
    assert.is_truthy(resolved_root)
    local uri = require("pjollrig.uri").for_bufnr(0)
    store.put(resolved_root, {
      id = "p",
      uri = uri,
      scope = "project",
      project_root = resolved_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "project",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "s",
      uri = uri,
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    local merged = store.all_for_uri(uri)
    assert.are.equal(2, #merged)
    local ids = { merged[1].id, merged[2].id }
    table.sort(ids)
    assert.are.same({ "p", "s" }, ids)
  end)

  it("all_for_uri accepts an explicit project root for non-current buffers", function()
    local store = require("pjollrig.store")
    local uri = require("pjollrig.uri").for_path(tmp_root .. "/target.lua")
    store.put(tmp_root, {
      id = "p",
      uri = uri,
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "project",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "s",
      uri = uri,
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })

    vim.cmd.enew()

    local opts_root = store.all_for_uri(uri, { root = tmp_root })
    assert.are.equal(2, #opts_root)

    local opts_session = store.all_for_uri(uri, { session_only = true })
    assert.are.equal(1, #opts_session)
    assert.are.equal("s", opts_session[1].id)

    -- The pre-opts positional form (a raw root / explicit nil as the
    -- second argument) is gone: only nil or an opts table is accepted.
    local ok, err = pcall(store.all_for_uri, uri, tmp_root)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("opts must be a table", 1, true))
  end)

  it("remove_record dispatches by scope from a single identity table", function()
    local store = require("pjollrig.store")
    local uri = require("pjollrig.uri").for_path(tmp_root .. "/remove.lua")
    local function record(id, scope)
      return {
        id = id,
        uri = uri,
        scope = scope,
        project_root = scope == "project" and tmp_root or nil,
        range = { start = { 0, 0 }, end_ = { 0, 0 } },
        body = id,
        author = "",
        created_at = 0,
        updated_at = 0,
        resolved = false,
        meta = {},
      }
    end
    store.put(tmp_root, record("p1", "project"))
    store.put(tmp_root, record("p2", "project"))
    store.session_put(record("s1", "session"))

    -- Table form, both scopes.
    local removed_project = store.remove_record({ scope = "project", id = "p1", project_root = tmp_root })
    assert.are.equal("p1", removed_project.id)
    local removed_session = store.remove_record({ scope = "session", id = "s1" })
    assert.are.equal("s1", removed_session.id)

    -- The positional form (scope, id, project_root) is gone.
    local ok, err = pcall(store.remove_record, "project", "p2", tmp_root)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("opts must be a table", 1, true))

    local removed_p2 = store.remove_record({ scope = "project", id = "p2", project_root = tmp_root })
    assert.are.equal("p2", removed_p2.id)

    assert.are.equal(0, #store.all_for_uri(uri, { root = tmp_root }))
  end)

  it("session_save keeps ephemeral unnamed-buffer records in memory but off disk", function()
    local store = require("pjollrig.store")
    store.session_put({
      id = "ephemeral",
      uri = "pjollrig://buffer/1/1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "scratch",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = { ephemeral = true },
    })

    local ok = store.session_save()
    assert.is_true(ok)
    assert.are.equal(1, #store.session_all())

    store._reset()
    assert.are.equal(0, #store.session_all())
  end)

  it("restore_record un-tombstones a soft-deleted project record on disk", function()
    local store = require("pjollrig.store")
    local record = {
      id = "del1",
      uri = "file://" .. tmp_root .. "/d.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "to delete",
      author = "",
      created_at = 1,
      updated_at = 1,
      resolved = false,
      meta = {},
    }
    store.put(tmp_root, record)
    assert.is_true(store.save(tmp_root))
    assert.are.equal(1, #store.all(tmp_root))

    -- Soft-delete: writes a tombstone row (deleted_at) to SQLite.
    local snapshot = vim.deepcopy(record)
    assert.is_truthy(store.remove(tmp_root, "del1"))
    assert.is_true(store.save(tmp_root))
    assert.are.equal(0, #store.all(tmp_root))

    -- Restore clears the tombstone in place.
    local ok, err = store.restore_record(snapshot)
    assert.is_true(ok)
    assert.is_nil(err)

    local restored = store.all(tmp_root)
    assert.are.equal(1, #restored)
    assert.are.equal("del1", restored[1].id)
    assert.are.equal("to delete", restored[1].body)

    -- A fresh client reading the same SQLite db must also see it — i.e.
    -- the tombstone was truly cleared on disk, not just in memory.
    local fresh = new_store_client()
    local fresh_records = fresh.load(tmp_root)
    assert.are.equal(1, #fresh_records)
    assert.are.equal("del1", fresh_records[1].id)
  end)

  it("restore_record on a missing project_root returns an error", function()
    local store = require("pjollrig.store")
    local ok, err = store.restore_record({ id = "x", scope = "project" })
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("memoizes the branch-scoped store name until _reset", function()
    -- `store_name` runs on every store read; with
    -- `store.scope_by_branch = true` the un-memoized version forked
    -- `git branch --show-current` per call. The memo pins the load-time
    -- name for the whole session (keeping cache[root]/sqlite_dbs
    -- coherent) and `_reset` drops it.
    vim.fn.system({ "git", "init", "-q", tmp_root })
    vim.fn.system({ "git", "-C", tmp_root, "checkout", "-q", "-b", "feature-a" })
    require("pjollrig").setup({
      store = {
        dir = tmp_state .. "/",
        format = "json",
        canonicalize_symlinks = false,
        poll_interval_ms = 0,
        scope_by_branch = true,
      },
    })
    local store = require("pjollrig.store")

    local path_a = store.path(tmp_root)
    assert.is_truthy(path_a:find("feature-a", 1, true))

    -- Switching branches on disk does NOT re-key the already-resolved
    -- store mid-session: reads and writes stay pinned to the database
    -- the session loaded.
    vim.fn.system({ "git", "-C", tmp_root, "checkout", "-q", "-b", "feature-b" })
    assert.are.equal(path_a, store.path(tmp_root))

    -- A reset (fresh session) resolves the new branch.
    store._reset()
    local path_b = store.path(tmp_root)
    assert.is_truthy(path_b:find("feature-b", 1, true))
    assert.are_not.equal(path_a, path_b)
  end)

  it("restore_record brings a removed session record back and survives reload", function()
    local store = require("pjollrig.store")
    local record = {
      id = "sdel",
      uri = "term://s/1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session to delete",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    store.session_put(record)
    assert.is_true(store.session_save())
    assert.are.equal(1, #store.session_all())

    local snapshot = vim.deepcopy(record)
    assert.is_truthy(store.session_remove("sdel"))
    assert.is_true(store.session_save())
    assert.are.equal(0, #store.session_all())

    local ok, err = store.restore_record(snapshot)
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, #store.session_all())
    assert.are.equal("sdel", store.session_all()[1].id)

    -- Survives a reload from disk.
    store._reset()
    local reloaded = store.session_all()
    assert.are.equal(1, #reloaded)
    assert.are.equal("sdel", reloaded[1].id)
    assert.are.equal("session to delete", reloaded[1].body)
  end)
end)
