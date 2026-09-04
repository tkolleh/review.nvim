local M = {}

local store = require("review.store")
local config = require("review.config")
local normalize_path = require("review.utils").normalize_path

local ns_id = vim.api.nvim_create_namespace("review")
local ns_padding = vim.api.nvim_create_namespace("review_padding")

local MIN_CONTENT_WIDTH = 20
local DEFAULT_CONTENT_WIDTH = 60
-- 4 border/padding columns ("│ " + " │") flank the box's text column.
local BOX_BORDER_OVERHEAD = 4

---@type table<string, string> hex -> lazily-registered highlight group name
local author_hl_cache = {}

---Resolves (and lazily registers) the highlight group for a comment's
---author-derived border color, picking color_dark/color_light per the live
---`:set background` value. Falls back to fallback_hl when the comment
---predates the color columns (an older .duckdb file).
---@param comment table
---@param fallback_hl string
---@return string hl_group
local function resolve_author_hl(comment, fallback_hl)
  local hex = vim.o.background == "light" and comment.color_light or comment.color_dark
  if not hex then
    return fallback_hl
  end

  local cached = author_hl_cache[hex]
  if cached then
    return cached
  end

  local group = "ReviewAuthorBorder_" .. hex:sub(2)
  vim.api.nvim_set_hl(0, group, { fg = hex, default = true })
  author_hl_cache[hex] = group
  return group
end

---Greedily wrap text on whitespace so no rendered line exceeds max_width display
---columns. A single word wider than max_width is hard-split by character rather
---than left to overflow.
---@param text string
---@param max_width number
---@return string[]
local function wrap_line(text, max_width)
  if vim.fn.strdisplaywidth(text) <= max_width then
    return { text }
  end

  local lines = {}
  local current = ""

  local function flush()
    if current ~= "" then
      table.insert(lines, current)
      current = ""
    end
  end

  for word in text:gmatch("%S+") do
    while vim.fn.strdisplaywidth(word) > max_width do
      flush()
      table.insert(lines, vim.fn.strcharpart(word, 0, max_width))
      word = vim.fn.strcharpart(word, max_width)
    end

    local candidate = current == "" and word or (current .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) > max_width then
      flush()
      current = word
    else
      current = candidate
    end
  end
  flush()

  return lines
end

---Resolve the usable text width for boxes rendered against a buffer: the
---width of a window currently displaying it, minus sign/number/fold columns
---and the box's own border overhead. Falls back to a fixed default when the
---buffer isn't shown in any window (e.g. a comment on a file not currently open).
---@param bufnr number
---@return number
local function window_content_width(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return DEFAULT_CONTENT_WIDTH
  end

  local info = vim.fn.getwininfo(winid)[1]
  if not info then
    return DEFAULT_CONTENT_WIDTH
  end

  return math.max(info.width - info.textoff - BOX_BORDER_OVERHEAD, MIN_CONTENT_WIDTH)
end

---@param text string
---@param type_name string
---@param hl string highlights the header label and comment text
---@param max_width number
---@param author_hl string highlights the box-drawing border characters
---@return table[] virt_lines
local function build_comment_box(text, type_name, hl, max_width, author_hl)
  local virt_lines = {}
  local text_lines = vim.split(text, "\n")

  local rendered_lines = {}
  for _, text_line in ipairs(text_lines) do
    vim.list_extend(rendered_lines, wrap_line(text_line, max_width))
  end

  local max_text_width = 0
  for _, rendered_line in ipairs(rendered_lines) do
    max_text_width = math.max(max_text_width, vim.fn.strdisplaywidth(rendered_line))
  end
  local header_text = string.format("[%s]", string.upper(type_name))
  local content_width = math.max(max_text_width, MIN_CONTENT_WIDTH)

  local top_dashes = content_width - vim.fn.strdisplaywidth(header_text) + 1
  table.insert(virt_lines, {
    { "╭─", author_hl },
    { header_text, hl },
    { string.rep("─", top_dashes) .. "╮", author_hl },
  })

  for _, rendered_line in ipairs(rendered_lines) do
    local padding = content_width - vim.fn.strdisplaywidth(rendered_line)
    table.insert(virt_lines, {
      { "│ ", author_hl },
      { rendered_line .. string.rep(" ", padding), hl },
      { " │", author_hl },
    })
  end

  table.insert(virt_lines, { { "╰" .. string.rep("─", content_width + 2) .. "╯", author_hl } })
  return virt_lines
end

---@param bufnr number
---@param side? "old"|"new"
---@param file_override? string file path to use directly instead of parsing buffer name
function M.render_for_buffer(bufnr, side, file_override)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local file
  if file_override then
    file = normalize_path(file_override)
  else
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not bufname or bufname == "" then
      return
    end

    if bufname:match("^codediff://") then
      local path = bufname:match("^codediff://[^/]+/(.+)%?") or bufname:match("^codediff://[^/]+/(.+)$")
      if path then
        file = normalize_path(path)
      end
    else
      file = normalize_path(vim.fn.fnamemodify(bufname, ":."))
    end
  end

  if not file then
    return
  end

  local comments = store.get_for_file(file, side)

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local cfg = config.get()
  local max_width = window_content_width(bufnr)

  for _, comment in ipairs(comments) do
    local type_info = cfg.comment_types[comment.type]
    local icon = type_info and type_info.icon or "●"
    local hl = type_info and type_info.hl or "ReviewSign"
    local line_hl = type_info and type_info.line_hl
    local name = type_info and type_info.name or comment.type
    local author_hl = resolve_author_hl(comment, hl)
    local virt_lines = build_comment_box(comment.text, name, hl, max_width, author_hl)

    if comment.line == 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, 0, 0, {
        sign_text = icon,
        sign_hl_group = hl,
        virt_lines = virt_lines,
        virt_lines_above = true,
        virt_lines_overflow = "scroll",
      })
      -- Scroll windows to reveal virt_lines above row 0
      local virt_line_count = #virt_lines
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
          vim.api.nvim_win_call(win, function()
            local view = vim.fn.winsaveview()
            if view.topline <= 1 then
              view.topfill = virt_line_count
              vim.fn.winrestview(view)
            end
          end)
        end
      end
    else
      local line_start = comment.line - 1
      local line_end_0 = (comment.line_end or comment.line) - 1
      local is_range = line_end_0 ~= line_start

      if line_start >= 0 then
        if is_range then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_start, 0, {
            sign_text = icon,
            sign_hl_group = hl,
            line_hl_group = line_hl,
          })

          for l = line_start + 1, line_end_0 - 1 do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, l, 0, {
              line_hl_group = line_hl,
            })
          end

          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_end_0, 0, {
            line_hl_group = line_hl,
            virt_lines = virt_lines,
            virt_lines_above = false,
            virt_lines_overflow = "scroll",
          })
        else
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_start, 0, {
            sign_text = icon,
            sign_hl_group = hl,
            line_hl_group = line_hl,
            virt_lines = virt_lines,
            virt_lines_above = false,
            virt_lines_overflow = "scroll",
          })
        end
      end
    end
  end
