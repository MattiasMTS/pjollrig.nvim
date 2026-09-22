-- pjollrig.nvim: tiny SQLite binding for the local event store.
--
-- Keep this deliberately small. The store needs only prepared
-- statements, transactions, WAL pragmas, and a couple of scalar queries.

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
  ffi.cdef([[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    typedef long long sqlite3_int64;
    typedef void (*sqlite3_destructor_type)(void*);

    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const char *sql, void*, void*, char **errmsg);
    void sqlite3_free(void*);
    const char *sqlite3_errmsg(sqlite3*);
    int sqlite3_busy_timeout(sqlite3*, int ms);

    int sqlite3_prepare_v2(sqlite3*, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_finalize(sqlite3_stmt *pStmt);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_reset(sqlite3_stmt*);

    int sqlite3_bind_null(sqlite3_stmt*, int);
    int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64);
    int sqlite3_bind_double(sqlite3_stmt*, int, double);
    int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, sqlite3_destructor_type);

    int sqlite3_column_count(sqlite3_stmt *pStmt);
    const char *sqlite3_column_name(sqlite3_stmt*, int N);
    int sqlite3_column_type(sqlite3_stmt*, int iCol);
    sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol);
    double sqlite3_column_double(sqlite3_stmt*, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
    int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
  ]])
end

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_NULL = 5

local lib
local lib_err

local function load_lib()
  if not ok_ffi then
    return nil, "LuaJIT ffi is unavailable"
  end
  if lib then
    return lib
  end
  local ok, loaded = pcall(ffi.load, "sqlite3")
  if ok then
    lib = loaded
    return lib
  end
  lib_err = tostring(loaded)
  return nil, lib_err
end

---@return boolean, string?
function M.available()
  local loaded, err = load_lib()
  return loaded ~= nil, err
end

local function errmsg(db)
  if not db then
    return "sqlite error"
  end
  local msg = load_lib().sqlite3_errmsg(db)
  return msg ~= nil and ffi.string(msg) or "sqlite error"
end

local DB = {}
DB.__index = DB

---@param path string
---@return table? db, string? err
function M.open(path)
  local C, err = load_lib()
  if not C then
    return nil, err
  end
  local pp = ffi.new("sqlite3*[1]")
  local rc = C.sqlite3_open(path, pp)
  if rc ~= SQLITE_OK then
    local db = pp[0]
    local msg = db ~= nil and errmsg(db) or "open failed"
    if db ~= nil then
      C.sqlite3_close(db)
    end
    return nil, msg
  end
  local self = setmetatable({ handle = pp[0], path = path }, DB)
  C.sqlite3_busy_timeout(self.handle, 1000)
  return self
end

function DB:close()
  if self.handle ~= nil then
    load_lib().sqlite3_close(self.handle)
    self.handle = nil
  end
end

---@param sql string
---@return boolean ok, string? err
function DB:exec(sql)
  local C = load_lib()
  local errp = ffi.new("char*[1]")
  local rc = C.sqlite3_exec(self.handle, sql, nil, nil, errp)
  if rc == SQLITE_OK then
    return true
  end
  local msg
  if errp[0] ~= nil then
    msg = ffi.string(errp[0])
    C.sqlite3_free(errp[0])
  else
    msg = errmsg(self.handle)
  end
  return false, msg
end

local function prepare(db, sql)
  local C = load_lib()
  local stmtp = ffi.new("sqlite3_stmt*[1]")
  local rc = C.sqlite3_prepare_v2(db.handle, sql, -1, stmtp, nil)
  if rc ~= SQLITE_OK then
    return nil, errmsg(db.handle)
  end
  return stmtp[0]
end

local SQLITE_TRANSIENT = ok_ffi and ffi.cast("sqlite3_destructor_type", -1) or nil

---Count of placeholders implied by `params`. `ipairs` stops at the first
---nil hole, so a NULL parameter (Lua nil) would truncate the bind list
---and leave later placeholders unbound. Determine the real length from
---an explicit `n`, an embedded `params.n`, or the highest numeric key
---(`table.maxn` on LuaJIT) so binding spans every slot.
---@param params table
---@param n integer?
---@return integer
local function param_count(params, n)
  if n then
    return n
  end
  if params.n then
    return params.n
  end
  if table.maxn then
    return table.maxn(params)
  end
  local max = 0
  for k in pairs(params) do
    if type(k) == "number" and k > max then
      max = k
    end
  end
  return max
