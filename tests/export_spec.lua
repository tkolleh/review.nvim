local store = require("review.store")
local helpers = require("tests.helpers")
local export = require("review.export")

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
  end)
end)
