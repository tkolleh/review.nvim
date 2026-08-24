local hooks = require("review.hooks")
local keymaps = require("review.keymaps")
local config = require("review.config")

describe("hooks focus behavior", function()
  local mod_buf, mod_win, other_win

  before_each(function()
    mod_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, { "new line" })

    other_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    mod_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(mod_win, mod_buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(mod_buf) then
      vim.api.nvim_buf_delete(mod_buf, { force = true })
    end

    while #vim.api.nvim_tabpage_list_wins(0) > 1 do
      vim.cmd("quit")
    end
  end)

  it("focuses the modified pane normally", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_win(other_win)
    assert.equals(other_win, vim.api.nvim_get_current_win())

    local lifecycle = {
      get_session = function()
        return { modified_win = mod_win }
      end,
    }

    hooks._focus_modified_pane(lifecycle, tabpage)

    assert.equals(mod_win, vim.api.nvim_get_current_win())
  end)

  it("should not steal focus from floating windows", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_win(other_win)

    local lifecycle = {
      get_session = function()
        return { modified_win = mod_win }
      end,
    }

    -- Stub nvim_win_get_config to simulate current window being a float
    local original_get_config = vim.api.nvim_win_get_config
    vim.api.nvim_win_get_config = function(win)
      if win == vim.api.nvim_get_current_win() then
        return { relative = "cursor", width = 40, height = 5 }
      end
      return original_get_config(win)
    end

    hooks._focus_modified_pane(lifecycle, tabpage)

    -- Focus should stay on the current window, not jump to mod_win
    assert.equals(other_win, vim.api.nvim_get_current_win())

    vim.api.nvim_win_get_config = original_get_config
  end)
end)

describe("keymaps explorer leak prevention", function()
  local orig_buf, mod_buf, explorer_buf
  local real_lifecycle
  local close_key

  before_each(function()
    config.setup()
    close_key = config.get().keymaps.close

    orig_buf = vim.api.nvim_create_buf(false, true)
    mod_buf = vim.api.nvim_create_buf(false, true)
    explorer_buf = vim.api.nvim_create_buf(false, true)

    real_lifecycle = package.loaded["codediff.ui.lifecycle"]
    package.loaded["codediff.ui.lifecycle"] = {
      get_session = function()
        return { modified_win = vim.api.nvim_get_current_win() }
      end,
      get_buffers = function()
        return orig_buf, mod_buf
      end,
    }
  end)

  after_each(function()
    keymaps.cleanup()
    package.loaded["codediff.ui.lifecycle"] = real_lifecycle

    for _, buf in ipairs({ orig_buf, mod_buf, explorer_buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("does not leak review keymaps onto the explorer buffer", function()
    local tabpage = vim.api.nvim_get_current_tabpage()

    vim.api.nvim_set_current_buf(mod_buf)
    keymaps.setup_keymaps(tabpage)

    -- Simulate the explorer buffer receiving focus, as codediff does
    -- when a file is selected in the explorer sidebar.
    vim.api.nvim_set_current_buf(explorer_buf)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = explorer_buf })

    local mapping = vim.fn.maparg(close_key, "n", false, true)
    assert.is_true(vim.tbl_isempty(mapping), "review keymap leaked onto explorer buffer")
  end)

  it("still applies review keymaps on the codediff diff buffers", function()
    local tabpage = vim.api.nvim_get_current_tabpage()

    vim.api.nvim_set_current_buf(orig_buf)
    keymaps.setup_keymaps(tabpage)

    vim.api.nvim_set_current_buf(mod_buf)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = mod_buf })

    local mapping = vim.fn.maparg(close_key, "n", false, true)
    assert.is_false(vim.tbl_isempty(mapping), "review keymap missing from codediff diff buffer")
  end)
end)
