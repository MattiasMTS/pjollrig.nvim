local H = require("helpers")
local uv = vim.uv

local ctx

---Start an in-process JSONL pipe server. Returns { path, messages, close }.
---@param reply_ack boolean|"close" - true: ack normally, "close": ack then immediately close
local function pipe_server(reply_ack)
  local path = ctx.artifact_root .. "/srv-" .. tostring(math.random(1e6)) .. ".sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local messages = {}
  server:listen(16, function()
    local client = uv.new_pipe(false)
    server:accept(client)
    local buffer = ""
    client:read_start(function(err, chunk)
      assert(not err, err)
      if not chunk then
        return
      end
      buffer = buffer .. chunk
      while true do
        local line, rest = buffer:match("^(.-)\n(.*)$")
        if not line then
          break
        end
        buffer = rest
        local decoded = vim.json.decode(line)
        table.insert(messages, decoded)
        if decoded.type == "submit" and reply_ack then
          client:write(vim.json.encode({ type = "ack" }) .. "\n")
          if reply_ack == "close" then
            client:close()
          end
        end
      end
    end)
  end)
  return {
    path = path,
    messages = messages,
    close = function()
      server:close()
    end,
  }
end

describe("pjollrig socket sink", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("sends hello + submit as JSONL and succeeds on ack", function()
    local server = pipe_server(true)
    local spec = require("pjollrig.sinks.socket").setup({})
    local record = {
      body = "needs a guard",
      project_root = ctx.root,
      uri = "file://" .. ctx.root .. "/src/a.lua",
      range = { start = { 4, 0 }, end_ = { 6, 0 } },
    }

    local got_ok, got_err
    spec.send({ record }, { socket = server.path, job = "job-1", label = "since-review" }, function(ok, err)
      got_ok, got_err = ok, err
    end)
    vim.wait(2000, function()
      return got_ok ~= nil
    end)
    server.close()

    assert.is_true(got_ok, got_err)
    assert.are.equal("hello", server.messages[1].type)
    assert.are.equal("job-1", server.messages[1].job)
    local submit = server.messages[2]
    assert.are.equal("submit", submit.type)
    assert.are.equal("since-review", submit.label)
    assert.are.equal(1, #submit.comments)
    assert.are.equal("src/a.lua", submit.comments[1].path)
    assert.are.equal(5, submit.comments[1].lnum)
    assert.are.equal(7, submit.comments[1].end_lnum)
    assert.are.equal("needs a guard", submit.comments[1].body)
  end)

  it("falls back to submit.json when nothing acks", function()
    local sock_dir = ctx.artifact_root .. "/nowhere"
    vim.fn.mkdir(sock_dir, "p")
    local spec = require("pjollrig.sinks.socket").setup({ ack_timeout_ms = 100 })
    local record = {
      body = "orphaned",
      uri = "file://" .. ctx.root .. "/x.lua",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    }

    local got_ok, got_err
    spec.send({ record }, { socket = sock_dir .. "/missing.sock" }, function(ok, err)
      got_ok, got_err = ok, err
    end)
    vim.wait(2000, function()
      return got_ok ~= nil
    end)

    assert.is_false(got_ok)
    assert.is_truthy(got_err:find("submit.json", 1, true))
    local fallback = vim.json.decode(table.concat(vim.fn.readfile(sock_dir .. "/submit.json"), "\n"))
    assert.are.equal("submit", fallback.type)
    assert.are.equal(1, #fallback.comments)
  end)

  it("validate rejects a missing ctx.socket", function()
    local spec = require("pjollrig.sinks.socket").setup({})
    local ok, err = spec.validate({})
    assert.is_false(ok)
    assert.is_truthy(err)
  end)

  it("is hidden from selection listing but dispatchable by name with ctx.socket", function()
    local sinks = require("pjollrig.sinks")
    sinks._reset()
    sinks.setup({ clipboard = false, github = false, cmux = false })

    -- Hidden from picker / single-sink auto-dispatch listing: without a
    -- review-supplied ctx.socket the sink can never validate interactively.
    assert.are.same({}, sinks.list())

    -- ...but a review-driven dispatch by name still reaches the sink.
    local server = pipe_server(true)
    local record = {
      body = "review-driven dispatch",
      project_root = ctx.root,
      uri = "file://" .. ctx.root .. "/src/b.lua",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    }

    local got_ok, got_err
    sinks.dispatch("socket", { record }, { socket = server.path, job = "job-2", label = "review" }, function(ok, err)
      got_ok, got_err = ok, err
    end)
    vim.wait(2000, function()
      return got_ok ~= nil
    end)
    server.close()

    assert.is_true(got_ok, got_err)
    assert.are.equal("hello", server.messages[1].type)
    assert.are.equal("submit", server.messages[2].type)
    assert.are.equal("src/b.lua", server.messages[2].comments[1].path)
  end)

  it("succeeds when server sends ack and immediately closes", function()
    local server = pipe_server("close")
    local spec = require("pjollrig.sinks.socket").setup({})
    local record = {
      body = "eof race test",
      uri = "file://" .. ctx.root .. "/test.lua",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    }

    local got_ok, got_err
    spec.send({ record }, { socket = server.path, job = "race-test" }, function(ok, err)
      got_ok, got_err = ok, err
    end)
    vim.wait(2000, function()
      return got_ok ~= nil
    end)
    server.close()

    assert.is_true(got_ok, got_err)
    -- No fallback file should be written on success
    local fallback_path = vim.fn.fnamemodify(server.path, ":h") .. "/submit.json"
    assert.are.equal(0, vim.fn.filereadable(fallback_path))
  end)
end)
