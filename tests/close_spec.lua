local config = require("review.config")
local export = require("review.export")
local hooks = require("review.hooks")
local store = require("review.store")

-- specs/review-workflow.allium models AuthorClosesReview against an existing
-- session, so closing with nothing open has no specified outcome. It used to
-- reach vim.cmd("tabclose") anyway and surface Neovim's own E784 traceback.
describe("review.close", function()
  local real_lifecycle
  local notifications
  local real_notify
  local real_count, real_generate_markdown
  local created

  -- close() only consults the store to decide whether to export, so stubbing
  -- the count keeps these tests on close()'s branching instead of duplicating
  -- store_spec.lua's coverage of the (async, DuckDB-backed) write path.
  local function pretend_comments_exist(n)
    store.count = function()
      return n
    end
    export.generate_markdown = function()
      return "# stub"
    end
  end

  ---@return number bufnr
  local function new_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    table.insert(created, buf)
    return buf
  end

  ---@return boolean
  local function notified(pattern)
    for _, n in ipairs(notifications) do
      if n.msg:match(pattern) then
        return true
      end
    end
    return false
  end

  before_each(function()
    config.setup()
    store.reset()
    created = {}
    notifications = {}

    real_notify = vim.notify
    vim.notify = function(msg, level, opts)
      table.insert(notifications, { msg = msg, level = level, opts = opts })
    end

    real_count = store.count
    real_generate_markdown = export.generate_markdown

    real_lifecycle = package.loaded["codediff.ui.lifecycle"]
    package.loaded["codediff.ui.lifecycle"] = {
      get_buffers = function()
        return nil, nil
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
    vim.notify = real_notify
    store.count = real_count
    export.generate_markdown = real_generate_markdown
    package.loaded["codediff.ui.lifecycle"] = real_lifecycle
    store.reset()

    for _, buf in ipairs(created) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  describe("with no active session", function()
    it("warns instead of raising Neovim's last-tab error", function()
      assert.has_no.errors(function()
        require("review").close()
      end)

      assert.is_true(notified("No active review session"), "expected a no-session warning")
    end)

    it("leaves the tab it was invoked from open", function()
      local before = #vim.api.nvim_list_tabpages()

      require("review").close()

      assert.equals(before, #vim.api.nvim_list_tabpages())
    end)

    it("does not export comments it never opened a session for", function()
      pretend_comments_exist(1)

      require("review").close()

      assert.is_false(notified("Exported"), "exported without an active session")
    end)
  end)

  describe("with an active session", function()
    before_each(function()
      local orig, mod = new_buf(), new_buf()
      package.loaded["codediff.ui.lifecycle"].get_buffers = function()
        return orig, mod
      end
      hooks.on_session_created(vim.api.nvim_get_current_tabpage())
    end)

    it("still exports accumulated comments to the clipboard", function()
      pretend_comments_exist(1)

      require("review").close()

      assert.is_true(notified("Exported 1 comment"), "close stopped exporting")
    end)

    it("reports rather than raises when the tab cannot be closed", function()
      -- The suite runs in a single-tabpage headless Neovim, so tabclose here
      -- hits the same E784 the no-session path used to surface.
      assert.has_no.errors(function()
        require("review").close()
      end)

      assert.is_true(notified("Could not close review tab"), "expected a tabclose warning")
    end)

    it("ends the session even when the tab could not be closed", function()
      require("review").close()

      assert.is_nil(hooks.get_current_tabpage(), "session outlived close")
    end)
  end)
end)