end

local function bind(stmt, params, n)
  if not params then
    return true
  end
  local C = load_lib()
  local count = param_count(params, n)
  for i = 1, count do
    local value = params[i]
    local rc
    local t = type(value)
    if value == nil then
      rc = C.sqlite3_bind_null(stmt, i)
    elseif t == "number" then
      if value % 1 == 0 then
        rc = C.sqlite3_bind_int64(stmt, i, value)
      else
        rc = C.sqlite3_bind_double(stmt, i, value)
      end
    elseif t == "boolean" then
      rc = C.sqlite3_bind_int64(stmt, i, value and 1 or 0)
    else
      local s = tostring(value)
      rc = C.sqlite3_bind_text(stmt, i, s, #s, SQLITE_TRANSIENT)
    end
    if rc ~= SQLITE_OK then
      return false, "failed to bind parameter " .. tostring(i)
    end
  end
  return true
end

---@param sql string
---@param params any[]|nil
---@return boolean ok, string? err
function DB:execute(sql, params)
  local C = load_lib()
  local stmt, err = prepare(self, sql)
  if not stmt then
    return false, err
  end
  local ok, bind_err = bind(stmt, params)
  if not ok then
    C.sqlite3_finalize(stmt)
    return false, bind_err
  end
  local rc = C.sqlite3_step(stmt)
  local final_rc = C.sqlite3_finalize(stmt)
  if rc ~= SQLITE_DONE then
    return false, errmsg(self.handle)
  end
  if final_rc ~= SQLITE_OK then
    return false, errmsg(self.handle)
  end
  return true
end

local function column_value(stmt, index)
  local C = load_lib()
  local typ = C.sqlite3_column_type(stmt, index)
  if typ == SQLITE_NULL then
    return nil
  elseif typ == SQLITE_INTEGER then
    return tonumber(C.sqlite3_column_int64(stmt, index))
  elseif typ == SQLITE_FLOAT then
    return tonumber(C.sqlite3_column_double(stmt, index))
  elseif typ == SQLITE_TEXT then
    local bytes = C.sqlite3_column_bytes(stmt, index)
    local text = C.sqlite3_column_text(stmt, index)
    if text == nil then
      return ""
    end
    return ffi.string(text, bytes)
  end
  return nil
end

---@param sql string
---@param params any[]|nil
---@return table[]? rows, string? err
function DB:rows(sql, params)
  local C = load_lib()
  local stmt, err = prepare(self, sql)
  if not stmt then
    return nil, err
  end
  local ok, bind_err = bind(stmt, params)
  if not ok then
    C.sqlite3_finalize(stmt)
    return nil, bind_err
  end
  local out = {}
  while true do
    local rc = C.sqlite3_step(stmt)
    if rc == SQLITE_ROW then
      local row = {}
      local count = C.sqlite3_column_count(stmt)
      for i = 0, count - 1 do
        row[ffi.string(C.sqlite3_column_name(stmt, i))] = column_value(stmt, i)
      end
      table.insert(out, row)
    elseif rc == SQLITE_DONE then
      local final_rc = C.sqlite3_finalize(stmt)
      if final_rc ~= SQLITE_OK then
        return nil, errmsg(self.handle)
      end
      return out
    else
      local msg = errmsg(self.handle)
      C.sqlite3_finalize(stmt)
      return nil, msg
    end
  end
end

---@param sql string
---@param params any[]|nil
---@return table|nil row, string? err
function DB:row(sql, params)
  local rows, err = self:rows(sql, params)
  if not rows then
    return nil, err
  end
  return rows[1]
end

---@param fn fun(): boolean?, string?
---@return boolean ok, string? err
function DB:transaction(fn)
  local ok, err = self:exec("BEGIN IMMEDIATE")
  if not ok then
    return false, err
  end
  local call_ok, fn_ok, fn_err = pcall(fn)
  if not call_ok or fn_ok == false then
    self:exec("ROLLBACK")
    return false, call_ok and fn_err or tostring(fn_ok)
  end
  ok, err = self:exec("COMMIT")
  if not ok then
    self:exec("ROLLBACK")
    return false, err
  end
  return true
end

return M
