local M = {}

local store = require("review.store")
local hooks = require("review.hooks")
local popup = require("review.popup")
local marks = require("review.marks")

local function notify(msg, level)
  vim.notify(msg, level, { title = "review.nvim" })
end

---@return string
local function current_user()
  local user = vim.fn.expand("$USER")
  return (user ~= "" and user ~= "$USER") and user or "user"
end

---@param initial_type? "note"|"suggestion"|"issue"|"praise"
function M.add_at_cursor(initial_type)
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  popup.open(initial_type or "note", nil, function(comment_type, text)
    if comment_type and text then
      store.add(file, line, comment_type, text, nil, side, current_user(), function(_, err)
        if err then
          notify(string.format("Failed to add comment: %s", err), vim.log.levels.ERROR)
          return
        end
        marks.refresh()
        notify(string.format("Added %s comment", comment_type), vim.log.levels.INFO)
      end)
    end
  end)
end

-- Alias for backwards compatibility
function M.add_with_menu()
  M.add_at_cursor()
end

---@param initial_type? "note"|"suggestion"|"issue"|"praise"
function M.file_comment(initial_type)
  local file = hooks.get_cursor_position()
  if not file then
    notify("Could not determine file", vim.log.levels.WARN)
    return
  end

  local existing = store.get_file_comment(file, current_user())
  if existing then
    popup.open(existing.type, existing.text, function(new_type, text)
      if new_type and text then
        store.update(existing.id, existing.text, text, new_type, function(ok, err)
          if not ok then
            notify(string.format("Failed to update file comment: %s", err or "not found"), vim.log.levels.ERROR)
            return
          end
          marks.refresh()
          notify("File comment updated", vim.log.levels.INFO)
        end)
      end
    end)
  else
    popup.open(initial_type or "note", nil, function(comment_type, text)
      if comment_type and text then
        store.add(file, 0, comment_type, text, nil, nil, current_user(), function(_, err)
          if err then
            notify(string.format("Failed to add file comment: %s", err), vim.log.levels.ERROR)
            return
          end
          marks.refresh()
          notify(string.format("Added %s file comment", comment_type), vim.log.levels.INFO)
        end)
      end
    end)
  end
end

---@param initial_type? "note"|"suggestion"|"issue"|"praise"
function M.add_for_range(initial_type)
  local file, start_line, end_line, side = hooks.get_visual_range()
  if not file or not start_line or not end_line then
    notify("Could not determine visual selection", vim.log.levels.WARN)
    return
  end

  popup.open(initial_type or "note", nil, function(comment_type, text)
    if comment_type and text then
      store.add(file, start_line, comment_type, text, end_line, side, current_user(), function(_, err)
        if err then
          notify(string.format("Failed to add comment: %s", err), vim.log.levels.ERROR)
          return
        end
        marks.refresh()
        notify(string.format("Added %s comment", comment_type), vim.log.levels.INFO)
      end)
    end
  end)
end

---Resolves the comment at the cursor that `current_user()` may act on,
---prompting with a picker when more than one comment exists at that
---file/line and the author owns none or more than one of them
---(specs/review-storage.allium SelectingAmbiguousComment).
---@param file string
---@param line number
---@param callback fun(comment: Comment)
local function resolve_target_comment(file, line, callback)
  if line == 1 then
    local file_comment = store.get_file_comment(file, current_user())
    if file_comment then
      callback(file_comment)
      return
    end
  end

  local selected, needs_explicit = store.select_ambiguous_comment(file, line, current_user())
  if selected then
    callback(selected)
    return
  end

  if not needs_explicit then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  local candidates = store.get_all_at_line(file, line)

  vim.ui.select(candidates, {
    prompt = "Multiple comments here. Choose one:",
    format_item = function(comment)
      return string.format("[%s] %s: %s", comment.type, comment.author, comment.text)
    end,
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

function M.edit_at_cursor()
  local file, line = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  resolve_target_comment(file, line, function(comment)
    popup.open(comment.type, comment.text, function(new_type, text)
      if new_type and text then
        store.update(comment.id, comment.text, text, new_type, function(ok, err)
          if not ok then
            notify(
              err == "stale" and "Comment was changed by someone else; edit cancelled"
                or string.format("Failed to update comment: %s", err or "not found"),
              vim.log.levels.ERROR
            )
            return
          end
          marks.refresh()
          notify("Comment updated", vim.log.levels.INFO)
        end)
      end
    end)
  end)
end

function M.delete_at_cursor()
  local file, line = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  resolve_target_comment(file, line, function(comment)
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete this comment?",
    }, function(choice)
      if choice == "Yes" then
        store.delete(comment.id, comment.text, function(ok, err)
          if not ok then
            notify(
              err == "stale" and "Comment was changed by someone else; delete cancelled"
                or string.format("Failed to delete comment: %s", err or "not found"),
              vim.log.levels.ERROR
            )
            return
          end
          marks.refresh()
          notify("Comment deleted", vim.log.levels.INFO)
        end)
      end
    end)
  end)
end

function M.goto_next()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for _, comment in ipairs(comments) do
    if comment.line > line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("No more comments in this file", vim.log.levels.INFO)
end

function M.goto_prev()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for i = #comments, 1, -1 do
    local comment = comments[i]
    if comment.line < line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("No previous comments in this file", vim.log.levels.INFO)
end

function M.list()
  local config = require("review.config").get()
  local all_comments = store.get_all()

  if #all_comments == 0 then
    notify("No comments yet", vim.log.levels.INFO)
    return
  end

  -- Build display items
  local items = {}
  for _, comment in ipairs(all_comments) do
    local type_info = config.comment_types[comment.type]
    local icon = type_info and type_info.icon or "●"
    local name = type_info and type_info.name or comment.type
    local location
    local is_old = (comment.side or "new") == "old"
    if comment.line == 0 then
      location = comment.file
    elseif is_old then
      if comment.line_end and comment.line_end ~= comment.line then
        location = string.format("%s:~%d-~%d", comment.file, comment.line, comment.line_end)
      else
        location = string.format("%s:~%d", comment.file, comment.line)
      end
    elseif comment.line_end and comment.line_end ~= comment.line then
      location = string.format("%s:%d-%d", comment.file, comment.line, comment.line_end)
    else
      location = string.format("%s:%d", comment.file, comment.line)
    end
    local display = string.format("%s %s [%s] %s", icon, location, name, comment.text)
    table.insert(items, { display = display, comment = comment })
  end

  -- Show picker
  vim.ui.select(items, {
    prompt = "Comments:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if not choice then
      return
    end

    local comment = choice.comment

    -- Try to navigate to the file in codediff explorer
    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if ok then
      local tabpage = hooks.get_current_tabpage()
      if tabpage then
        local explorer = lifecycle.get_explorer(tabpage)
        if explorer then
          local explorer_mod = require("codediff.ui.explorer")
          -- Find and select the file in explorer
          -- This is a best-effort navigation
          for i, node in ipairs(explorer.tree:get_nodes()) do
            if node.path == comment.file then
              explorer_mod.select_node(explorer, node)
              break
            end
          end
        end
      end
    end

    -- Jump to line after a short delay (line 1 for file-level comments)
    vim.defer_fn(function()
      local target_line = comment.line == 0 and 1 or comment.line
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    end, 100)
  end)
end

return M
