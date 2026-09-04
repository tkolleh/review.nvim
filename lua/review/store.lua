local M = {}

local storage = require("review.storage")
local duckdb = require("review.duckdb")

---@class Comment
---@field id string
---@field file string
---@field line number
---@field line_end? number
---@field side? "old"|"new"
---@field type "note"|"suggestion"|"issue"|"praise"
---@field text string
---@field author string
---@field color_dark? string DuckDB-computed hex, for `:set background=dark`; absent on rows predating this column
---@field color_light? string DuckDB-computed hex, for `:set background=light`; absent on rows predating this column
---@field lifecycle_state "submitted"|"resolved"
---@field created_at number

---@type table<string, Comment[]>
M.comments = {}

---@return string|nil
local function db_path()
  return storage.get_storage_path()
end

---@param comment Comment
local function cache_insert(comment)
  if not M.comments[comment.file] then
    M.comments[comment.file] = {}
  end
  table.insert(M.comments[comment.file], comment)
end

function M.reset()
  M.comments = {}
end

---@param row table decoded row from review_comments (see storage.lua's schema)
---@return Comment
local function row_to_comment(row)
  return {
    id = row.id,
    file = row.file_path,
    line = row.comment_scope == "file" and 0 or row.line_start,
    line_end = row.line_end,
    side = row.side or "new",
    type = row.comment_type,
    text = row.content,
    author = row.author,
    color_dark = row.color_dark,
    color_light = row.color_light,
    lifecycle_state = row.lifecycle_state,
    created_at = row.created_at,
  }
end

---Merges the db file into the in-memory cache (add/update/remove) so a
---concurrent external writer's (e.g. an agent's) comments become visible.
---review.nvim's own writes update the cache directly and skip this
---round-trip, since a write already knows its own result.
---@param callback? fun(ok: boolean, err: string|nil)
function M.sync_from_storage(callback)
  callback = callback or function() end
  local path = db_path()
  if not path then
    callback(false, "no storage path available (not in a git repo?)")
    return
  end

  storage.ensure_schema(path, function(ok, err)
    if not ok then
      callback(false, err)
      return
    end

    duckdb.query(path, "SELECT * FROM review_comments;", { readonly = true }, function(read_ok, result, read_err)
      if not read_ok then
        callback(false, read_err)
        return
      end

      local seen_ids = {}
      for _, row in ipairs(result) do
        seen_ids[row.id] = true
        local comment = row_to_comment(row)
        local existing = M.get(comment.id)
        if existing then
          for k, v in pairs(comment) do
            existing[k] = v
          end
        else
          cache_insert(comment)
        end
      end

      for file, comments in pairs(M.comments) do
        for i = #comments, 1, -1 do
          if not seen_ids[comments[i].id] then
            table.remove(comments, i)
          end
        end
        if #comments == 0 then
          M.comments[file] = nil
        end
      end

      callback(true, nil)
    end)
  end)
end

