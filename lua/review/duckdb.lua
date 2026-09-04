local M = {}

---Escapes a Lua string for embedding as a single-quoted SQL literal.
---@param s string
---@return string
function M.escape_string(s)
  return (s:gsub("'", "''"))
end

---@param stderr string|nil
---@return boolean
local function is_lock_contention(stderr)
  return stderr ~= nil and stderr:find("Conflicting lock is held", 1, true) ~= nil
end

---Runs a single short-lived `duckdb <db_path> -c "<sql>"` subprocess call.
---Never holds the connection open beyond this one invocation, per
---specs/review-storage.allium's CommentAuthor @guidance (CLI-only, no
---libduckdb/FFI, no long-lived connection).
---@param db_path string
---@param sql string
---@param opts? { readonly?: boolean, timeout_ms?: number }
---@param callback fun(ok: boolean, result: table[]|nil, err: string|nil)
function M.query(db_path, sql, opts, callback)
  opts = opts or {}

  local cmd = { "duckdb", db_path, "-json" }
  if opts.readonly then
    table.insert(cmd, "-readonly")
  end
  table.insert(cmd, "-c")
  table.insert(cmd, sql)

  vim.system(cmd, { text = true, timeout = opts.timeout_ms or 5000 }, function(completed)
    vim.schedule(function()
      if completed.code ~= 0 then
        callback(false, nil, completed.stderr)
        return
      end

      local stdout = completed.stdout or ""
      if stdout:match("^%s*$") then
        callback(true, {}, nil)
        return
      end

      local ok, decoded = pcall(vim.json.decode, stdout, { luanil = { object = true } })
      if not ok then
        callback(false, nil, "failed to decode duckdb JSON output: " .. stdout)
        return
      end

      callback(true, decoded, nil)
    end)
  end)
end

---Same as M.query, but automatically retries on DuckDB's "conflicting lock"
---IO Error (storage-access contention, specs/review-storage.allium's
---IndependentWritersDoNotCollide @guidance) up to
---config.write_contention_max_retries times, waiting
---config.write_contention_backoff_ms between attempts. Any other failure
---(including a genuine semantic rejection) is forwarded immediately,
---unretried.
---@param db_path string
---@param sql string
---@param opts? { readonly?: boolean, timeout_ms?: number, max_retries?: number, backoff_ms?: number }
---@param callback fun(ok: boolean, result: table[]|nil, err: string|nil)
function M.query_with_retry(db_path, sql, opts, callback)
  opts = opts or {}
  local max_retries = opts.max_retries or 0
  local backoff_ms = opts.backoff_ms or 0

  local function attempt(retries_left)
    M.query(db_path, sql, opts, function(ok, result, err)
      if ok or retries_left <= 0 or not is_lock_contention(err) then
        callback(ok, result, err)
        return
      end

      vim.defer_fn(function()
        attempt(retries_left - 1)
      end, backoff_ms)
    end)
  end

  attempt(max_retries)
end

return M
