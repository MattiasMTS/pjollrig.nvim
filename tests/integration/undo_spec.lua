-- Exercises the init-level multi-level undo stack for comment
-- deletions. Drives the real `pjollrig.delete` / `pjollrig.undo_delete`
-- path against a project-scoped SQLite store.

local H = require("helpers")

local ctx

local function setup_env()
  ctx = H.setup()
  H.edit_project_file(ctx, "src/example.lua", {
    "local value = 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

---Build a delete locator from a listed record.
---@param record table
---@return table
local function locator_for(record)
  return { id = record.id, scope = record.scope, project_root = record.project_root }
end

describe("pjollrig undo deletions", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("undo_delete restores the most recently deleted comment", function()
    require("pjollrig").add({
      body = "undo me",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    local id = records[1].id

    require("pjollrig").delete(id, locator_for(records[1]))
    assert.are.equal(0, #require("pjollrig").list())

    require("pjollrig").undo_delete()
    local restored = require("pjollrig").list()
    assert.are.equal(1, #restored)
    assert.are.equal(id, restored[1].id)
    assert.are.equal("undo me", restored[1].body)
  end)

  it("undo_delete is multi-level and restores in LIFO order", function()
    require("pjollrig").add({
      body = "first",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "second",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(2, #records)
    local by_body = {}
    for _, r in ipairs(records) do
      by_body[r.body] = r
    end
    assert.is_truthy(by_body.first)
    assert.is_truthy(by_body.second)

    -- Delete first, then second (so second is the most recent delete).
    require("pjollrig").delete(by_body.first.id, locator_for(by_body.first))
    require("pjollrig").delete(by_body.second.id, locator_for(by_body.second))
    assert.are.equal(0, #require("pjollrig").list())

    -- First undo brings back the second deletion (LIFO).
    require("pjollrig").undo_delete()
    local after_one = require("pjollrig").list()
    assert.are.equal(1, #after_one)
    assert.are.equal(by_body.second.id, after_one[1].id)

    -- Second undo brings back the first deletion.
    require("pjollrig").undo_delete()
    local after_two = require("pjollrig").list()
    assert.are.equal(2, #after_two)
    local ids = {}
    for _, r in ipairs(after_two) do
      ids[r.id] = true
    end
    assert.is_true(ids[by_body.first.id])
    assert.is_true(ids[by_body.second.id])
  end)

  it("undo_delete on an empty stack does not error", function()
    -- No deletions have happened; this should just notify, not throw.
    local ok = pcall(function()
      require("pjollrig").undo_delete()
    end)
    assert.is_true(ok)
    assert.are.equal(0, #require("pjollrig").list())
  end)

  it("redo_delete re-deletes a comment that was undone", function()
    require("pjollrig").add({
      body = "redo me",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    local id = records[1].id

    -- delete → undo (back) → redo (gone again).
    require("pjollrig").delete(id, locator_for(records[1]))
    require("pjollrig").undo_delete()
    assert.are.equal(1, #require("pjollrig").list())

    require("pjollrig").redo_delete()
    assert.are.equal(0, #require("pjollrig").list())
  end)

  it("redo_delete is multi-level and re-applies in LIFO order", function()
    require("pjollrig").add({
      body = "first",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "second",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(2, #records)
    local by_body = {}
    for _, r in ipairs(records) do
      by_body[r.body] = r
    end
    assert.is_truthy(by_body.first)
    assert.is_truthy(by_body.second)

    -- Delete both (second is the most recent delete).
    require("pjollrig").delete(by_body.first.id, locator_for(by_body.first))
    require("pjollrig").delete(by_body.second.id, locator_for(by_body.second))
    assert.are.equal(0, #require("pjollrig").list())

    -- Undo both — undo restores second first (LIFO), then first; the
    -- redo stack now holds [second, first] so redo pops first then second.
    require("pjollrig").undo_delete()
    require("pjollrig").undo_delete()
    assert.are.equal(2, #require("pjollrig").list())

    -- First redo re-deletes the first deletion (top of the redo stack).
    require("pjollrig").redo_delete()
    local after_one = require("pjollrig").list()
    assert.are.equal(1, #after_one)
    assert.are.equal(by_body.second.id, after_one[1].id)

    -- Second redo re-deletes the second deletion; both gone again.
    require("pjollrig").redo_delete()
    assert.are.equal(0, #require("pjollrig").list())
  end)

  it("a fresh deletion clears the redo branch", function()
    require("pjollrig").add({
      body = "alpha",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("pjollrig").add({
      body = "beta",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(2, #records)
    local by_body = {}
    for _, r in ipairs(records) do
      by_body[r.body] = r
    end

    -- Delete A, undo A (redo branch now holds A).
    require("pjollrig").delete(by_body.alpha.id, locator_for(by_body.alpha))
    require("pjollrig").undo_delete()

    -- A fresh deletion of B must invalidate the redo branch.
    require("pjollrig").delete(by_body.beta.id, locator_for(by_body.beta))

    -- redo_delete is now a no-op: A must NOT be re-deleted.
    require("pjollrig").redo_delete()
    local after = require("pjollrig").list()
    assert.are.equal(1, #after)
    assert.are.equal(by_body.alpha.id, after[1].id) -- A still present, B deleted.
  end)

  it("redo_delete on an empty stack does not error", function()
    -- Nothing has been undone; this should just notify, not throw.
    local ok = pcall(function()
      require("pjollrig").redo_delete()
    end)
    assert.is_true(ok)
    assert.are.equal(0, #require("pjollrig").list())
  end)

  it("a full delete → undo → redo → undo cycle leaves the comment present", function()
    require("pjollrig").add({
      body = "cycle",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("pjollrig").list()
    assert.are.equal(1, #records)
    local id = records[1].id

    require("pjollrig").delete(id, locator_for(records[1]))
    require("pjollrig").undo_delete()
    require("pjollrig").redo_delete()
    require("pjollrig").undo_delete()

    local final = require("pjollrig").list()
    assert.are.equal(1, #final)
    assert.are.equal(id, final[1].id)
    assert.are.equal("cycle", final[1].body)
  end)
end)
