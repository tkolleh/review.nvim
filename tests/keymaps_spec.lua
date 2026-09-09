local keymaps = require("review.keymaps")
local config = require("review.config")

-- Covers the readonly-only-and-bracket-keymaps plan's target keymap table:
-- comment actions collapsed to a single <localleader> letter each, and the
-- motions that scheme frees up (e, f, F, i, d) left untouched by review so
-- they fall through to Neovim's built-ins.
describe("keymaps single-letter comment scheme", function()
  local orig_buf, mod_buf
  local real_lifecycle
  local km

  local function is_mapped(lhs)
    local mapping = vim.fn.maparg(lhs, "n", false, true)
    return not vim.tbl_isempty(mapping)
  end

  before_each(function()
    config.setup()
    km = config.get().keymaps

    orig_buf = vim.api.nvim_create_buf(false, true)
    mod_buf = vim.api.nvim_create_buf(false, true)

    real_lifecycle = package.loaded["codediff.ui.lifecycle"]
    package.loaded["codediff.ui.lifecycle"] = {
      get_session = function()
        return { modified_win = vim.api.nvim_get_current_win() }
      end,
      get_buffers = function()
        return orig_buf, mod_buf
      end,
    }

    vim.api.nvim_set_current_buf(mod_buf)
    keymaps.setup_keymaps(vim.api.nvim_get_current_tabpage())
  end)

  after_each(function()
    keymaps.cleanup()
    package.loaded["codediff.ui.lifecycle"] = real_lifecycle

    for _, buf in ipairs({ orig_buf, mod_buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("binds the four localleader comment actions", function()
    assert.is_true(is_mapped(km.add_comment), "add_comment not bound")
    assert.is_true(is_mapped(km.add_file_comment), "add_file_comment not bound")
    assert.is_true(is_mapped(km.edit_comment), "edit_comment not bound")
    assert.is_true(is_mapped(km.delete_comment), "delete_comment not bound")
  end)

  it("leaves the freed motions e, f, F, i, d with no buffer-local mapping", function()
    for _, key in ipairs({ "e", "f", "F", "i", "d" }) do
      assert.is_false(is_mapped(key), key .. " should have no buffer-local mapping")
    end
  end)

  it("no longer binds the removed toggle_readonly and file-panel keys", function()
    for _, key in ipairs({ "R", "<Tab>", "<S-Tab>" }) do
      assert.is_false(is_mapped(key), key .. " should have no buffer-local mapping")
    end
  end)
end)
