--- Scratchpad buffers.

local M = {}

--- The filetype for each extension a scratchpad can have.
local filetypes = { sql = 'sql', redis = 'redis', json = 'json' }

--- Where scratchpads are kept.
---@return string
function M.directory()
  return require('sqmeow.paths').scratch()
end

--- Turn a scratchpad name into something safe to use as a file name.
---@param name string
---@return string
function M.slug(name)
  local slug = name:gsub('[^%w%-_%.]', '-'):gsub('%-+', '-'):gsub('^%-', ''):gsub('%-$', '')
  return slug == '' and 'scratch' or slug
end

--- The filetype a scratchpad file opens with, or nil for a file that is not one.
---@param path string
---@return string|nil
function M.filetype(path)
  return filetypes[path:match('%.(%w+)$') or '']
end

--- Where a scratchpad of this name is kept.
--- `name` is a raw filename (`report.sql`, `cache.redis`, `docs.json`).
---@param name string Raw filename with extension.
---@return string
function M.path(name)
  return vim.fs.joinpath(M.directory(), M.slug(vim.trim(name)))
end

--- Whether a path is somewhere a scratchpad can be.
---@param path string Already normalised.
---@return boolean
local function is_pad_path(path)
  local directory = vim.fs.normalize(M.directory())
  return vim.fs.normalize(vim.fs.dirname(path)) == directory
end

--- Every loaded buffer holding one file.
---@param path string Already normalised.
---@return integer[]
function M.buffers_for(path)
  return vim.tbl_filter(function(handle)
    return vim.api.nvim_buf_is_valid(handle)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(handle)) == path
  end, vim.api.nvim_list_bufs())
end

--- Every scratchpad that has been saved.
---@return { name: string, path: string, modified: integer }[] # Most recently written first.
function M.list()
  local directory = M.directory()
  local pads = {}

  local function add(path)
    local stat = vim.uv.fs_stat(path)
    table.insert(pads, {
      name = vim.fn.fnamemodify(path, ':t'),
      path = path,
      modified = stat and stat.mtime.sec or 0,
    })
  end

  local ok, iter = pcall(vim.fs.dir, directory)
  if ok and iter then
    for entry, kind in iter do
      if kind == 'file' and M.filetype(entry) then
        add(vim.fs.joinpath(directory, entry))
      end
    end
  end

  table.sort(pads, function(left, right)
    if left.modified ~= right.modified then
      return left.modified > right.modified
    end
    return left.name < right.name
  end)
  return pads
end

--- Open a scratchpad by its path.
---@param path string
---@return integer buf
function M.open_path(path)
  require('sqmeow.ui.layout').editing_window()
  vim.cmd.edit(vim.fn.fnameescape(path))

  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = M.filetype(path) or 'sql'
  M.attach(buf, nil)
  return buf
end

--- Create a scratchpad and open it.
---@param name string Raw filename with extension (e.g. `report.sql`, `cache.redis`).
---@return integer|nil buf
---@return string|nil error
function M.create(name)
  if vim.trim(name or '') == '' then
    return nil, 'a scratchpad needs a name'
  end

  local path = M.path(name)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  if not vim.uv.fs_stat(path) and vim.fn.writefile({}, path) ~= 0 then
    return nil, ('could not create %s'):format(path)
  end
  return M.open_path(path)
end

--- Rename a scratchpad.
---@param path string
---@param name string The new raw filename.
---@return string|nil renamed Where the scratchpad now is.
---@return string|nil error
function M.rename(path, name)
  path = vim.fs.normalize(path)

  if not is_pad_path(path) then
    return nil, ('%s is not a scratchpad'):format(path)
  end
  if not vim.uv.fs_stat(path) then
    return nil, ('there is no scratchpad at %s'):format(path)
  end

  local folder = vim.fs.dirname(path)
  local slug = M.slug(name)
  local target = vim.fs.normalize(vim.fs.joinpath(folder, slug))

  if target == path then
    return target
  end
  -- The slug should make this impossible.
  if vim.fs.dirname(target) ~= folder then
    return nil, ('`%s` is not a usable scratchpad name'):format(name)
  end
  if vim.uv.fs_stat(target) then
    return nil, ('there is already a scratchpad called %s'):format(slug)
  end

  local ok, err = vim.uv.fs_rename(path, target)
  if not ok then
    return nil, ('could not rename %s: %s'):format(path, err)
  end

  for _, handle in ipairs(M.buffers_for(path)) do
    -- Otherwise `:w` writes the scratchpad back under its old name.
    vim.api.nvim_buf_set_name(handle, target)
    vim.api.nvim_buf_call(handle, function()
      vim.cmd('silent! write!')
    end)
  end

  -- Renaming a buffer leaves an unlisted one behind under the old name.
  for _, stale in ipairs(M.buffers_for(path)) do
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end

  return target
end

--- Delete a scratchpad.
---@param path string
---@return boolean removed
---@return string|nil error
function M.remove(path)
  path = vim.fs.normalize(path)

  if not is_pad_path(path) then
    return false, ('%s is not a scratchpad'):format(path)
  end
  if not vim.uv.fs_stat(path) then
    return false, ('there is no scratchpad at %s'):format(path)
  end

  for _, handle in ipairs(M.buffers_for(path)) do
    vim.api.nvim_buf_delete(handle, { force = true })
  end

  if vim.fn.delete(path) ~= 0 then
    return false, ('could not delete %s'):format(path)
  end
  return true
end

--- Actions the scratchpad's keys are bound to.
M.actions = {
  execute_statement = function()
    require('sqmeow.api').execute_statement()
  end,
  execute_selection = function()
    -- Leave visual mode first, so the `<` and `>` marks describe what was selected.
    vim.cmd('normal! \27')
    require('sqmeow.api').execute_selection()
  end,
  execute_buffer = function()
    require('sqmeow.api').execute_buffer()
  end,
  cancel = function()
    require('sqmeow.api').cancel()
  end,
  help = function()
    require('sqmeow.ui.help').open('editor')
  end,
}

--- Bind the scratchpad's keys in a buffer.
---@param target integer
---@param connection string|nil The database this buffer runs against, whatever else is active.
function M.attach(target, connection)
  require('sqmeow.keymap').apply('editor', target, M.actions)
  vim.b[target].sqmeow_editor = true
  vim.b[target].sqmeow_connection = connection
  M.update_winbar()
end

--- Say which database the buffer under the cursor will run against.
function M.update_winbar()
  if not require('sqmeow.config').get().ui.winbar then
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    -- Scratchpads, and any other buffer someone has tied to a connection with `:Sqmeow bind`.
    if M.is_scratchpad(buf) or vim.b[buf].sqmeow_connection then
      local connection, reason = require('sqmeow.api').target(buf)
      local label = connection and require('sqmeow.state').label(connection) or reason

      vim.wo[win].winbar = ('%%#SqmeowWinbar# %s %%*'):format(label)
    end
  end
end

--- Whether a buffer is one of ours.
---@param target integer|nil Defaults to the current buffer.
---@return boolean
function M.is_scratchpad(target)
  return vim.b[target or 0].sqmeow_editor == true
end

return M
