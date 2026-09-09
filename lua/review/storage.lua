local M = {}

local duckdb = require("review.duckdb")

-- Overridable so concurrent test processes each get an isolated storage
-- dir; sharing the real XDG path would hit DuckDB's single-writer lock.
local data_dir = os.getenv("REVIEW_NVIM_TEST_DATA_DIR") or (vim.fn.stdpath("data") .. "/review")

---@type {rev1: string, rev2: string}|nil
local current_revisions = nil

function M.set_revisions(rev1, rev2)
  current_revisions = (rev1 and rev2) and { rev1 = rev1, rev2 = rev2 } or nil
end

function M.clear_revisions()
  current_revisions = nil
end

---@return string|nil
local function get_git_root()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      return result:gsub("%s+$", "")
    end
  end
  return nil
end

---@return string|nil
local function get_git_branch()
  local handle = io.popen("git rev-parse --abbrev-ref HEAD 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      return result:gsub("%s+$", "")
    end
  end
  return nil
end

---@param str string
---@return string
local function hash(str)
  local h = 0
  for i = 1, #str do
    h = ((h * 31) + string.byte(str, i)) % 2147483647
  end
  return string.format("%x", h)
end

---@param rev string
---@return string
local function short_rev(rev)
  return rev:gsub("%^$", ""):sub(1, 8)
end

---@return table
function M.current_session()
  local now = os.time()
  local session = {
    project_root = get_git_root(),
    created_at = now,
    updated_at = now,
  }

  if current_revisions then
    session.scope = "revision_range"
    session.rev1 = short_rev(current_revisions.rev1)
    session.rev2 = short_rev(current_revisions.rev2)
  else
    session.scope = "branch"
    session.branch_name = get_git_branch()
  end

  return session
end

---@param _session table
---@param scope "review"|"file"|"line"
---@return table
function M.session_comments(_session, scope)
  if scope == "review" then
    return {}
  end

  local store = require("review.store")
  local all = store.get_all()
  local filtered = {}
  for _, comment in ipairs(all) do
    local is_file_scope = comment.line == 0
    if (scope == "file" and is_file_scope) or (scope == "line" and not is_file_scope) then
      table.insert(filtered, comment)
    end
  end
  return filtered
end

---@return string|nil
function M.get_storage_path()
  local git_root = get_git_root()
  if not git_root then
    return nil
  end

  local project_hash = hash(git_root)

  -- pcall since mkdir errors if the directory already exists
  pcall(vim.fn.mkdir, data_dir, "p")

  if current_revisions then
    local r1 = short_rev(current_revisions.rev1)
    local r2 = short_rev(current_revisions.rev2)
    return string.format("%s/%s-%s_%s.duckdb", data_dir, project_hash, r1, r2)
  end

  local branch = get_git_branch()
  if not branch then
    return nil
  end

  local safe_branch = branch:gsub("[^%w%-_]", "_")
  return string.format("%s/%s-%s.duckdb", data_dir, project_hash, safe_branch)
end

-- Same hash bucket in both palettes so an author keeps one hue identity
-- across `:set background`; both are WCAG AA-contrast validated.
-- Mirrored in skills/review-nvim/main.py's SCHEMA_SQL -- keep both in sync.
local AUTHOR_PALETTE_DARK = {
  "#89b4fa", "#f38ba8", "#a6e3a1", "#fab387",
  "#cba6f7", "#94e2d5", "#f9e2af", "#eba0ac",
}
local AUTHOR_PALETTE_LIGHT = {
  "#0a5de3", "#d3144a", "#2a7723", "#b14807",
  "#8733ed", "#207567", "#825c0a", "#cc2944",
}

---Builds a `list_extract(...)` SQL expression that deterministically maps
---the `author` column into one entry of palette via DuckDB's own hash().
---@param palette string[]
---@return string sql_expr
local function author_color_expr(palette)
  local quoted = {}
  for i, hex in ipairs(palette) do
    quoted[i] = "'" .. hex .. "'"
  end
  return string.format(
    "list_extract([%s], CAST(hash(author) %% %d AS BIGINT) + 1)",
    table.concat(quoted, ", "),
    #palette
  )
end

-- Both CREATE TABLEs batched into a single -c invocation so schema bootstrap
-- is one short-lived open-write-close subprocess call, not two.
--
-- color_dark/color_light are GENERATED ALWAYS AS columns, computed by DuckDB
-- at insert time -- not retrofittable onto an existing table (DuckDB rejects
-- `ALTER TABLE ... ADD COLUMN ... GENERATED`), so a pre-existing .duckdb file
-- predating this column won't gain it. Comments are disposable, and
-- `:Review clear` already resets a session's storage file on demand.
--
-- deleted_at is a plain (non-generated) column, so unlike color_dark/light
-- above it CAN reach a pre-existing .duckdb file: `ALTER TABLE ... ADD
-- COLUMN IF NOT EXISTS` is idempotent for a plain column (verified against
-- DuckDB 1.5.5 directly -- its docs don't state this either way), so it runs
-- unconditionally alongside the CREATE TABLEs on every bootstrap.
local SCHEMA_SQL = string.format([[
CREATE TABLE IF NOT EXISTS review_sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_root    VARCHAR NOT NULL,
    branch_name     VARCHAR,
    rev1            VARCHAR,
    rev2            VARCHAR,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS review_comments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    comment_scope   VARCHAR NOT NULL CHECK (comment_scope IN ('review', 'file', 'line')),
    file_path       VARCHAR,
    line_start      INTEGER,
    line_end        INTEGER,
    side            VARCHAR CHECK (side IN ('old', 'new')),
    comment_type    VARCHAR NOT NULL CHECK (comment_type IN ('note', 'suggestion', 'issue', 'praise')),
    content         VARCHAR NOT NULL,
    author          VARCHAR NOT NULL DEFAULT 'user',
    color_dark      VARCHAR GENERATED ALWAYS AS (%s),
    color_light     VARCHAR GENERATED ALWAYS AS (%s),
    lifecycle_state VARCHAR NOT NULL DEFAULT 'submitted',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comments_file ON review_comments(file_path);
ALTER TABLE review_comments ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
]], author_color_expr(AUTHOR_PALETTE_DARK), author_color_expr(AUTHOR_PALETTE_LIGHT))

---@type table<string, boolean>
local schema_ready = {}

---Ensures review_sessions/review_comments exist in db_path, running the DDL
---at most once per db_path per Neovim process. Every store.lua write funnels
---through this before its own statement.
---@param db_path string
---@param callback fun(ok: boolean, err: string|nil)
function M.ensure_schema(db_path, callback)
  if schema_ready[db_path] then
    callback(true, nil)
    return
  end

  duckdb.query(db_path, SCHEMA_SQL, nil, function(ok, _, err)
    if ok then
      schema_ready[db_path] = true
    end
    callback(ok, err)
  end)
end

local EXPIRY_SECONDS = 7 * 24 * 60 * 60

M.config = {
  session_retention_seconds = EXPIRY_SECONDS,
  write_contention_max_retries = 3,
  write_contention_backoff_ms = 50,
}

-- Sweeps *.duckdb files older than the retention window, using file mtime
-- rather than tracking session activity -- simple and good enough since
-- storage files are disposable per-branch caches, not durable records.
---@return number removed count of files removed
function M.cleanup_expired_now()
  local files = vim.fn.glob(data_dir .. "/*.duckdb", false, true)
  local now = os.time()
  local removed = 0
  for _, filepath in ipairs(files) do
    local mtime = vim.fn.getftime(filepath)
    if mtime > 0 and (now - mtime) > M.config.session_retention_seconds then
      os.remove(filepath)
      schema_ready[filepath] = nil
      removed = removed + 1
    end
  end
  return removed
end

-- Row-level counterpart to cleanup_expired_now: hard-deletes comments
-- store.lua's M.clear_comments soft-deleted (stamped deleted_at) more than
-- session_retention_seconds ago, across every known storage file. Files
-- cleanup_expired_now already removed above are simply absent from this
-- glob re-run, so there's no wasted work sweeping a file about to be gone.
---@param callback fun(removed: number) total rows hard-deleted, across all files
function M.hard_delete_expired_comments_now(callback)
  local files = vim.fn.glob(data_dir .. "/*.duckdb", false, true)
  if #files == 0 then
    callback(0)
    return
  end

  local sql = string.format(
    "DELETE FROM review_comments WHERE deleted_at IS NOT NULL AND deleted_at <= now() - INTERVAL '%d seconds' RETURNING id;",
    M.config.session_retention_seconds
  )

  local remaining = #files
  local total = 0
  for _, filepath in ipairs(files) do
    duckdb.query(filepath, sql, nil, function(ok, result)
      if ok and result then
        total = total + #result
      end
      remaining = remaining - 1
      if remaining == 0 then
        callback(total)
      end
    end)
  end
end

local cleanup_done = false

-- Wires both retention sweeps together, deferred so it never delays
-- startup. Neither sweep was reachable before this (cleanup_expired_now had
-- no caller anywhere in the plugin -- a dormant bug, not a deliberate
-- opt-in), so this is a real behavioural change: existing storage files
-- already past the retention window get swept on first load after
-- upgrading. Notifying what was removed keeps that from being silent.
function M.cleanup_expired()
  if cleanup_done then
    return
  end
  cleanup_done = true

  vim.defer_fn(function()
    local removed_sessions = M.cleanup_expired_now()
    M.hard_delete_expired_comments_now(function(removed_comments)
      local parts = {}
      if removed_sessions > 0 then
        table.insert(parts, string.format("%d expired session(s)", removed_sessions))
      end
      if removed_comments > 0 then
        table.insert(parts, string.format("%d expired comment(s)", removed_comments))
      end
      if #parts > 0 then
        vim.notify(
          "review.nvim: removed " .. table.concat(parts, ", "),
          vim.log.levels.INFO,
          { title = "review.nvim" }
        )
      end
    end)
  end, 0)
end

function M.clear()
  local path = M.get_storage_path()
  if path then
    os.remove(path)
    schema_ready[path] = nil
  end
end

return M
