local hooks = require("review.hooks")
local config = require("review.config")

-- Covers specs/review-workflow.allium's NoEditabilityLeak guarantee: every
-- buffer a session locked comes back to the editability it had before,
-- because codediff renders the modified side of a diff in the working tree
-- file's own buffer (georgeguimaraes/review.nvim#38).
describe("diff buffer editability", function()
  local real_lifecycle
  local pair
  local created

  ---@return number bufnr
  local function new_buf(modifiable)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = modifiable
    table.insert(created, buf)
    return buf
  end

  ---@return boolean modifiable, boolean readonly
  local function editability(buf)
    return vim.bo[buf].modifiable, vim.bo[buf].readonly
  end

  before_each(function()
    config.setup()
    created = {}
    pair = {}

    real_lifecycle = package.loaded["codediff.ui.lifecycle"]
    package.loaded["codediff.ui.lifecycle"] = {
      get_buffers = function()
        return pair[1], pair[2]
      end,
      get_paths = function()
        return nil, nil
      end,
      get_session = function()
        return nil
      end,
      get_git_context = function()
        return nil
      end,
    }
  end)

  after_each(function()
    hooks.on_session_closed()
    package.loaded["codediff.ui.lifecycle"] = real_lifecycle

    for _, buf in ipairs(created) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("locks the diff buffers while the session is open", function()
    local orig, mod = new_buf(true), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(vim.api.nvim_get_current_tabpage())

    for _, buf in ipairs({ orig, mod }) do
      local modifiable, readonly = editability(buf)
      assert.is_false(modifiable, "buffer should be locked during review")
      assert.is_true(readonly, "buffer should be readonly during review")
    end
  end)

  it("restores an editable buffer when the session closes", function()
    local orig, mod = new_buf(true), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(vim.api.nvim_get_current_tabpage())
    hooks.on_session_closed()

    for _, buf in ipairs({ orig, mod }) do
      local modifiable, readonly = editability(buf)
      assert.is_true(modifiable, "buffer left non-modifiable after close")
      assert.is_false(readonly, "buffer left readonly after close")
    end
  end)

  it("leaves an already non-modifiable buffer non-modifiable", function()
    -- The original side of a diff is a synthetic buffer codediff creates
    -- non-modifiable; forcing it editable on close is as wrong as leaving
    -- the working tree buffer locked.
    local orig, mod = new_buf(false), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(vim.api.nvim_get_current_tabpage())
    hooks.on_session_closed()

    assert.is_false((editability(orig)), "synthetic buffer wrongly made editable")
    assert.is_true((editability(mod)), "working tree buffer left non-modifiable")
  end)

  it("restores every file the session visited, not just the last", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local a_orig, a_mod = new_buf(true), new_buf(true)
    local b_orig, b_mod = new_buf(true), new_buf(true)

    pair = { a_orig, a_mod }
    hooks.on_session_created(tabpage)

    pair = { b_orig, b_mod }
    hooks.on_file_changed(tabpage)

    hooks.on_session_closed()

    for _, buf in ipairs({ a_orig, a_mod, b_orig, b_mod }) do
      local modifiable, readonly = editability(buf)
      assert.is_true(modifiable, "a visited file was left non-modifiable")
      assert.is_false(readonly, "a visited file was left readonly")
    end
  end)

  it("does not record its own lock when codediff re-selects a file", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig, mod = new_buf(true), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(tabpage)
    hooks.on_file_changed(tabpage)
    hooks.on_file_changed(tabpage)

    hooks.on_session_closed()

    for _, buf in ipairs({ orig, mod }) do
      local modifiable, readonly = editability(buf)
      assert.is_true(modifiable, "re-selection overwrote the recorded state")
      assert.is_false(readonly, "re-selection overwrote the recorded state")
    end
  end)

  it("restores what the session displaced even after toggling edit mode", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig, mod = new_buf(true), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(tabpage)

    -- Toggling is a live reviewer affordance, not a handover of the buffer:
    -- it must not disturb what close restores, however often it is used.
    require("review").toggle_readonly()
    require("review").toggle_readonly()

    hooks.on_session_closed()

    for _, buf in ipairs({ orig, mod }) do
      local modifiable, readonly = editability(buf)
      assert.is_true(modifiable, "toggling lost the recorded state")
      assert.is_false(readonly, "toggling lost the recorded state")
    end
  end)

  it("skips locking when readonly mode is disabled", function()
    config.setup({ codediff = { readonly = false } })
    local orig, mod = new_buf(true), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(vim.api.nvim_get_current_tabpage())

    for _, buf in ipairs({ orig, mod }) do
      local modifiable, readonly = editability(buf)
      assert.is_true(modifiable, "buffer locked despite readonly = false")
      assert.is_false(readonly, "buffer locked despite readonly = false")
    end
  end)

  it("tolerates a buffer wiped mid-session", function()
    local orig, mod = new_buf(true), new_buf(true)
    pair = { orig, mod }

    hooks.on_session_created(vim.api.nvim_get_current_tabpage())
    vim.api.nvim_buf_delete(orig, { force = true })

    assert.has_no.errors(function()
      hooks.on_session_closed()
    end)
    assert.is_true((editability(mod)), "surviving buffer not restored")
  end)
end)
