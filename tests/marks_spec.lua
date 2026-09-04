local store = require("review.store")
local marks = require("review.marks")
local config = require("review.config")
local helpers = require("tests.helpers")

describe("comment box line wrapping", function()
  local bufnr, win
  local ns_id

  before_each(function()
    store.clear()
    config.setup()
    ns_id = vim.api.nvim_create_namespace("review")

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local M = {}", "return M" })

    -- vsplit so the window can be resized narrower than the full editor width
    -- (nvim_win_set_width is a no-op on the sole window in a tabpage), giving
    -- wrap_line a deterministic, known-narrow target width to wrap against.
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.api.nvim_win_set_width(win, 30)
  end)

  after_each(function()
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

  -- A rendered line is `{ {text, hl}, {text, hl}, ... }` (border/content/border
  -- may be separate highlighted chunks since author-color border rendering
  -- was added) -- concatenate before measuring the line's true display width.
  local function line_width(line)
    local width = 0
    for _, chunk in ipairs(line) do
      width = width + vim.fn.strdisplaywidth(chunk[1])
    end
    return width
  end

  it("wraps a long single line instead of growing the box past the window width", function()
    local long_text = "This is a long comment that should wrap across several lines "
      .. "instead of growing the box unbounded past the edge of the window"
    helpers.add(store, "test.lua", 1, "issue", long_text)

    marks.render_for_buffer(bufnr, "new", "test.lua")

    local virt_lines = box_virt_lines()
    assert.is_true(#virt_lines > 3, "expected wrapping to produce more than one content line")
  end)

  it("keeps every rendered line within the window's usable width", function()
    local long_text = "This is a long comment that should wrap across several lines "
      .. "instead of growing the box unbounded past the edge of the window"
    helpers.add(store, "test.lua", 1, "issue", long_text)

    marks.render_for_buffer(bufnr, "new", "test.lua")

    local win_width = vim.api.nvim_win_get_width(win)
    for _, line in ipairs(box_virt_lines()) do
      local rendered = line[1][1]
      assert.is_true(
        vim.fn.strdisplaywidth(rendered) <= win_width,
        "rendered line exceeded window width: " .. rendered
      )
    end
  end)

  it("box lines share a consistent width after wrapping", function()
    local long_text = "This is a long comment that should wrap across several lines "
      .. "instead of growing the box unbounded past the edge of the window"
    helpers.add(store, "test.lua", 1, "issue", long_text)

    marks.render_for_buffer(bufnr, "new", "test.lua")

    local virt_lines = box_virt_lines()
    local first_width = line_width(virt_lines[1])
    for _, line in ipairs(virt_lines) do
      assert.equals(first_width, line_width(line))
    end
  end)

  it("hard-splits a single word wider than the window instead of overflowing", function()
    local unbreakable = string.rep("x", 200)
    helpers.add(store, "test.lua", 1, "note", unbreakable)

    marks.render_for_buffer(bufnr, "new", "test.lua")

    local win_width = vim.api.nvim_win_get_width(win)
    for _, line in ipairs(box_virt_lines()) do
      assert.is_true(line_width(line) <= win_width)
    end
  end)

  it("does not wrap a short comment", function()
    helpers.add(store, "test.lua", 1, "note", "Short comment")

    marks.render_for_buffer(bufnr, "new", "test.lua")

    -- header + 1 content line + footer
    assert.equals(3, #box_virt_lines())
  end)
end)
