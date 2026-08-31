local duckdb = require("review.duckdb")

---Runs an async duckdb.lua call and blocks (via vim.wait polling, not
---vim.system(...):wait()) until its callback fires, returning the
---callback's arguments. Keeps this spec's assertions synchronous/inline
---like the rest of the suite without making duckdb.lua itself blocking.
---@param fn fun(done: fun(...))
---@return ...
local function await(fn)
  local done = false
  local results
  local n

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

describe("review.duckdb", function()
  local db_path

  before_each(function()
    db_path = vim.fn.tempname() .. ".duckdb"
  end)

  after_each(function()
    os.remove(db_path)
  end)

  describe("escape_string", function()
    it("doubles single quotes", function()
      assert.equals("it''s a test", duckdb.escape_string("it's a test"))
    end)

    it("leaves strings with no quotes unchanged", function()
      assert.equals("hello world", duckdb.escape_string("hello world"))
    end)

    it("preserves embedded newlines", function()
      assert.equals("line one\nline two", duckdb.escape_string("line one\nline two"))
    end)
  end)

  describe("query", function()
    it("returns an empty result for a DDL statement with no output", function()
      local ok, result, err = await(function(done)
        duckdb.query(db_path, "CREATE TABLE t (id INTEGER, content VARCHAR);", nil, done)
      end)
      assert.is_true(ok)
      assert.same({}, result)
      assert.is_nil(err)
    end)

    it("returns decoded rows for a query with RETURNING", function()
      await(function(done)
        duckdb.query(db_path, "CREATE TABLE t (id INTEGER, content VARCHAR);", nil, done)
      end)

      local ok, result, err = await(function(done)
        duckdb.query(
          db_path,
          "INSERT INTO t VALUES (1, 'hello') RETURNING id, content;",
          nil,
          done
        )
      end)
      assert.is_true(ok)
      assert.equals(1, #result)
      assert.equals(1, result[1].id)
      assert.equals("hello", result[1].content)
      assert.is_nil(err)
    end)

    it("round-trips a value containing a quote and a newline when escaped", function()
      await(function(done)
        duckdb.query(db_path, "CREATE TABLE t (id INTEGER, content VARCHAR);", nil, done)
      end)

      local content = "it's a test\nwith a newline"
      local sql = string.format(
        "INSERT INTO t VALUES (1, '%s') RETURNING content;",
        duckdb.escape_string(content)
      )
      local ok, result = await(function(done)
        duckdb.query(db_path, sql, nil, done)
      end)
      assert.is_true(ok)
      assert.equals(content, result[1].content)
    end)

    it("returns an empty array for RETURNING that matches no rows", function()
      await(function(done)
        duckdb.query(db_path, "CREATE TABLE t (id INTEGER, content VARCHAR);", nil, done)
      end)

      local ok, result = await(function(done)
        duckdb.query(db_path, "UPDATE t SET content = 'x' WHERE id = 999 RETURNING id;", nil, done)
      end)
      assert.is_true(ok)
      assert.same({}, result)
    end)

    it("reports failure with stderr on invalid SQL", function()
      local ok, result, err = await(function(done)
        duckdb.query(db_path, "SELECT * FROM nonexistent_table;", nil, done)
      end)
      assert.is_false(ok)
      assert.is_nil(result)
      assert.truthy(err)
    end)

    it("allows concurrent readonly reads with no writer present", function()
      await(function(done)
        duckdb.query(db_path, "CREATE TABLE t (id INTEGER);", nil, done)
      end)

      local ok1, ok2
      await(function(done)
        local remaining = 2
        local function on_one(ok)
          ok1 = ok1 == nil and ok or ok1
          remaining = remaining - 1
          if remaining == 0 then
            done()
          end
        end
        duckdb.query(db_path, "SELECT * FROM t;", { readonly = true }, function(ok)
          on_one(ok)
        end)
        duckdb.query(db_path, "SELECT * FROM t;", { readonly = true }, function(ok)
          ok2 = ok
          on_one(ok)
        end)
      end)
      assert.is_true(ok1)
      assert.is_true(ok2)
    end)
  end)

  describe("query_with_retry", function()
    it("succeeds immediately with no contention", function()
      local ok = await(function(done)
        duckdb.query_with_retry(
          db_path,
          "CREATE TABLE t (id INTEGER);",
          { max_retries = 3, backoff_ms = 10 },
          done
        )
      end)
      assert.is_true(ok)
    end)

    it("does not retry a non-lock-contention failure", function()
      local ok, _, err = await(function(done)
        duckdb.query_with_retry(
          db_path,
          "SELECT * FROM nonexistent_table;",
          { max_retries = 3, backoff_ms = 10 },
          done
        )
      end)
      assert.is_false(ok)
      assert.truthy(err)
    end)

    it("retries and succeeds once the lock-holding writer releases it", function()
      await(function(done)
        duckdb.query(db_path, "CREATE TABLE t (id INTEGER);", nil, done)
      end)

      -- Hold a real writer lock open in a background OS process for ~800ms,
      -- reproducing DuckDB's empirically-tested "Conflicting lock is held"
      -- IO Error (docs/research/duckdb-storage-backend.md SS3).
      local holder = vim.system(
        { "duckdb", db_path, "-c", "BEGIN TRANSACTION; SELECT sleep_ms(800) FROM range(1); INSERT INTO t VALUES (1); COMMIT;" },
        { text = true }
      )

      vim.wait(200) -- give the holder time to acquire the lock first

      local ok, result, err = await(function(done)
        duckdb.query_with_retry(
          db_path,
          "INSERT INTO t VALUES (2) RETURNING id;",
          { max_retries = 5, backoff_ms = 150, timeout_ms = 2000 },
          done
        )
      end)

      holder:wait(2000)

      assert.is_true(ok, err)
      assert.equals(1, #result)
    end)
  end)
end)