---Runs sql against the current session's db file, retrying on lock
---contention so independent writers (this process and e.g. an agent's)
---don't fail each other's writes.
---@param sql string
---@param callback fun(ok: boolean, result: table[]|nil, err: string|nil)
local function write(sql, callback)
  local path = db_path()
  if not path then
    callback(false, nil, "no storage path available (not in a git repo?)")
    return
  end

  storage.ensure_schema(path, function(ok, err)
    if not ok then
      callback(false, nil, err)
      return
    end

    duckdb.query_with_retry(path, sql, {
      max_retries = storage.config.write_contention_max_retries,
      backoff_ms = storage.config.write_contention_backoff_ms,
    }, callback)
  end)
end

---@param value string|number|nil
---@return string sql literal, including surrounding quotes for strings
local function literal(value)
  if value == nil then
    return "NULL"
  end
  if type(value) == "number" then
    return tostring(value)
  end
  return "'" .. duckdb.escape_string(value) .. "'"
end

---@param file string
---@param line number
---@param type "note"|"suggestion"|"issue"|"praise"
---@param text string
---@param line_end? number
---@param side? "old"|"new"
---@param author? string
---@param callback fun(comment: Comment|nil, err: string|nil)
function M.add(file, line, type, text, line_end, side, author, callback)
  local scope = line == 0 and "file" or "line"
  local resolved_side = side or "new"
  local resolved_line_end = (line_end and line_end ~= line) and line_end or nil
  local resolved_author = author or "user"

  local sql = string.format(
    [[INSERT INTO review_comments (comment_scope, file_path, line_start, line_end, side, comment_type, content, author)
      VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
      RETURNING id, created_at, color_dark, color_light;]],
    literal(scope),
    literal(file),
    scope == "file" and "NULL" or literal(line),
    literal(resolved_line_end),
    scope == "file" and "NULL" or literal(resolved_side),
    literal(type),
    literal(text),
    literal(resolved_author)
  )

  write(sql, function(ok, result, err)
    if not ok then
      callback(nil, err)
      return
    end

    local row = result[1]
    local comment = {
      id = row.id,
      file = file,
      line = line,
      line_end = resolved_line_end,
      side = resolved_side,
      type = type,
      text = text,
      author = resolved_author,
      color_dark = row.color_dark,
      color_light = row.color_light,
      lifecycle_state = "submitted",
      created_at = row.created_at,
    }
    cache_insert(comment)
    callback(comment, nil)
  end)
end

---@param id string
---@return Comment|nil
function M.get(id)
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      if comment.id == id then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param side? "old"|"new"
---@return Comment[]
function M.get_for_file(file, side)
  local comments = M.comments[file] or {}
  if not side then
    return comments
  end
  local filtered = {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 or (comment.side or "new") == side then
      table.insert(filtered, comment)
    end
  end
  return filtered
end

---@param file string
---@param author? string When given, scopes the match to this author so one
---author's "add file comment" can't silently edit another's
---@return Comment|nil
function M.get_file_comment(file, author)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 and (not author or comment.author == author) then
      return comment
    end
  end
  return nil
end

---@param file string
---@param line number
---@param side? "old"|"new"
---@return Comment|nil
function M.get_at_line(file, line, side)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    local line_end = comment.line_end or comment.line
    if line >= comment.line and line <= line_end then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param line number
---@param side? "old"|"new"
---@return Comment[]
function M.get_all_at_line(file, line, side)
  local comments = M.comments[file] or {}
  local at_line = {}
  for _, comment in ipairs(comments) do
    local line_end = comment.line_end or comment.line
    if line >= comment.line and line <= line_end then
      if not side or (comment.side or "new") == side then
        table.insert(at_line, comment)
      end
    end
  end
  return at_line
end

---@param file string
---@param start_line number
---@param end_line number
---@param side? "old"|"new"
---@return Comment|nil
function M.get_overlapping(file, start_line, end_line, side)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    local c_end = comment.line_end or comment.line
    if comment.line <= end_line and c_end >= start_line then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param id string
---@param expected_prior_content string
---@param new_content string
---@param new_type? "note"|"suggestion"|"issue"|"praise"
---@param callback fun(ok: boolean, err: string|nil)
function M.update(id, expected_prior_content, new_content, new_type, callback)
  local sql = string.format(
    [[UPDATE review_comments SET content = %s%s, updated_at = now()
      WHERE id = %s AND content = %s
      RETURNING id;]],
    literal(new_content),
    new_type and (", comment_type = " .. literal(new_type)) or "",
    literal(id),
    literal(expected_prior_content)
  )

  write(sql, function(ok, result, err)
    if not ok then
      callback(false, err)
      return
    end

    if #result == 0 then
      -- Zero rows means either no such id or a stale expected_prior_content;
      -- a cheap follow-up read disambiguates without slowing the common path.
      local path = db_path()
      duckdb.query(
        path,
        string.format("SELECT id FROM review_comments WHERE id = %s;", literal(id)),
        { readonly = true },
        function(select_ok, select_result)
          if select_ok and select_result and #select_result > 0 then
            callback(false, "stale")
          else
            callback(false, nil)
          end
        end
      )
      return
    end

    local comment = M.get(id)
    if comment then
      comment.text = new_content
      if new_type then
        comment.type = new_type
      end
    end
    callback(true, nil)
  end)
end

---@param id string
---@param expected_prior_content string
---@param callback fun(ok: boolean, err: string|nil)
function M.delete(id, expected_prior_content, callback)
  local sql = string.format(
    "DELETE FROM review_comments WHERE id = %s AND content = %s RETURNING id;",
    literal(id),
    literal(expected_prior_content)
  )

  write(sql, function(ok, result, err)
    if not ok then
      callback(false, err)
      return
    end

    if #result == 0 then
      local path = db_path()
      duckdb.query(
        path,
        string.format("SELECT id FROM review_comments WHERE id = %s;", literal(id)),
        { readonly = true },
        function(select_ok, select_result)
          if select_ok and select_result and #select_result > 0 then
            callback(false, "stale")
          else
            callback(false, nil)
          end
        end
      )
      return
    end

    for file, comments in pairs(M.comments) do
      for i, comment in ipairs(comments) do
        if comment.id == id then
          table.remove(comments, i)
          if #comments == 0 then
            M.comments[file] = nil
          end
          break
        end
      end
    end
    callback(true, nil)
  end)
end

---@param id string
---@param callback fun(ok: boolean, err: string|nil)
function M.resolve(id, callback)
  local sql = string.format(
    [[UPDATE review_comments SET lifecycle_state = 'resolved', updated_at = now()
      WHERE id = %s AND lifecycle_state = 'submitted'
      RETURNING id;]],
    literal(id)
  )

  write(sql, function(ok, result, err)
    if not ok then
      callback(false, err)
      return
    end

    if #result == 0 then
      callback(false, nil)
      return
    end

    local comment = M.get(id)
    if comment then
      comment.lifecycle_state = "resolved"
    end
    callback(true, nil)
  end)
end

---@param file string
---@param line number
---@param author string
---@return Comment|nil, boolean
function M.select_ambiguous_comment(file, line, author)
  local candidates = M.get_all_at_line(file, line)
  if #candidates == 0 then
    return nil, false
  end

  local own = {}
  for _, comment in ipairs(candidates) do
    if comment.author == author then
      table.insert(own, comment)
    end
  end

  if #own == 1 then
    return own[1], false
  end

  return nil, true
end

---@return Comment[]
function M.get_all()
  local all = {}
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      table.insert(all, comment)
    end
  end
  table.sort(all, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return all
end

---@return table<string, Comment[]>
function M.get_all_by_file()
  return M.comments
end

---@return number
function M.count()
  local count = 0
  for _, comments in pairs(M.comments) do
    count = count + #comments
  end
  return count
end

function M.clear()
  M.reset()
  storage.clear()
  storage.clear_revisions()
end

return M