end

---@param comment table
---@param max_width number
---@return number height, number attach_line (0-indexed)
local function comment_box_height(comment, max_width)
  local text_lines = vim.split(comment.text, "\n")
  local rendered_line_count = 0
  for _, text_line in ipairs(text_lines) do
    rendered_line_count = rendered_line_count + #wrap_line(text_line, max_width)
  end
  local height = rendered_line_count + 2 -- + top and bottom border lines
  local attach_line
  if comment.line == 0 then
    attach_line = 0
  else
    attach_line = (comment.line_end or comment.line) - 1
  end
  return height, attach_line
end

---@param orig_buf number
---@param mod_buf number
---@param orig_file string|nil
---@param mod_file string|nil
function M.align_buffers(orig_buf, mod_buf, orig_file, mod_file)
  if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
    vim.api.nvim_buf_clear_namespace(orig_buf, ns_padding, 0, -1)
  end
  if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
    vim.api.nvim_buf_clear_namespace(mod_buf, ns_padding, 0, -1)
  end

  if not orig_buf or not mod_buf
    or not vim.api.nvim_buf_is_valid(orig_buf)
    or not vim.api.nvim_buf_is_valid(mod_buf)
    or (not orig_file and not mod_file) then
    return
  end

  -- Skip file comments (line 0): they render identically on both sides, so
  -- they never cause a height mismatch that needs padding
  local function build_height_map(bufnr, file, side)
    if not file then return {} end
    local max_width = window_content_width(bufnr)
    local map = {}
    for _, comment in ipairs(store.get_for_file(file, side)) do
      if comment.line ~= 0 and (comment.side or "new") == side then
        local height, attach_line = comment_box_height(comment, max_width)
        map[attach_line] = (map[attach_line] or 0) + height
      end
    end
    return map
  end

  local old_map = build_height_map(orig_buf, orig_file, "old")
  local new_map = build_height_map(mod_buf, mod_file, "new")

  local all_lines = {}
  for line in pairs(old_map) do all_lines[line] = true end
  for line in pairs(new_map) do all_lines[line] = true end

  for line in pairs(all_lines) do
    local old_h = old_map[line] or 0
    local new_h = new_map[line] or 0
    local diff = old_h - new_h

    if diff ~= 0 then
      local target_buf = diff > 0 and mod_buf or orig_buf
      local pad_count = math.abs(diff)
      local padding = {}
      for _ = 1, pad_count do
        table.insert(padding, { { "", "Normal" } })
      end
      pcall(vim.api.nvim_buf_set_extmark, target_buf, ns_padding, line, 0, {
        virt_lines = padding,
        virt_lines_above = false,
      })
    end
  end
end

function M.refresh()
  local ok, hooks = pcall(require, "review.hooks")
  if not ok then
    return
  end

  local orig_buf, mod_buf = hooks.get_buffers()
  local orig_path, mod_path = hooks.get_paths()
  if orig_buf then
    M.render_for_buffer(orig_buf, "old", orig_path)
  end
  if mod_buf then
    M.render_for_buffer(mod_buf, "new", mod_path)
  end

  if orig_buf and mod_buf and (orig_path or mod_path) then
    M.align_buffers(orig_buf, mod_buf, orig_path, mod_path)
  end
end

function M.clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_padding, 0, -1)
    end
  end
end

return M
