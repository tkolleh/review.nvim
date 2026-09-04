local store = require("review.store")
local helpers = require("tests.helpers")
local export = require("review.export")
local duckdb = require("review.duckdb")

---Runs an async duckdb.lua call and blocks until its callback fires.
---Mirrors store_spec.lua's await, needed here to insert a row directly
---(bypassing store.add) so it round-trips through the real JSON decode.
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

describe("review.export", function()
  before_each(function()
    store.clear()
  end)

  describe("generate_markdown", function()
    it("returns empty message when no comments", function()
      local md = export.generate_markdown()
      assert.matches("No comments yet", md)
    end)

    it("includes file and comment in output", function()
      helpers.add(store, "src/main.lua", 10, "issue", "Fix this bug")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:10", md)
      assert.matches("%[ISSUE%]", md)
      assert.matches("Fix this bug", md)
    end)

    it("formats comments as numbered list", function()
      helpers.add(store, "a.lua", 1, "note", "Note A")
      helpers.add(store, "b.lua", 1, "issue", "Issue B")
      helpers.add(store, "a.lua", 5, "suggestion", "Suggestion A")

      local md = export.generate_markdown()
      assert.matches("1%. %*%*%[NOTE%]%*%*", md)
      assert.matches("2%. %*%*%[SUGGESTION%]%*%*", md)
      assert.matches("3%. %*%*%[ISSUE%]%*%*", md)
    end)

    it("uses tilde notation for old-side comments", function()
      helpers.add(store, "src/main.lua", 10, "issue", "Removed bug", nil, "old")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:~10", md)
    end)

    it("uses tilde on both ends for old-side range", function()
      helpers.add(store, "src/main.lua", 10, "issue", "Old range", 15, "old")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:~10%-~15", md)
    end)

    it("uses normal notation for new-side comments", function()
      helpers.add(store, "src/main.lua", 10, "issue", "New side", nil, "new")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:10", md)
      assert.not_matches("~10", md)
    end)

    -- OptionalFieldsPersistAsAbsent (specs/review-storage.allium): a
    -- single-line comment loaded from storage (rather than store.add's own
    -- write-callback path) has a NULL line_end. vim.json.decode() without
    -- luanil turns that into vim.NIL, a userdata sentinel that is truthy --
    -- `comment.line_end and comment.line_end ~= comment.line` (export.lua)
    -- then takes the range branch and formats "%d" with a userdata value,
    -- erroring instead of falling back to the single-line format.
    it("formats a synced single-line comment without erroring on a NULL line_end", function()
      -- Seeds the schema (review_comments table) the same way store.add
      -- would, so the raw insert below lands in an existing table rather
      -- than silently failing against a not-yet-bootstrapped db file.
      helpers.add(store, "seed.lua", 1, "note", "seed")

      local path = require("review.storage").get_storage_path()
      local insert_ok, _, insert_err = await(function(done)
        duckdb.query(
          path,
          "INSERT INTO review_comments (comment_scope, file_path, line_start, side, comment_type, content, author) "
            .. "VALUES ('line', 'src/main.lua', 10, 'new', 'note', 'from another writer', 'other-agent') RETURNING id;",
          nil,
          done
        )
      end)
      assert.is_true(insert_ok, insert_err)

      await(function(done)
        store.sync_from_storage(done)
      end)

      local md
      assert.has_no.errors(function()
        md = export.generate_markdown()
      end)
      assert.matches("src/main.lua:10", md)
      assert.not_matches("src/main.lua:10%-", md)
    end)
  end)
end)
