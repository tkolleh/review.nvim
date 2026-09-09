local store = require("review.store")
local comments = require("review.comments")
local hooks = require("review.hooks")
local helpers = require("tests.helpers")

-- codediff.nvim v2.67.2 renamed lifecycle.get_explorer to get_panel_view and
-- folded the panel object into a descriptor, so a session's side panel is now
-- either the file explorer or the commit-history panel. Only the explorer's
-- view has the tree shape codediff.ui.explorer's actions expect.
--
-- Step 0 of the readonly-only-and-bracket-keymaps plan deleted review's own
-- next_file/prev_file/toggle_file_panel keymaps (pure re-wraps of codediff's
-- ]f/[f/<leader>b) along with their get_panel_view call sites. The one
-- surviving call site is comments.lua's M.list(), which navigates the
-- explorer to the selected comment's file -- this file's coverage moved to
-- exercise that instead.
describe("codediff panel view access via :Review list", function()
  local orig_buf, mod_buf
  local real_lifecycle, real_explorer, original_select, original_get_current_tabpage
  local panel_name, selected
  local created

  ---@return number bufnr
  local function new_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    table.insert(created, buf)
    return buf
  end

  before_each(function()
    store.clear()
    created = {}
    panel_name = "explorer"
    selected = {}

    orig_buf, mod_buf = new_buf(), new_buf()

    real_lifecycle = package.loaded["codediff.ui.lifecycle"]
    real_explorer = package.loaded["codediff.ui.explorer"]
    original_get_current_tabpage = hooks.get_current_tabpage

    hooks.get_current_tabpage = function()
      return vim.api.nvim_get_current_tabpage()
    end

    package.loaded["codediff.ui.lifecycle"] = {
      get_panel_name = function()
        return panel_name
      end,
      get_panel_view = function()
        return { tree = { get_nodes = function() return { { path = "src/main.lua" } } end } }
      end,
    }

    package.loaded["codediff.ui.explorer"] = {
      select_node = function(_, node)
        table.insert(selected, node)
      end,
    }

    helpers.add(store, "src/main.lua", 1, "note", "seed")

    original_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1])
    end
  end)

  after_each(function()
    vim.ui.select = original_select
    hooks.get_current_tabpage = original_get_current_tabpage
    package.loaded["codediff.ui.lifecycle"] = real_lifecycle
    package.loaded["codediff.ui.explorer"] = real_explorer

    for _, buf in ipairs(created) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("navigates the explorer to the selected comment's file", function()
    assert.has_no.errors(function()
      comments.list()
    end)

    assert.equals(1, #selected, "select_node was not reached")
    assert.equals("src/main.lua", selected[1].path)
  end)

  it("does not hand a history-panel view to the explorer's select_node", function()
    panel_name = "history"

    assert.has_no.errors(function()
      comments.list()
    end)

    assert.equals(0, #selected, "history panel view leaked into explorer navigation")
  end)

  it("no-ops rather than erroring when there is no side panel", function()
    panel_name = nil

    assert.has_no.errors(function()
      comments.list()
    end)

    assert.equals(0, #selected)
  end)

  it("falls back to get_explorer on codediff.nvim older than v2.67.2", function()
    package.loaded["codediff.ui.lifecycle"] = {
      get_panel_name = function()
        return "explorer"
      end,
      get_explorer = function()
        return { tree = { get_nodes = function() return { { path = "src/main.lua" } } end } }
      end,
    }

    assert.has_no.errors(function()
      comments.list()
    end)

    assert.equals(1, #selected, "compat shim did not fall back to get_explorer")
  end)
end)
