-- pjollrig.nvim: shared sink helpers.
--
-- Integration authors can use these helpers to keep formatting and
-- command execution consistent with bundled sinks.
--
-- Stable sink-author surface (see ARCHITECTURE.md "Sinks"):
--   relative_path, line_span, location            comment geometry
--   format_markdown_review, wrap_text, format_line payload formatting
--   executable, system, system_async               command execution
-- Everything else in this file is a private implementation detail.

local M = {}

---Compare a live comment with a send-time snapshot to decide whether
---the delivered content is still what the user has. Ignores:
---  - the sink's delivery `marker` (persisting it bumps nothing the user
---    wrote),
---  - `updated_at` (bookkeeping), and
---  - `range`: async sinks ack long after dispatch, and position sync
---    rewrites `record.range` as the file moves under the anchor. That is
---    drift, not an edit, so it must not block a `clear_on_success`
---    delete or a sent-marker stamp.
---A body/uri/resolved/meta change made while the sink was busy still
---counts as a real edit and keeps the record.
function M.same_record(current, snapshot, marker)
  if not current or not snapshot then
    return false
  end
  local function comparable(record)
    local copy = vim.tbl_extend("force", {}, record)
    copy.updated_at = nil
    copy.range = nil
    if marker and type(copy.meta) == "table" then
      copy.meta = vim.tbl_extend("force", {}, copy.meta)
      copy.meta[marker] = nil
      if next(copy.meta) == nil then
        copy.meta = nil
      end
    end
    return copy
  end
  return vim.deep_equal(comparable(current), comparable(snapshot))
end

-- Split on LF keeping blank lines (comment bodies and pre/post text are
-- prose; blank lines are content). Kept local so sinks/helpers stays
-- self-contained for third-party consumers — do not fold into
-- pjollrig.str.split_lines.
local function split_lines_keep_blanks(text)
  return vim.split(tostring(text or ""), "\n", { plain = true })
end

local function text_block(value)
  if type(value) ~= "string" then
    return nil
  end
  local text = vim.trim(value)
  return text ~= "" and text or nil
end

local function append_block(parts, text)
  text = text_block(text)
  if not text then
    return
  end
  for _, line in ipairs(split_lines_keep_blanks(text)) do
    table.insert(parts, line)
  end
  table.insert(parts, "")
end

local function join_blocks(parts)
  while #parts > 0 and parts[#parts] == "" do
    table.remove(parts)
  end
  return table.concat(parts, "\n")
end

local function normalize_path(path)
  return (tostring(path or ""):gsub("\\", "/"):gsub("/+", "/"):gsub("/$", ""))
end

local function relpath(root, path)
  root = normalize_path(root)
  path = normalize_path(path)
  if root == "" or path == "" then
    return nil
  end
  if path == root then
    return "."
  end
  local prefix = root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return nil
end

local function uri_to_path(uri)
  local ok, uri_mod = pcall(require, "pjollrig.uri")
  if not ok then
    return nil
  end
  return uri_mod.to_path(uri)
end

local function inferred_root(comment)
  if comment.project_root then
    return comment.project_root
  end
  local ok, uri_mod = pcall(require, "pjollrig.uri")
  if not ok then
    return nil
  end
  local parts = uri_mod.codediff_parts(comment.uri)
  return parts and parts.git_root or nil
end

---Return the project-relative path for a comment, or nil when the
---comment's URI cannot be resolved against a project root (session-scope
---temp buffers, files outside the root, unparseable URIs).
---@param comment table
---@return string|nil
function M.relative_path(comment)
  local abs = uri_to_path(comment.uri)
  local root = inferred_root(comment)
  if not (abs and root) then
    return nil
  end
  return relpath(root, abs)
end

---Return an absolute or project-relative path for a comment.
---@param comment table
---@return string
local function display_path(comment)
  local rel = M.relative_path(comment)
  if rel then
    return rel
  end
  return uri_to_path(comment.uri) or comment.uri or "?"
end

---Return the 1-indexed start and end lines for a comment.
---@param comment table
---@return integer start_lnum, integer end_lnum
function M.line_span(comment)
  local range = comment.range or {}
  local start = range.start or { 0, 0 }
  local finish = range["end_"] or start
  local s = (start[1] or 0) + 1
  local e = (finish[1] or start[1] or 0) + 1
  return s, e
end

---Return a 1-indexed display range for a comment.
---@param comment table
---@return string
local function display_range(comment)
  local s, e = M.line_span(comment)
  return e ~= s and (s .. "-" .. e) or tostring(s)
end

---Return `path:range` for a comment (1-indexed, project-relative when
---resolvable). The primitive `format_line` and the markdown headings are
---built on; useful for custom `format` implementations.
---@param comment table
---@return string
function M.location(comment)
  return ("%s:%s"):format(display_path(comment), display_range(comment))
end

---Format comments as a markdown review payload suitable for agents.
---@param comments table[]
---@param opts? {title?: string, pre_text?: string, post_text?: string}
---@return string
function M.format_markdown_review(comments, opts)
  opts = opts or {}
  local title = opts.title or "Pjollrig review"
  local parts = {
    ("%s (%d comment%s):"):format(title, #comments, #comments == 1 and "" or "s"),
    "",
  }
  append_block(parts, opts.pre_text)
  for index, comment in ipairs(comments) do
    table.insert(parts, ("## M%d %s"):format(index, M.location(comment)))
    for _, line in ipairs(split_lines_keep_blanks(comment.body)) do
      table.insert(parts, line)
    end
    table.insert(parts, "")
  end
  append_block(parts, opts.post_text)
  return join_blocks(parts)
end

---Wrap an already formatted text payload with optional sink pre/post text.
---@param text string
---@param opts? {pre_text?: string, post_text?: string}
---@return string
function M.wrap_text(text, opts)
  opts = opts or {}
  local parts = {}
  append_block(parts, opts.pre_text)
  append_block(parts, text)
  append_block(parts, opts.post_text)
  return join_blocks(parts)
end

---Format one comment as a compact single line.
---@param comment table
---@return string
function M.format_line(comment)
  return ("%s: %s"):format(M.location(comment), comment.body or "")
end

---Return true when an executable exists.
---@param command string
---@return boolean
function M.executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

---Run a command and return a normalized result table.
---@param argv string[]
---@param opts? table
---@return {code: integer, stdout: string, stderr: string}
function M.system(argv, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  local result = vim.system(argv, opts):wait()
  return {
    code = result.code or 0,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

---Run a command asynchronously without blocking the UI. The callback
---receives the same normalized result table as `M.system` and is invoked
---via `vim.schedule` (vim.system's on_exit fires in a fast-event
---context), so it may safely touch the vim API and `vim.notify`.
---@param argv string[]
---@param opts? table
---@param cb fun(result: {code: integer, stdout: string, stderr: string})
function M.system_async(argv, opts, cb)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  vim.system(argv, opts, function(result)
    vim.schedule(function()
      cb({
        code = result.code or 0,
        stdout = result.stdout or "",
        stderr = result.stderr or "",
      })
    end)
  end)
end

return M
