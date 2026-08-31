local store = require("review.store")

---Runs a callback-based store.lua write and blocks (via vim.wait polling,
---not a blocking API) until the callback fires, returning its arguments.
---Keeps this spec's assertions synchronous/inline despite store.add/update/
---delete/resolve now being callback-based (DuckDB CLI subprocess-backed).
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

-- store.add's positional signature is (file, line, type, text, line_end,
-- side, author, callback) -- callback must land in slot 8 exactly, so
-- shorter test calls need padding to 7 args first (unpack(args, 1, 7)
-- correctly turns any padded-nil slot into a real nil argument, not a
-- missing one).
local ADD_ARITY = 7

---@return Comment
local function add(...)
  local args = { ... }
  return (await(function(done)
    args[ADD_ARITY + 1] = done
    store.add(unpack(args, 1, ADD_ARITY + 1))
  end))
end

describe("review.store", function()
  before_each(function()
    store.clear()
  end)

  describe("add", function()
    it("creates a comment with generated id", function()
      local comment = add("file.lua", 10, "issue", "Fix this")
      assert.is_not_nil(comment.id)
      assert.equals("file.lua", comment.file)
      assert.equals(10, comment.line)
      assert.equals("issue", comment.type)
      assert.equals("Fix this", comment.text)
    end)

    it("stores comments by file", function()
      add("a.lua", 1, "note", "Note 1")
      add("a.lua", 2, "note", "Note 2")
      add("b.lua", 1, "issue", "Issue 1")

      assert.equals(2, #store.get_for_file("a.lua"))
      assert.equals(1, #store.get_for_file("b.lua"))
    end)
  end)

  describe("get_at_line", function()
    it("returns comment at specific line", function()
      add("file.lua", 10, "issue", "At line 10")
      add("file.lua", 20, "note", "At line 20")

      local comment = store.get_at_line("file.lua", 10)
      assert.is_not_nil(comment)
      assert.equals("At line 10", comment.text)
    end)

    it("returns nil when no comment at line", function()
      add("file.lua", 10, "issue", "At line 10")
      assert.is_nil(store.get_at_line("file.lua", 15))
    end)
  end)

  describe("update", function()
    it("updates comment text", function()
      local comment = add("file.lua", 10, "issue", "Original")
      local success = await(function(done)
        store.update(comment.id, "Original", "Updated", nil, done)
      end)

      assert.is_true(success)
      assert.equals("Updated", store.get(comment.id).text)
    end)

    it("returns false for non-existent id", function()
      local ok = await(function(done)
        store.update("fake_id", "anything", "text", nil, done)
      end)
      assert.is_false(ok)
    end)
  end)

  describe("delete", function()
    it("removes comment", function()
      local comment = add("file.lua", 10, "issue", "Delete me")
      assert.equals(1, store.count())

      local success = await(function(done)
        store.delete(comment.id, "Delete me", done)
      end)
      assert.is_true(success)
      assert.equals(0, store.count())
    end)

    it("returns false for non-existent id", function()
      local ok = await(function(done)
        store.delete("fake_id", "anything", done)
      end)
      assert.is_false(ok)
    end)
  end)

  describe("get_all", function()
    it("returns all comments sorted by file and line", function()
      add("b.lua", 20, "note", "B20")
      add("a.lua", 10, "note", "A10")
      add("a.lua", 5, "note", "A5")

      local all = store.get_all()
      assert.equals(3, #all)
      assert.equals("A5", all[1].text)
      assert.equals("A10", all[2].text)
      assert.equals("B20", all[3].text)
    end)
  end)

  describe("count", function()
    it("returns total comment count", function()
      assert.equals(0, store.count())
      add("a.lua", 1, "note", "1")
      add("b.lua", 1, "note", "2")
      assert.equals(2, store.count())
    end)
  end)

  describe("side awareness", function()
    it("stores side field on add", function()
      local c = add("file.lua", 10, "note", "old side", nil, "old")
      assert.equals("old", c.side)
    end)

    it("defaults side to new", function()
      local c = add("file.lua", 10, "note", "no side")
      assert.equals("new", c.side)
    end)

    it("get_at_line filters by side", function()
      add("file.lua", 10, "note", "old comment", nil, "old")
      add("file.lua", 10, "issue", "new comment", nil, "new")

      local old = store.get_at_line("file.lua", 10, "old")
      assert.is_not_nil(old)
      assert.equals("old comment", old.text)

      local new = store.get_at_line("file.lua", 10, "new")
      assert.is_not_nil(new)
      assert.equals("new comment", new.text)
    end)

    it("get_at_line without side returns first match", function()
      add("file.lua", 10, "note", "old comment", nil, "old")
      local c = store.get_at_line("file.lua", 10)
      assert.is_not_nil(c)
      assert.equals("old comment", c.text)
    end)

    it("get_overlapping filters by side", function()
      add("file.lua", 5, "note", "old range", 15, "old")
      add("file.lua", 5, "issue", "new range", 15, "new")

      local old = store.get_overlapping("file.lua", 8, 12, "old")
      assert.is_not_nil(old)
      assert.equals("old range", old.text)

      local new = store.get_overlapping("file.lua", 8, 12, "new")
      assert.is_not_nil(new)
      assert.equals("new range", new.text)
    end)

    it("get_for_file filters by side", function()
      add("file.lua", 5, "note", "old", nil, "old")
      add("file.lua", 10, "issue", "new", nil, "new")

      local old_comments = store.get_for_file("file.lua", "old")
      assert.equals(1, #old_comments)
      assert.equals("old", old_comments[1].text)

      local new_comments = store.get_for_file("file.lua", "new")
      assert.equals(1, #new_comments)
      assert.equals("new", new_comments[1].text)
    end)

    it("get_for_file without side returns all", function()
      add("file.lua", 5, "note", "old", nil, "old")
      add("file.lua", 10, "issue", "new", nil, "new")

      local all = store.get_for_file("file.lua")
      assert.equals(2, #all)
    end)

    it("get_for_file with side includes file-level comments", function()
      add("file.lua", 0, "note", "file comment")
      add("file.lua", 10, "issue", "new side", nil, "new")
      add("file.lua", 10, "note", "old side", nil, "old")

      local old_comments = store.get_for_file("file.lua", "old")
      assert.equals(2, #old_comments)

      local new_comments = store.get_for_file("file.lua", "new")
      assert.equals(2, #new_comments)
    end)

    it("comments on different sides at same line don't conflict", function()
      add("file.lua", 10, "note", "old note", nil, "old")
      add("file.lua", 10, "issue", "new issue", nil, "new")

      local old = store.get_at_line("file.lua", 10, "old")
      local new = store.get_at_line("file.lua", 10, "new")
      assert.is_not_nil(old)
      assert.is_not_nil(new)
      assert.are_not.equal(old.text, new.text)
    end)
  end)

  -- Generated from specs/review-storage.allium. Spec-first: these describe
  -- store.lua's intended post-migration API and are expected to fail until
  -- that implementation work lands (multi-author comments, author field,
  -- optimistic-concurrency edit/delete, ambiguous-comment selection).
  -- Obligation ids reference `allium plan specs/review-storage.allium`.
  describe("author field (entity-fields.Comment, when-presence.Comment.*)", function()
    it("stores an explicit author on add", function()
      local c = add("file.lua", 10, "issue", "text", nil, "new", "tkolleh")
      assert.equals("tkolleh", c.author)
    end)

    it("defaults author when omitted, matching today's single-writer comments", function()
      local c = add("file.lua", 10, "issue", "text")
      assert.is_not_nil(c.author)
    end)
  end)

  -- rule-success/rule-entity-creation IndependentWritersDoNotCollide:
  -- two authors on the same file/line each get their own comment, neither
  -- clobbers, blocks, or merges with the other (duckdb-storage-backend.md
  -- SS2a; specs/review-storage.allium IndependentWritersDoNotCollide).
  describe("multiple comments per line, multiple authors (independent writers)", function()
    it("allows a second author's comment at an already-commented line", function()
      local first = add("file.lua", 42, "issue", "Missing nil check", nil, "new", "tkolleh")
      local second = add("file.lua", 42, "suggestion", "Extract a helper", nil, "new", "claude-agent")

      assert.are_not.equal(first.id, second.id)
      local at_line = store.get_all_at_line("file.lua", 42)
      assert.equals(2, #at_line)
    end)

    it("preserves both authors' comments independently, in submission order", function()
      add("file.lua", 42, "issue", "first", nil, "new", "tkolleh")
      add("file.lua", 42, "suggestion", "second", nil, "new", "claude-agent")

      local at_line = store.get_all_at_line("file.lua", 42)
      assert.equals("tkolleh", at_line[1].author)
      assert.equals("claude-agent", at_line[2].author)
    end)

    it("does not let a second author's submission alter the first author's comment", function()
      local first = add("file.lua", 42, "issue", "first", nil, "new", "tkolleh")
      add("file.lua", 42, "suggestion", "second", nil, "new", "claude-agent")

      local reloaded = store.get(first.id)
      assert.equals("first", reloaded.text)
      assert.equals("tkolleh", reloaded.author)
    end)
  end)

  -- rule-success/rule-failure CommentModificationsDoNotRace, DeletingComment:
  -- edit/delete take the caller's last-known content and reject a stale
  -- modification rather than silently applying or blindly overwriting it.
  describe("optimistic-concurrency edit (CommentModificationsDoNotRace)", function()
    it("applies the edit when expected_prior_content matches", function()
      local c = add("file.lua", 10, "issue", "Original", nil, "new", "tkolleh")
      local ok = await(function(done)
        store.update(c.id, "Original", "Updated", nil, done)
      end)

      assert.is_true(ok)
      assert.equals("Updated", store.get(c.id).text)
    end)

    it("updates the type when new_type is provided", function()
      local c = add("file.lua", 10, "issue", "Original", nil, "new", "tkolleh")
      await(function(done)
        store.update(c.id, "Original", "Updated", "suggestion", done)
      end)

      assert.equals("suggestion", store.get(c.id).type)
    end)

    it("rejects the edit when expected_prior_content is stale", function()
      local c = add("file.lua", 10, "issue", "Original", nil, "new", "tkolleh")
      -- Simulate another writer's edit landing first.
      await(function(done)
        store.update(c.id, "Original", "Changed by someone else", nil, done)
      end)

      local ok, reason = await(function(done)
        store.update(c.id, "Original", "My stale edit", nil, done)
      end)

      assert.is_false(ok)
      assert.equals("stale", reason)
      assert.equals("Changed by someone else", store.get(c.id).text)
    end)

    it("returns false for a non-existent id", function()
      local ok = await(function(done)
        store.update("fake_id", "anything", "text", nil, done)
      end)
      assert.is_false(ok)
    end)
  end)

  describe("optimistic-concurrency delete (DeletingComment)", function()
    it("deletes when expected_prior_content matches", function()
      local c = add("file.lua", 10, "issue", "Delete me", nil, "new", "tkolleh")
      local ok = await(function(done)
        store.delete(c.id, "Delete me", done)
      end)

      assert.is_true(ok)
      assert.is_nil(store.get(c.id))
    end)

    it("rejects the delete when expected_prior_content is stale", function()
      local c = add("file.lua", 10, "issue", "Original", nil, "new", "tkolleh")
      await(function(done)
        store.update(c.id, "Original", "Changed by someone else", nil, done)
      end)

      local ok, reason = await(function(done)
        store.delete(c.id, "Original", done)
      end)

      assert.is_false(ok)
      assert.equals("stale", reason)
      assert.is_not_nil(store.get(c.id))
    end)

    it("returns false for a non-existent id", function()
      local ok = await(function(done)
        store.delete("fake_id", "anything", done)
      end)
      assert.is_false(ok)
    end)
  end)

  -- rule-success ResolvingComment / rule-failure ResolvingComment.1:
  -- lifecycle_state moves submitted -> resolved; resolving an
  -- already-resolved comment is rejected (requires clause fails).
  describe("resolving a comment (ResolvingComment)", function()
    it("marks a submitted comment resolved", function()
      local c = add("file.lua", 10, "note", "text", nil, "new", "tkolleh")
      assert.equals("submitted", c.lifecycle_state)

      local ok = await(function(done)
        store.resolve(c.id, done)
      end)

      assert.is_true(ok)
      assert.equals("resolved", store.get(c.id).lifecycle_state)
    end)

    it("rejects resolving an already-resolved comment", function()
      local c = add("file.lua", 10, "note", "text", nil, "new", "tkolleh")
      await(function(done)
        store.resolve(c.id, done)
      end)

      local ok = await(function(done)
        store.resolve(c.id, done)
      end)

      assert.is_false(ok)
    end)

    it("returns false for a non-existent id", function()
      local ok = await(function(done)
        store.resolve("fake_id", done)
      end)
      assert.is_false(ok)
    end)
  end)

  -- rule-success SelectingAmbiguousComment: author-match-first
  -- disambiguation when more than one comment exists at a file/line
  -- (specs/review-storage.allium SelectingAmbiguousComment;
  -- duckdb-storage-backend.md SS2a's edit/delete disambiguation question).
  describe("selecting among ambiguous comments at one location", function()
    it("targets the sole comment when only one exists at the location", function()
      local c = add("file.lua", 42, "issue", "only one", nil, "new", "tkolleh")
      local selected, needs_explicit = store.select_ambiguous_comment("file.lua", 42, "tkolleh")

      assert.equals(c.id, selected.id)
      assert.is_false(needs_explicit)
    end)

    it("auto-targets the acting author's own comment when others exist too", function()
      local mine = add("file.lua", 42, "issue", "mine", nil, "new", "tkolleh")
      add("file.lua", 42, "suggestion", "theirs", nil, "new", "claude-agent")

      local selected, needs_explicit = store.select_ambiguous_comment("file.lua", 42, "tkolleh")

      assert.equals(mine.id, selected.id)
      assert.is_false(needs_explicit)
    end)

    it("requires an explicit reference when the author has no comment there", function()
      add("file.lua", 42, "suggestion", "theirs", nil, "new", "claude-agent")

      local selected, needs_explicit = store.select_ambiguous_comment("file.lua", 42, "tkolleh")

      assert.is_nil(selected)
      assert.is_true(needs_explicit)
    end)

    it("requires an explicit reference when the author has more than one comment there", function()
      add("file.lua", 42, "issue", "first", nil, "new", "tkolleh")
      add("file.lua", 42, "note", "second", nil, "new", "tkolleh")

      local selected, needs_explicit = store.select_ambiguous_comment("file.lua", 42, "tkolleh")

      assert.is_nil(selected)
      assert.is_true(needs_explicit)
    end)

    it("returns no selection and no explicit-required flag when nothing exists at the location", function()
      local selected, needs_explicit = store.select_ambiguous_comment("file.lua", 42, "tkolleh")

      assert.is_nil(selected)
      assert.is_false(needs_explicit)
    end)
  end)

  -- invariant.CommentScopeFieldsMatch, when-presence.Comment.file_path/
  -- line_start/line_end/side: file_path is set iff scope is file or line;
  -- line_start/line_end/side are set iff scope is line. Expressed against
  -- store.lua's existing field shape (line == 0 sentinel for file scope,
  -- see agent-comment-authoring.md SS1) rather than the spec's own
  -- scope/file_path/line_start names, since that shape is unchanged by
  -- this migration.
  describe("comment scope field presence (CommentScopeFieldsMatch)", function()
    it("a file-level comment (line == 0) has no line_end or side semantics", function()
      local c = add("file.lua", 0, "note", "file comment")
      assert.equals(0, c.line)
      assert.is_nil(c.line_end)
    end)

    it("a line-level comment always has file and line set", function()
      local c = add("file.lua", 10, "note", "line comment")
      assert.is_not_nil(c.file)
      assert.is_not_nil(c.line)
    end)

    it("a range comment has line_end set only when it differs from line", function()
      local single_line = add("file.lua", 10, "note", "single", 10)
      assert.is_nil(single_line.line_end)

      local range = add("file.lua", 10, "note", "range", 15)
      assert.equals(15, range.line_end)
    end)
  end)

  -- invariant.LineRangeOrdered: line_end, when present, is never less than
  -- the comment's starting line.
  describe("line range ordering (LineRangeOrdered)", function()
    it("accepts a range where line_end >= line", function()
      local c = add("file.lua", 10, "note", "valid range", 20)
      assert.is_true(c.line_end >= c.line)
    end)

    it("stores a well-formed range as given (start <= end)", function()
      local c = add("file.lua", 5, "note", "range", 12)
      assert.equals(5, c.line)
      assert.equals(12, c.line_end)
    end)
  end)

  -- surface-exposure/surface-provides/surface-actor.CommentAuthor: the
  -- CommentAuthor surface exposes review/file/line comment projections and
  -- provides submit/edit/delete/resolve operations scoped to the acting
  -- writer; edit/delete are only available when comment.author = writer.
  describe("CommentAuthor surface", function()
    it("exposes file-scoped and line-scoped comments for the current file", function()
      add("file.lua", 0, "note", "file-level")
      add("file.lua", 10, "note", "line-level")

      local exposed = store.get_for_file("file.lua")
      assert.equals(2, #exposed)
    end)

    it("select_ambiguous_comment scopes edit/delete targeting to the acting author's own comment", function()
      -- The `when comment.author = writer` guard on AuthorEditsComment/
      -- AuthorDeletesComment (specs/review-storage.allium CommentAuthor
      -- surface) is enforced by resolving *which* comment a writer may act
      -- on before store.update/store.delete are ever called -- see
      -- SelectingAmbiguousComment above. A writer is never handed a
      -- selection that resolves to another author's comment.
      add("file.lua", 10, "issue", "theirs", nil, "new", "someone-else")

      local selected, needs_explicit = store.select_ambiguous_comment("file.lua", 10, "tkolleh")

      assert.is_nil(selected)
      assert.is_true(needs_explicit)
    end)
  end)

  -- ReadYourWrites is satisfied for this process's own writes by updating
  -- the cache directly in each write's callback (see M.add/update/delete/
  -- resolve above) -- sync_from_storage is specifically about picking up a
  -- *different* writer's (e.g. an external agent's) concurrent comments,
  -- simulated here via review.duckdb directly rather than a second process.
  describe("sync_from_storage (external writer visibility)", function()
    local duckdb = require("review.duckdb")

    it("picks up a comment inserted directly by another writer", function()
      add("file.lua", 1, "note", "mine")

      local path = require("review.storage").get_storage_path()
      await(function(done)
        duckdb.query(
          path,
          "INSERT INTO review_comments (comment_scope, file_path, line_start, side, comment_type, content, author) "
            .. "VALUES ('line', 'file.lua', 5, 'new', 'issue', 'from another writer', 'other-agent') RETURNING id;",
          nil,
          done
        )
      end)

      assert.equals(1, #store.get_for_file("file.lua"))

      await(function(done)
        store.sync_from_storage(done)
      end)

      local all = store.get_for_file("file.lua")
      assert.equals(2, #all)

      local found = false
      for _, c in ipairs(all) do
        if c.text == "from another writer" and c.author == "other-agent" then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("removes a cached comment another writer deleted", function()
      local c = add("file.lua", 1, "note", "will be deleted elsewhere")
      assert.is_not_nil(store.get(c.id))

      local path = require("review.storage").get_storage_path()
      await(function(done)
        duckdb.query(path, string.format("DELETE FROM review_comments WHERE id = '%s';", c.id), nil, done)
      end)

      await(function(done)
        store.sync_from_storage(done)
      end)

      assert.is_nil(store.get(c.id))
    end)

    it("updates a cached comment another writer edited", function()
      local c = add("file.lua", 1, "note", "original")

      local path = require("review.storage").get_storage_path()
      await(function(done)
        duckdb.query(
          path,
          string.format("UPDATE review_comments SET content = 'edited elsewhere' WHERE id = '%s';", c.id),
          nil,
          done
        )
      end)

      await(function(done)
        store.sync_from_storage(done)
      end)

      assert.equals("edited elsewhere", store.get(c.id).text)
    end)
  end)
end)
