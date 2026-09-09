local storage = require("review.storage")

describe("review.storage", function()
  after_each(function()
    storage.clear_revisions()
  end)

  describe("get_storage_path", function()
    it("returns branch-scoped path when no revisions set", function()
      storage.clear_revisions()
      local path = storage.get_storage_path()
      assert.is_not_nil(path)
      assert.is_nil(path:match("_"))
      assert.truthy(path:match("%.duckdb$"))
    end)

    it("returns revision-scoped path when revisions are set", function()
      storage.set_revisions("abc12345def^", "fef98765abc")
      local path = storage.get_storage_path()
      assert.is_not_nil(path)
      assert.truthy(path:match("abc12345_fef98765%.duckdb$"))
    end)

    it("strips trailing ^ from revision in filename", function()
      storage.set_revisions("abc12345^", "def67890")
      local path = storage.get_storage_path()
      assert.truthy(path:match("abc12345_def67890%.duckdb$"))
    end)

    it("truncates long revisions to 8 chars", function()
      storage.set_revisions("abcdef1234567890^", "1234567890abcdef")
      local path = storage.get_storage_path()
      assert.truthy(path:match("abcdef12_12345678%.duckdb$"))
    end)

    it("sanitizes ref-name revisions so '/' can't split the path into nested directories", function()
      -- Regression: a ref like "origin/main" (not a SHA) truncated to 8
      -- chars was "origin/m", and that literal "/" survived into the
      -- filename, splitting it into non-existent nested directories that
      -- DuckDB then failed to open.
      storage.set_revisions("origin/main", "origin/main")
      local path = storage.get_storage_path()
      -- The filename segment (after the last "/") must be exactly this --
      -- no "/" fell through into it as an extra path separator.
      assert.truthy(path:match("/[^/]-origin_m_origin_m%.duckdb$"))
    end)

    it("returns branch path after clearing revisions", function()
      storage.set_revisions("abc12345^", "def67890")
      storage.clear_revisions()
      local path = storage.get_storage_path()
      assert.is_not_nil(path)
      -- Should not contain revision separator
      assert.is_nil(path:match("abc12345"))
    end)
  end)

  -- Generated from specs/review-storage.allium. Spec-first: storage.lua has
  -- no session-object accessor today, only path derivation. These describe
  -- the intended ReviewSession API and are expected to fail until that
  -- implementation work lands. Obligation ids reference
  -- `allium plan specs/review-storage.allium`.
  describe("current_session (entity-fields.ReviewSession, sum-type-variant.*)", function()
    after_each(function()
      storage.clear_revisions()
    end)

    it("returns a Branch-scoped session when no revisions are set", function()
      storage.clear_revisions()
      local session = storage.current_session()

      assert.is_not_nil(session.project_root)
      assert.is_not_nil(session.created_at)
      assert.is_not_nil(session.updated_at)
      assert.equals("branch", session.scope)
      assert.is_not_nil(session.branch_name)
    end)

    it("returns a RevisionRange-scoped session when revisions are set", function()
      storage.set_revisions("abc12345^", "def67890")
      local session = storage.current_session()

      assert.equals("revision_range", session.scope)
      assert.equals("abc12345", session.rev1)
      assert.equals("def67890", session.rev2)
    end)
  end)

  -- entity-relationship.ReviewSession.comments, projection.ReviewSession.*:
  -- review/file/line projections filter a session's comments by scope
  -- (specs/review-storage.allium ReviewSession.review_comments/
  -- file_comments/line_comments).
  describe("session_comments projections", function()
    local store = require("review.store")

    before_each(function()
      store.clear()
    end)

    local function add_and_wait(file, line, type, text)
      local done = false
      store.add(file, line, type, text, nil, nil, nil, function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
      assert.is_true(done, "store.add callback did not fire within timeout")
    end

    it("review_comments contains only review-scoped comments", function()
      add_and_wait("file.lua", 0, "note", "file-level")
      add_and_wait("file.lua", 10, "note", "line-level")

      local session = storage.current_session()
      local review_comments = storage.session_comments(session, "review")

      assert.equals(0, #review_comments)
    end)

    it("file_comments contains only file-scoped comments", function()
      add_and_wait("file.lua", 0, "note", "file-level")
      add_and_wait("file.lua", 10, "note", "line-level")

      local session = storage.current_session()
      local file_comments = storage.session_comments(session, "file")

      assert.equals(1, #file_comments)
      assert.equals("file-level", file_comments[1].text)
    end)

    it("line_comments contains only line-scoped comments", function()
      add_and_wait("file.lua", 0, "note", "file-level")
      add_and_wait("file.lua", 10, "note", "line-level")

      local session = storage.current_session()
      local line_comments = storage.session_comments(session, "line")

      assert.equals(1, #line_comments)
      assert.equals("line-level", line_comments[1].text)
    end)
  end)

  -- invariant.SessionScopeIsolatesComments: comments from a different
  -- branch/revision-range session are never visible when scoped to this
  -- session (project CLAUDE.md; agent-comment-authoring.md SS1).
  describe("session scope isolation (SessionScopeIsolatesComments)", function()
    it("does not surface a revision-range session's comments under a differently-scoped session", function()
      local store = require("review.store")
      store.clear()

      storage.clear_revisions()
      local branch_session = storage.current_session()

      storage.set_revisions("abc12345^", "def67890")
      local revision_session = storage.current_session()

      assert.are_not.same(branch_session, revision_session)
    end)
  end)

  -- config-default.session_retention, .write_contention_max_retries,
  -- .write_contention_backoff: declared defaults from specs/review-storage.allium.
  describe("config defaults", function()
    it("session_retention defaults to 7 days", function()
      assert.equals(7 * 24 * 60 * 60, storage.config.session_retention_seconds)
    end)

    it("write_contention_max_retries defaults to 3", function()
      assert.equals(3, storage.config.write_contention_max_retries)
    end)

    it("write_contention_backoff defaults to 50 milliseconds", function()
      assert.equals(50, storage.config.write_contention_backoff_ms)
    end)
  end)

  -- rule-success.ExpiredSessionsAreRemoved: a session whose updated_at is
  -- older than session_retention is removed, along with its comments.
  -- Mirrors today's storage.lua cleanup_expired/EXPIRY_SECONDS behavior;
  -- this obligation is already covered by that existing, working mechanism.
  -- Uses review.duckdb directly as a fixture (not store.lua/storage.save --
  -- those don't exist as synchronous JSON round-trips anymore) to create a
  -- real .duckdb file to backdate and sweep.
  describe("expired sessions are removed (ExpiredSessionsAreRemoved)", function()
    local duckdb = require("review.duckdb")

    before_each(function()
      require("review.store").clear()
    end)

    local function await(fn)
      local done = false
      fn(function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
      assert.is_true(done, "callback did not fire within timeout")
    end

    it("removes a session file older than the retention window", function()
      local path = storage.get_storage_path()
      await(function(done)
        storage.ensure_schema(path, function()
          duckdb.query(path, "INSERT INTO review_comments (comment_scope, content) VALUES ('file', 'old');", nil, done)
        end)
      end)

      -- Backdate the file past the retention window (no vim.fn.setftime
      -- exists; shell out to `touch`, matching storage.lua's own precedent
      -- of shelling out for git info via io.popen).
      local old_time = os.time() - (8 * 24 * 60 * 60)
      os.execute(string.format("touch -t %s %s", os.date("%Y%m%d%H%M.%S", old_time), vim.fn.shellescape(path)))

      assert.equals(1, storage.cleanup_expired_now())
      assert.equals(0, vim.fn.filereadable(path))
    end)

    it("keeps a session file within the retention window", function()
      local path = storage.get_storage_path()
      await(function(done)
        storage.ensure_schema(path, function()
          duckdb.query(path, "INSERT INTO review_comments (comment_scope, content) VALUES ('file', 'fresh');", nil, done)
        end)
      end)

      assert.equals(0, storage.cleanup_expired_now())
      assert.equals(1, vim.fn.filereadable(path))
    end)
  end)

  -- rule-success.ClearedCommentsAreHardDeleted: a comment soft-deleted (via
  -- store.lua's M.clear_comments, which stamps deleted_at) more than
  -- session_retention_seconds ago is permanently removed; one within the
  -- window is left alone so it stays recoverable via direct storage access.
  describe("row-level hard-delete sweep (ClearedCommentsAreHardDeleted)", function()
    local duckdb = require("review.duckdb")

    before_each(function()
      require("review.store").clear()
    end)

    local function await(fn)
      local done = false
      fn(function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
      assert.is_true(done, "callback did not fire within timeout")
    end

    local function hard_delete_now()
      local removed
      await(function(done)
        storage.hard_delete_expired_comments_now(function(count)
          removed = count
          done()
        end)
      end)
      return removed
    end

    ---Mirrors comments_spec.lua's await, needed here to capture a
    ---duckdb.query callback's result rather than just its completion.
    local function await_result(fn)
      local done = false
      local results, n
      fn(function(...)
        results = { ... }
        n = select("#", ...)
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
      assert.is_true(done, "callback did not fire within timeout")
      return unpack(results, 1, n)
    end

    it("removes a comment soft-deleted past the retention window", function()
      local path = storage.get_storage_path()
      await(function(done)
        storage.ensure_schema(path, function()
          duckdb.query(
            path,
            [[INSERT INTO review_comments (comment_scope, comment_type, content, deleted_at)
              VALUES ('file', 'note', 'cleared long ago', now() - INTERVAL '8 days');]],
            nil,
            done
          )
        end)
      end)

      assert.equals(1, hard_delete_now())

      local _, remaining = await_result(function(done)
        duckdb.query(path, "SELECT id FROM review_comments;", { readonly = true }, done)
      end)
      assert.equals(0, #remaining)
    end)

    it("keeps a comment soft-deleted within the retention window", function()
      local path = storage.get_storage_path()
      await(function(done)
        storage.ensure_schema(path, function()
          duckdb.query(
            path,
            [[INSERT INTO review_comments (comment_scope, comment_type, content, deleted_at)
              VALUES ('file', 'note', 'cleared recently', now() - INTERVAL '1 hour');]],
            nil,
            done
          )
        end)
      end)

      assert.equals(0, hard_delete_now())

      local _, remaining = await_result(function(done)
        duckdb.query(path, "SELECT id FROM review_comments;", { readonly = true }, done)
      end)
      assert.equals(1, #remaining)
    end)

    it("never touches a comment that has not been cleared", function()
      local path = storage.get_storage_path()
      await(function(done)
        storage.ensure_schema(path, function()
          duckdb.query(path, "INSERT INTO review_comments (comment_scope, comment_type, content) VALUES ('file', 'note', 'still active');", nil, done)
        end)
      end)

      assert.equals(0, hard_delete_now())

      local _, remaining = await_result(function(done)
        duckdb.query(path, "SELECT id FROM review_comments;", { readonly = true }, done)
      end)
      assert.equals(1, #remaining)
    end)
  end)
end)
