local M = {}

local marks = require("review.marks")
local config = require("review.config")
local store = require("review.store")
local normalize_path = require("review.utils").normalize_path

---@type number|nil Current tabpage with active codediff session
local current_tabpage = nil

---@type number|nil Autocmd group for buffer events
local buf_augroup = nil

---@type uv.uv_timer_t|nil Background poll picking up external writers'
---(e.g. an agent's) concurrent comments while a review session is open
local sync_timer = nil

---@class ReviewEditability
---@field modifiable boolean
---@field readonly boolean

---@type table<number, ReviewEditability> Editability each locked buffer had
---before this session locked it, keyed by bufnr. codediff renders the modified
---side of a diff in the working tree file's own buffer, and modifiable/readonly
---are buffer-scoped, so a lock we never release follows that buffer into
---unrelated editing (georgeguimaraes/review.nvim#38).
local prior_editability = {}

local SYNC_POLL_INTERVAL_MS = 3000

local function start_sync_timer()
  if sync_timer then
    return
  end
  sync_timer = vim.uv.new_timer()
  sync_timer:start(SYNC_POLL_INTERVAL_MS, SYNC_POLL_INTERVAL_MS, function()
    store.sync_from_storage(function(ok)
      if ok then
        vim.schedule(marks.refresh)
      end
    end)
  end)
end

local function stop_sync_timer()
  if not sync_timer then
    return
  end
  sync_timer:stop()
  sync_timer:close()
  sync_timer = nil
end

---Lock a buffer against edits, recording what it displaced.
---Recorded once per buffer: codediff re-emits its file-selected event for a
---buffer we already locked, and re-recording would capture our own lock as
---though it were the reviewer's prior state.
---@param bufnr number|nil
local function lock_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not prior_editability[bufnr] then
    prior_editability[bufnr] = {
      modifiable = vim.bo[bufnr].modifiable,
      readonly = vim.bo[bufnr].readonly,
    }
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

---Restore every buffer this session locked to the editability it had before.
---Restoring is not the same as making editable -- a diff's original side is a
---synthetic buffer that was already non-modifiable.
local function release_buffers()
  for bufnr, prior in pairs(prior_editability) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modifiable = prior.modifiable
      vim.bo[bufnr].readonly = prior.readonly
    end
  end
  prior_editability = {}
end

---Set syntax highlighting for a buffer based on file path.
---Uses treesitter directly instead of setting filetype to avoid triggering
---FileType autocmds that other plugins (e.g. render-markdown.nvim) use to
---attach to buffers, which can interfere with review popups.
---@param bufnr number
---@param path string|nil
local function set_buffer_filetype(bufnr, path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not path or path == "" then
    return
  end

  local ft = vim.filetype.match({ filename = path, buf = bufnr })
  if ft then
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local ts_ok = pcall(vim.treesitter.start, bufnr, lang)
    if not ts_ok then
      vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
    end
  end
end

---@return number|nil tabpage id
function M.get_current_tabpage()
  return current_tabpage
end

---@return table|nil codediff lifecycle module
local function get_lifecycle()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  return lifecycle
end

---@return table|nil codediff session
function M.get_session()
  if not current_tabpage then
    return nil
  end
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  return lifecycle.get_session(current_tabpage)
end

---Coerce a path value to a plain string.
---@param path string|table|nil
---@return string|nil
local function to_path_string(path)
  if type(path) ~= "table" then
    return path
  end
  if path.absolute and path.absolute ~= "" then
    return path.absolute
  end
  return path.relative
end

---Relativize a path against the git root for consistent storage/lookup
---@param path string|table|nil
---@param lifecycle table
---@param tabpage number
---@return string|nil
local function relativize_path(path, lifecycle, tabpage)
  path = to_path_string(path)
  if not path then
    return nil
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  if git_ctx and git_ctx.git_root then
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(
      abs:gsub("^" .. vim.pesc(git_ctx.git_root) .. "/", "")
    )
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---@return string|nil file path
---@return number|nil line number
---@return "old"|"new"|nil side
function M.get_cursor_position()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil, nil
  end

  local sess = lifecycle.get_session(current_tabpage)
  if not sess then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_buf = vim.api.nvim_get_current_buf()

  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(current_tabpage)

  local file_path
  local side
  if current_buf == orig_buf then
    file_path = orig_path
    side = "old"
  elseif current_buf == mod_buf then
    file_path = mod_path
    side = "new"
  else
    local bufname = vim.api.nvim_buf_get_name(current_buf)
    if bufname and bufname ~= "" then
      if bufname:match("^codediff://") then
        file_path = mod_path or orig_path
      else
        file_path = vim.fn.fnamemodify(bufname, ":.")
      end
    end
  end

  if not file_path then
    return nil, nil, nil
  end

  return relativize_path(file_path, lifecycle, current_tabpage), cursor[1], side
end

---@return string|nil file path
---@return number|nil start line
---@return number|nil end line
---@return "old"|"new"|nil side
function M.get_visual_range()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file, _, side = M.get_cursor_position()
  if not file then
    return nil, nil, nil, nil
  end

  return file, start_line, end_line, side
end

---@return number|nil original buffer
---@return number|nil modified buffer
function M.get_buffers()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  return lifecycle.get_buffers(current_tabpage)
end

---@return string|nil original path
---@return string|nil modified path
function M.get_paths()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  return relativize_path(orig_path, lifecycle, current_tabpage),
    relativize_path(mod_path, lifecycle, current_tabpage)
end

function M.on_session_created(tabpage)
  current_tabpage = tabpage
  start_sync_timer()

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)

  -- Needed here since commit reviews build buffers without going through
  -- normal file-open filetype detection
  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, to_path_string(raw_orig_path))
  set_buffer_filetype(mod_buf, to_path_string(raw_mod_path))

  local cfg = config.get()
  if cfg.codediff.readonly then
    lock_buffer(orig_buf)
    lock_buffer(mod_buf)
  end

  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
  end
  buf_augroup =
    vim.api.nvim_create_augroup("review_buf_marks", { clear = true })

  -- Re-render on BufEnter too, in case the initial deferred render below
  -- ran before these buffers existed
  vim.api.nvim_create_autocmd("BufEnter", {
    group = buf_augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= current_tabpage then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(current_tabpage)
      if bufnr ~= ob and bufnr ~= mb then
        return
      end
      marks.refresh()
    end,
  })

  -- Deferred since buffers may not be fully ready immediately after session creation
  vim.defer_fn(function()
    marks.refresh()
  end, 100)

  vim.defer_fn(function()
    M._focus_modified_pane(lifecycle, tabpage)
  end, 150)
end

function M._focus_modified_pane(lifecycle, tabpage)
  local cur_cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
  if cur_cfg.relative ~= "" then
    return
  end
  local sess = lifecycle.get_session(tabpage)
  if
    sess
    and sess.modified_win
    and vim.api.nvim_win_is_valid(sess.modified_win)
  then
    vim.api.nvim_set_current_win(sess.modified_win)
  end
end

function M.on_session_closed()
  current_tabpage = nil
  stop_sync_timer()
  release_buffers()
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("review.keymaps").cleanup()
end

function M.on_file_changed(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)

  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, to_path_string(raw_orig_path))
  set_buffer_filetype(mod_buf, to_path_string(raw_mod_path))

  local cfg = config.get()
  if cfg.codediff.readonly then
    lock_buffer(orig_buf)
    lock_buffer(mod_buf)
  end

  vim.defer_fn(function()
    marks.refresh()
  end, 50)
end

return M
