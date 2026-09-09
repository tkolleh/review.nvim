local M = {}

local config = require("review.config")
local comments = require("review.comments")
local export = require("review.export")

-- Track which buffers have keymaps set and what keys were mapped
local keymapped_buffers = {}

--- Check if a keymap is enabled (not false, nil, or empty string)
---@param key string|false|nil
---@return boolean
local function is_enabled(key)
  return key ~= nil and key ~= false and key ~= ""
end

--- Capture a pre-existing buffer-local mapping so it can be restored later.
--- maparg()/mapset() only ever operate on the current buffer, so both this
--- and the restore in del_keymap must hop into bufnr's context explicitly.
---@param bufnr number
---@param mode string
---@param lhs string
---@return table|nil
local function capture_prior_mapping(bufnr, mode, lhs)
  local prior
  vim.api.nvim_buf_call(bufnr, function()
    local existing = vim.fn.maparg(lhs, mode, false, true)
    if existing.buffer == 1 then
      prior = existing
    end
  end)
  return prior
end

--- Delete a keymap from a buffer if it exists, restoring whatever
--- buffer-local mapping review's own setup displaced.
---@param bufnr number
---@param mode string
---@param lhs string|nil
---@param prior table|nil
local function del_keymap(bufnr, mode, lhs, prior)
  if lhs and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
    if prior then
      vim.api.nvim_buf_call(bufnr, function()
        pcall(vim.fn.mapset, prior)
      end)
    end
  end
end

--- Delete all tracked keymaps from a buffer
---@param bufnr number
local function clear_buffer_keymaps(bufnr)
  local tracked = keymapped_buffers[bufnr]
  if tracked then
    for _, entry in ipairs(tracked) do
      del_keymap(bufnr, entry[1], entry[2], entry[3])
    end
  end
end

--- Format a keymap string for display
---@param key string
---@return string
local function format_key(key)
  local inner = key:match("^<(.+)>$")
  if not inner then return key end
  if inner:lower() == "leader" or inner:lower() == "localleader" then return key end

  -- Handle modifiers: C- -> Ctrl-, S- stays as S-
  inner = inner:gsub("^C%-", "Ctrl-")
  return inner
end

