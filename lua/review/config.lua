local M = {}

---@class ReviewConfig
---@field comment_types table<string, CommentType>
---@field keymaps ReviewKeymaps

---@class CommentType
---@field key string
---@field name string
---@field icon string
---@field hl string
---@field line_hl string

---@class ReviewKeymaps
---@field add_comment string|false
---@field add_file_comment string|false
---@field delete_comment string|false
---@field edit_comment string|false
---@field next_comment string|false
---@field prev_comment string|false
---@field list_comments string|false
---@field export_clipboard string|false
---@field send_sidekick string|false
---@field clear_comments string|false
---@field close string|false
---@field show_help string|false
---@field popup_submit string|false
---@field popup_cancel string|false
---@field popup_cycle_type string|false

---@type ReviewConfig
M.defaults = {
  comment_types = {
    note = { key = "n", name = "Note", icon = "📝", hl = "ReviewNote", line_hl = "ReviewNoteLine" },
    suggestion = { key = "s", name = "Suggestion", icon = "💡", hl = "ReviewSuggestion", line_hl = "ReviewSuggestionLine" },
    issue = { key = "i", name = "Issue", icon = "⚠️", hl = "ReviewIssue", line_hl = "ReviewIssueLine" },
    praise = { key = "p", name = "Praise", icon = "✨", hl = "ReviewPraise", line_hl = "ReviewPraiseLine" },
  },
  keymaps = {
    -- Comment actions
    add_comment = "<localleader>c",
    add_file_comment = "<localleader>f",
    edit_comment = "<localleader>e",
    delete_comment = "<localleader>d",
    -- Navigation
    next_comment = "]n",
    prev_comment = "[n",
    -- Common actions
    list_comments = "c",
    export_clipboard = "C",
    send_sidekick = "S",
    clear_comments = "<C-r>",
    close = "q",
    -- Help
    show_help = "?",
    -- Popup keymaps
    popup_submit = "<C-s>",
    popup_cancel = "q",
    popup_cycle_type = "<Tab>",
  },
}

---@type ReviewConfig
M.config = vim.deepcopy(M.defaults)

---@param opts? ReviewConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

---@return ReviewConfig
function M.get()
  return M.config
end

return M
