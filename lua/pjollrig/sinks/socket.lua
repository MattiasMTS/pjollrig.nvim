-- pjollrig.nvim: generic JSONL-over-unix-socket sink.
--
-- Sends the comment batch as structured JSON lines to a local pipe
-- (unix socket / named pipe) supplied via ctx.socket. Any consumer can
-- listen — a coding-agent extension, a script, `nc -U`. Pjollrig does
-- not know or care who is on the other side.
--
-- Protocol (one JSON object per \n-terminated line):
--   -> {"type":"hello","pid":<pid>,"job":"<ctx.job>"}
--   -> {"type":"submit","label":"<ctx.label>","comments":[...]}
--   <- {"type":"ack"}
--
-- If connect/write/ack fails, the submit payload is written to
-- `<dirname(socket)>/submit.json` so comments are never lost.

local M = {}

local uv = vim.uv

local function defaults()
  return {
    ack_timeout_ms = 2000,
    clear_on_success = true,
  }
end

local function to_comment(record)
  local uri_mod = require("pjollrig.uri")
  local path = uri_mod.to_path(record.uri) or tostring(record.uri or "")
  local root = record.project_root
  if root and path:sub(1, #root + 1) == root .. "/" then
    path = path:sub(#root + 2)
  end
  local start_row = record.range and record.range.start and record.range.start[1] or 0
  local end_row = record.range and record.range.end_ and record.range.end_[1] or start_row
  return {
    path = path,
    lnum = start_row + 1,
    end_lnum = end_row + 1,
    body = record.body or "",
    side = "working",
  }
end

local function payload(comments, ctx)
  return {
    type = "submit",
    label = ctx.label,
    comments = vim.tbl_map(to_comment, comments),
  }
end

---@param opts? {ack_timeout_ms?: number, clear_on_success?: boolean}
---@return table sink spec
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults(), opts or {})
  return {
    name = "socket",
    type = "integration",
    label = "socket (JSONL)",
    description = "send structured comments to a local unix socket",
    -- Only a review job supplies ctx.socket, so an interactive pick can
    -- never validate. Register (a review dispatches to "socket" by name
    -- with its session ctx) but keep the sink out of pickers, single-sink
    -- auto-dispatch, and completion. `is_available` would unregister it
    -- entirely and break the review-driven dispatch, hence `hidden`.
    hidden = true,
    clear_on_success = opts.clear_on_success,
    validate = function(ctx)
      if type(ctx.socket) ~= "string" or ctx.socket == "" then
        return false, "pjollrig: socket sink requires ctx.socket (pipe path)"
      end
      return true
    end,
    send = function(comments, ctx, cb)
      local submit = payload(comments, ctx)
      -- Pre-encode JSONL strings before entering uv callbacks for strict fast-event safety
      local hello = vim.json.encode({ type = "hello", pid = uv.os_getpid(), job = ctx.job }) .. "\n"
      local body = vim.json.encode(submit) .. "\n"

      local pipe = uv.new_pipe(false)
      local finished = false
      local timer = uv.new_timer()

      -- All vim.* API (fallback write, user callback) must run in vim.schedule
      -- to avoid E5560 in fast-event callbacks (timer/pipe). Pure libuv work
      -- (pipe, timer, string) stays in the uv context.
      local function finish(ok, err)
        if finished then
          return
        end
        finished = true
        timer:stop()
        timer:close()
        if not pipe:is_closing() then
          pipe:close()
        end

        vim.schedule(function()
          if not ok then
            local dir = vim.fn.fnamemodify(ctx.socket, ":h")
            local file = dir .. "/submit.json"
            local write_ok = pcall(vim.fn.writefile, { vim.json.encode(submit) }, file)
            err = tostring(err or "socket send failed")
              .. (write_ok and ("; comments saved to " .. file) or "; fallback write also failed")
          end
          cb(ok, ok and nil or err)
        end)
      end

      timer:start(opts.ack_timeout_ms, 0, function()
        finish(false, "pjollrig: socket sink timed out waiting for ack")
      end)

      pipe:connect(ctx.socket, function(connect_err)
        if connect_err then
          finish(false, "pjollrig: socket connect failed: " .. tostring(connect_err))
          return
        end
        local buffer = ""
        pipe:read_start(function(read_err, chunk)
          if read_err then
            finish(false, "pjollrig: socket read failed: " .. tostring(read_err))
            return
          end
          if not chunk then
            -- Schedule EOF handling to preserve order when ack+EOF arrive together
            vim.schedule(function()
              finish(false, "pjollrig: socket closed before ack")
            end)
            return
          end
          -- Pure string work in uv callback; JSON decode + ack check scheduled
          buffer = buffer .. chunk
          local line = buffer:match("^(.-)\n")
          if line then
            vim.schedule(function()
              local ok, decoded = pcall(vim.json.decode, line)
              if ok and type(decoded) == "table" and decoded.type == "ack" then
                finish(true)
              else
                finish(false, "pjollrig: unexpected socket reply: " .. line:sub(1, 120))
              end
            end)
          end
        end)
        pipe:write(hello .. body, function(write_err)
          if write_err then
            finish(false, "pjollrig: socket write failed: " .. tostring(write_err))
          end
        end)
      end)
    end,
    health = function()
      return { transport = "unix socket (vim.uv pipe)", protocol = "jsonl-v1" }
    end,
  }
end

return M