--- Build help lines for a section
---@param entries {key: string, desc: string}[]
---@param title string
---@param lines string[]
---@param max_key_width number
local function add_section(entries, title, lines, max_key_width)
  if #entries == 0 then return end
  table.insert(lines, "")
  table.insert(lines, "  " .. title)
  for _, entry in ipairs(entries) do
    local padding = string.rep(" ", max_key_width - #entry.key + 3)
    table.insert(lines, "   " .. entry.key .. padding .. entry.desc)
  end
end

local help_popup = nil

local function close_help()
  if help_popup then
    help_popup:unmount()
    help_popup = nil
  end
end

local function show_help()
  if help_popup then
    close_help()
    return
  end

  local cfg = config.get()
  local km = cfg.keymaps

  local comment_entries = {}
  local nav_entries = {}
  local action_entries = {}

  local function entry(key_name, desc, tbl)
    local key = km[key_name]
    if not is_enabled(key) then return end
    table.insert(tbl, { key = format_key(key), desc = desc })
  end

  entry("add_comment", "Add comment (pick type)", comment_entries)
  entry("add_file_comment", "File comment", comment_entries)
  entry("edit_comment", "Edit comment", comment_entries)
  entry("delete_comment", "Delete comment", comment_entries)

  entry("next_comment", "Next comment", nav_entries)
  entry("prev_comment", "Previous comment", nav_entries)
  entry("list_comments", "List comments", nav_entries)

  entry("export_clipboard", "Export to clipboard", action_entries)
  entry("send_sidekick", "Send to sidekick", action_entries)
  entry("clear_comments", "Clear all", action_entries)
  entry("close", "Export & close review", action_entries)
  entry("show_help", "This help", action_entries)
  table.insert(action_entries, { key = "t", desc = "Toggle layout" })
  table.insert(action_entries, { key = "g?", desc = "Codediff help" })

  local all_entries = {}
  vim.list_extend(all_entries, comment_entries)
  vim.list_extend(all_entries, nav_entries)
  vim.list_extend(all_entries, action_entries)

  local max_key_width = 0
  for _, e in ipairs(all_entries) do
    max_key_width = math.max(max_key_width, #e.key)
  end

  local lines = {}
  add_section(comment_entries, "Comments", lines, max_key_width)
  add_section(nav_entries, "Navigation", lines, max_key_width)
  add_section(action_entries, "Actions", lines, max_key_width)
  table.insert(lines, "")

  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, #line)
  end

  local width = math.max(max_line_width + 2, 30)
  local height = #lines

  local Popup = require("nui.popup")
  help_popup = Popup({
    position = "50%",
    size = { width = width, height = height },
    border = {
      style = "rounded",
      text = {
        top = " Review Keymaps ",
        top_align = "center",
      },
    },
    buf_options = {
      modifiable = false,
      buftype = "nofile",
    },
  })

  help_popup:mount()

  local buf = help_popup.bufnr
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  vim.api.nvim_set_current_win(help_popup.winid)

  local map_opts = { noremap = true, nowait = true }
  help_popup:map("n", "?", close_help, map_opts)
  help_popup:map("n", "q", close_help, map_opts)
  help_popup:map("n", "<Esc>", close_help, map_opts)
end

---@param bufnr number
local function set_buffer_keymaps(bufnr)
  clear_buffer_keymaps(bufnr)

  local cfg = config.get()
  local km = cfg.keymaps
  local mapped = {}

  local function set(lhs, rhs, desc)
    if is_enabled(lhs) then
      local prior = capture_prior_mapping(bufnr, "n", lhs)
      vim.keymap.set("n", lhs, rhs, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = desc })
      table.insert(mapped, { "n", lhs, prior })
    end
  end

  local function set_visual(lhs, rhs, desc)
    if is_enabled(lhs) then
      local prior = capture_prior_mapping(bufnr, "x", lhs)
      vim.keymap.set("x", lhs, rhs, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = desc })
      table.insert(mapped, { "x", lhs, prior })
    end
  end

  set(km.add_comment, function() comments.add_with_menu() end, "Add comment (pick type)")
  set_visual(km.add_comment, ":<C-u>lua require('review.comments').add_for_range()<CR>", "Add comment for selection")
  set(km.add_file_comment, function() comments.file_comment() end, "File comment")
  set(km.delete_comment, function() comments.delete_at_cursor() end, "Delete comment")
  set(km.edit_comment, function() comments.edit_at_cursor() end, "Edit comment")
  set(km.list_comments, function() comments.list() end, "List all comments")
  set(km.export_clipboard, function() export.to_clipboard() end, "Export to clipboard")
  set(km.send_sidekick, function() export.to_sidekick() end, "Send to sidekick")
  set(km.clear_comments, function() require("review").clear_comments() end, "Clear all comments")
  set(km.next_comment, function() comments.goto_next() end, "Next comment")
  set(km.prev_comment, function() comments.goto_prev() end, "Previous comment")

  set(km.close, function() require("review").close() end, "Close")
  set(km.show_help, show_help, "Show help")

  keymapped_buffers[bufnr] = mapped
end

local augroup = nil

---@param tabpage number
function M.setup_keymaps(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    vim.notify("codediff.ui.lifecycle not available", vim.log.levels.WARN, { title = "review.nvim" })
    return
  end

  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
  end
  augroup = vim.api.nvim_create_augroup("review_keymaps", { clear = true })

  for bufnr in pairs(keymapped_buffers) do
    clear_buffer_keymaps(bufnr)
  end
  keymapped_buffers = {}

  set_buffer_keymaps(vim.api.nvim_get_current_buf())

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= tabpage then return end
      -- Skip floating windows (popups) to avoid overriding their keymaps
      local win_config = vim.api.nvim_win_get_config(0)
      if win_config.relative ~= "" then return end
      if not lifecycle.get_session(tabpage) then return end
      -- Only apply review keymaps to codediff diff buffers, not the explorer
      local bufnr = vim.api.nvim_get_current_buf()
      local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
      if bufnr ~= orig_buf and bufnr ~= mod_buf then return end
      set_buffer_keymaps(bufnr)
    end,
  })

  -- codediff renders the modified side in the working-tree file's own buffer,
  -- so without this, review's buffer-local keymaps stay live in any other tab
  -- that opens the same file. TabLeave fires before the tab switch, so
  -- nvim_get_current_tabpage() here still reflects the tab being left.
  vim.api.nvim_create_autocmd("TabLeave", {
    group = augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= tabpage then return end
      M.clear_keymaps()
    end,
  })
end

function M.clear_keymaps()
  for bufnr in pairs(keymapped_buffers) do
    clear_buffer_keymaps(bufnr)
  end
  keymapped_buffers = {}
end

function M.cleanup()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  close_help()
  M.clear_keymaps()
end

M._test = {
  format_key = format_key,
  add_section = add_section,
  is_enabled = is_enabled,
}

return M
