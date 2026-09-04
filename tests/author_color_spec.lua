local store = require("review.store")
local marks = require("review.marks")
local config = require("review.config")
local helpers = require("tests.helpers")

-- "tj" and "agent:claude-code" are known (verified against a real duckdb
-- CLI) to land in different hash buckets of the 8-entry author palette, so
-- the "different authors" assertions below aren't flaky against a collision.
describe("per-author comment box border color", function()
  before_each(function()
    store.clear()
    config.setup()
  end)

  describe("DuckDB-computed color (color_dark/color_light columns)", function()
    it("is deterministic: the same author gets the same colors across separate inserts", function()
      local first = helpers.add(store, "a.lua", 1, "note", "first", nil, nil, "tj")
      local second = helpers.add(store, "b.lua", 2, "note", "second", nil, nil, "tj")

      assert.equals(first.color_dark, second.color_dark)
      assert.equals(first.color_light, second.color_light)
    end)

    it("gives different authors different colors", function()
      local tj = helpers.add(store, "a.lua", 1, "note", "x", nil, nil, "tj")
      local agent = helpers.add(store, "a.lua", 2, "note", "y", nil, nil, "agent:claude-code")

      assert.are_not.equal(tj.color_dark, agent.color_dark)
      assert.are_not.equal(tj.color_light, agent.color_light)
    end)

    it("returns a hex color for both palettes", function()
      local comment = helpers.add(store, "a.lua", 1, "note", "x", nil, nil, "tj")

      assert.is_not_nil(comment.color_dark:match("^#%x%x%x%x%x%x$"))
      assert.is_not_nil(comment.color_light:match("^#%x%x%x%x%x%x$"))
    end)
  end)

  describe("rendering", function()
    local bufnr, win, ns_id
    local original_background

    before_each(function()
      original_background = vim.o.background
      ns_id = vim.api.nvim_create_namespace("review")
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local M = {}", "return M" })
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, bufnr)
    end)

    after_each(function()
      vim.o.background = original_background
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    local function box_virt_lines()
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
      assert.equals(1, #extmarks)
      return extmarks[1][4].virt_lines
    end

    local function hex_of(hl_group)
      local resolved = vim.api.nvim_get_hl(0, { name = hl_group })
      return string.format("#%06x", resolved.fg)
    end

    it("colors only the border chunks; header and content keep the type highlight", function()
      vim.o.background = "dark"
      local comment = helpers.add(store, "test.lua", 1, "note", "Short comment", nil, nil, "tj")

      marks.render_for_buffer(bufnr, "new", "test.lua")

      local virt_lines = box_virt_lines()
      assert.equals(3, #virt_lines) -- header + 1 content line + footer

      local top = virt_lines[1]
      assert.equals(3, #top)
      assert.equals("╭─", top[1][1])
      assert.equals("[NOTE]", top[2][1])
      assert.equals("ReviewNote", top[2][2])

      local border_hl = top[1][2]
      assert.equals(border_hl, top[3][2])
      assert.equals(comment.color_dark, hex_of(border_hl))

      local content = virt_lines[2]
      assert.equals(3, #content)
      assert.equals(border_hl, content[1][2])
      assert.equals(border_hl, content[3][2])
      assert.equals("ReviewNote", content[2][2])

      local bottom = virt_lines[3]
      assert.equals(1, #bottom)
      assert.equals(border_hl, bottom[1][2])
    end)

    it("uses color_light instead of color_dark when background=light", function()
      vim.o.background = "light"
      local comment = helpers.add(store, "test.lua", 1, "note", "Short comment", nil, nil, "tj")

      marks.render_for_buffer(bufnr, "new", "test.lua")

      local border_hl = box_virt_lines()[1][1][2]
      assert.equals(comment.color_light, hex_of(border_hl))
    end)
  end)
end)
