local M = {}

local duckdb = require("review.duckdb")

-- REVIEW_NVIM_TEST_DATA_DIR lets the test suite isolate each spec-file
-- subprocess's storage from the real XDG path (PlenaryBustedDirectory runs
-- spec files as separate concurrent `nvim --headless` processes, per
-- plenary's test_harness.lua; without this, they all race on the same
-- real ~/.local/share/nvim/review/<hash>-<branch>.duckdb file, which under
-- DuckDB's single-writer-excludes-everyone locking model would hard-fail
-- with a "Conflicting lock" IO Error rather than silently interleaving).
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

  -- Ensure directory exists (pcall to suppress error if exists)
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

-- Schema DDL, mirroring docs/research/duckdb-storage-backend.md SS2. Batched
-- into a single -c invocation so schema bootstrap is one short-lived
-- open-write-close subprocess call, not three.
local SCHEMA_SQL = [[
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
    lifecycle_state VARCHAR NOT NULL DEFAULT 'submitted',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comments_file ON review_comments(file_path);
]]

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

-- Sweeps *.duckdb files older than the retention window, same file-mtime
-- based semantics as the prior JSON design (deliberately unchanged scope --
-- see specs/review-storage.allium's open question on session_retention,
-- inherited as-is).
function M.cleanup_expired_now()
  local files = vim.fn.glob(data_dir .. "/*.duckdb", false, true)
  local now = os.time()
  for _, filepath in ipairs(files) do
    local mtime = vim.fn.getftime(filepath)
    if mtime > 0 and (now - mtime) > M.config.session_retention_seconds then
      os.remove(filepath)
      schema_ready[filepath] = nil
    end
  end
end

local cleanup_done = false

function M.cleanup_expired()
  if cleanup_done then
    return
  end
  cleanup_done = true

  vim.defer_fn(function()
    M.cleanup_expired_now()
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
