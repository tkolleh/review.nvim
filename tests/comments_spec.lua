local store = require("review.store")
local comments = require("review.comments")
local duckdb = require("review.duckdb")
local helpers = require("tests.helpers")

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

describe("review.comments", function()
  before_each(function()
    store.clear()
  end)

  describe("list", function()
    local original_select

    before_each(function()
      original_select = vim.ui.select
      -- M.list() only needs items built without erroring for this
      -- regression; it never reads the picker's chosen result here.
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end
    end)

    after_each(function()
      vim.ui.select = original_select
    end)

    -- OptionalFieldsPersistAsAbsent (specs/review-storage.allium): mirrors
    -- export_spec.lua's regression -- comments.lua's M.list() duplicates
    -- the same `comment.line_end and comment.line_end ~= comment.line`
    -- range check, so a synced single-line comment with a NULL line_end
    -- (decoded as vim.NIL, not nil) hits the same "%d" formatting error on
    -- a userdata value.
    it("builds the picker list for a synced single-line comment without erroring", function()
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

      assert.has_no.errors(function()
        comments.list()
      end)
    end)
  end)

  describe("file_comment", function()
    local hooks = require("review.hooks")
    local popup = require("review.popup")
    local original_get_cursor_position, original_popup_open

    before_each(function()
      original_get_cursor_position = hooks.get_cursor_position
      original_popup_open = popup.open
      hooks.get_cursor_position = function()
        return "src/main.lua", 1, "new"
      end
    end)

    after_each(function()
      hooks.get_cursor_position = original_get_cursor_position
      popup.open = original_popup_open
    end)

    -- IndependentWritersDoNotCollide's NoClobber guarantee
    -- (specs/review-storage.allium) applies per-author to file-scoped
    -- comments same as line-scoped ones: adding a file comment must never
    -- silently edit a different author's existing one.
    it("creates a new file comment rather than editing another author's", function()
      -- Seeds the schema (review_comments table) the same way store.add
      -- would, so the raw insert below lands in an existing table rather
      -- than silently failing against a not-yet-bootstrapped db file.
      helpers.add(store, "src/main.lua", 5, "note", "seed")

      local path = require("review.storage").get_storage_path()
      local insert_ok, _, insert_err = await(function(done)
        duckdb.query(
          path,
          "INSERT INTO review_comments (comment_scope, file_path, comment_type, content, author) "
            .. "VALUES ('file', 'src/main.lua', 'note', 'from another writer', 'other-agent') RETURNING id;",
          nil,
          done
        )
      end)
      assert.is_true(insert_ok, insert_err)

      await(function(done)
        store.sync_from_storage(done)
      end)

      popup.open = function(_, _, on_submit)
        on_submit("issue", "my own file comment")
      end

      comments.file_comment()

      vim.wait(2000, function()
        return #store.get_for_file("src/main.lua") >= 3
      end, 10)

      local all = store.get_for_file("src/main.lua")
      assert.equals(3, #all)

      local others_comment = store.get_file_comment("src/main.lua", "other-agent")
      assert.is_not_nil(others_comment)
      assert.equals("from another writer", others_comment.text)
    end)
  end)
end)
