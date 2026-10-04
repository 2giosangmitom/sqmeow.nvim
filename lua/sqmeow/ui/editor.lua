--- Scratchpad buffers.

local M = {}

--- The filetype for each extension a scratchpad can have.
local filetypes = { sql = 'sql', redis = 'redis', json = 'json', surql = 'surql' }

--- Where scratchpads are kept.
---@return string
function M.directory()
  return require('sqmeow.core.paths').scratch()
end

--- A path inside the scratch directory, relative to it with `/` separators.
---@param path string Absolute path.
---@return string rel `notes.sql`, or `reports/monthly.sql` for a nested scratchpad.
function M.relative(path)
  local directory = vim.fs.normalize(M.directory())
  local absolute = vim.fs.normalize(path)
  if absolute:sub(1, #directory + 1) == directory .. '/' then
    return absolute:sub(#directory + 2)
  end
  return absolute
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
--- `name` is a raw filename (`report.sql`, `cache.redis`, `docs.json`); `/` separates
--- folders, so `reports/monthly.sql` is kept in a `reports` folder. `.` and `..` segments
--- are dropped, so a name can never escape the scratch directory.
---@param name string Raw name with extension, optionally with `/` folders.
---@return string
function M.path(name)
  local full = M.directory()
  local parts = {}
  for segment in vim.gsplit(vim.trim(name or ''), '/', { plain = true }) do
    if segment ~= '' and segment ~= '.' and segment ~= '..' then
      table.insert(parts, M.slug(segment))
    end
  end
  if #parts == 0 then
    table.insert(parts, 'scratch')
  end
  for _, part in ipairs(parts) do
    full = vim.fs.joinpath(full, part)
  end
  return full
end

--- Whether a path is somewhere a scratchpad can be: the scratch directory itself or
--- anything under it, so nested scratchpads count.
---@param path string Already normalised.
---@return boolean
local function is_pad_path(path)
  local directory = vim.fs.normalize(M.directory())
  path = vim.fs.normalize(path)
  return path == directory or path:sub(1, #directory + 1) == directory .. '/'
end

--- Whether any component of `path` under the scratch directory is a symlink,
--- checked without following links.
---@param path string Already normalised, and under the scratch directory.
---@return boolean
local function has_symlink_component(path)
  local directory = vim.fs.normalize(M.directory())
  local current = directory
  for segment in path:sub(#directory + 2):gmatch('[^/]+') do
    current = vim.fs.joinpath(current, segment)
    local stat = vim.uv.fs_lstat(current)
    if stat and stat.type == 'link' then
      return true
    end
  end
  return false
end

--- Whether `path` stays inside the scratch directory once symlinks in existing
--- components are resolved. A name that does not exist yet is judged at its
--- nearest existing parent, since what does not exist yet cannot be a link.
---@param path string
---@return boolean
local function is_real_pad_path(path)
  local directory = vim.uv.fs_realpath(M.directory())
  if not directory then
    return false
  end

  local existing = path
  while not vim.uv.fs_lstat(existing) do
    local parent = vim.fs.dirname(existing)
    if parent == existing then
      return false
    end
    existing = parent
  end

  local resolved = vim.uv.fs_realpath(existing)
  return resolved == directory
    or (resolved ~= nil and resolved:sub(1, #directory + 1) == directory .. '/')
end

--- Whether a path is a scratchpad folder: somewhere under the scratch directory,
--- but not the directory itself, and with no symlink on the way there, so
--- folder moves and deletions cannot reach outside the scratch directory
--- through a caller-supplied path.
---@param path string Already normalised.
---@return boolean
local function is_pad_dir(path)
  if not is_pad_path(path) or path == vim.fs.normalize(M.directory()) then
    return false
  end
  return not has_symlink_component(path)
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

--- Every file and folder under the scratch directory, depth-first.
---@return { name: string, path: string, kind: string }[] # `name` is the entry name.
local function walk()
  local directory = M.directory()
  local found = {}

  local function scan(dir)
    local ok, iter = pcall(vim.fs.dir, dir)
    if not (ok and iter) then
      return
    end
    for entry, kind in iter do
      local full = vim.fs.joinpath(dir, entry)
      table.insert(found, { name = entry, path = full, kind = kind })
      if kind == 'directory' then
        scan(full)
      end
    end
  end

  scan(directory)
  return found
end

--- Every folder under the scratch directory, including empty ones, as paths relative
--- to it (`reports`, `reports/2026`). Sorted.
---@return string[]
function M.folders()
  local dirs = {}
  for _, found in ipairs(walk()) do
    if found.kind == 'directory' then
      table.insert(dirs, M.relative(found.path))
    end
  end
  table.sort(dirs)
  return dirs
end

--- Every scratchpad that has been saved, including nested ones.
---@return { name: string, path: string, modified: integer }[] # Most recently written first; `name` is the path relative to the scratch directory (`reports/monthly.sql`).
function M.list()
  local pads = {}

  for _, found in ipairs(walk()) do
    if found.kind == 'file' and M.filetype(found.name) then
      local stat = vim.uv.fs_stat(found.path)
      table.insert(pads, {
        name = M.relative(found.path),
        path = found.path,
        modified = stat and stat.mtime.sec or 0,
      })
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

--- Create a scratchpad and open it. `/` in the name makes folders (`reports/monthly.sql`);
--- a trailing `/` (`reports/`) makes just the folder, opening nothing.
---@param name string Raw name with extension (e.g. `report.sql`, `cache.redis`), optionally with `/` folders.
---@return integer|nil buf Nil for a folder, which has nothing to open.
---@return string|nil error
function M.create(name)
  if vim.trim(name or '') == '' then
    return nil, 'a scratchpad needs a name'
  end

  vim.fn.mkdir(M.directory(), 'p')
  local path = M.path(name)
  -- `M.path` only filters `.` and `..` lexically, so a symlink planted under
  -- the scratch directory could still point the write outside of it.
  if not is_real_pad_path(path) then
    return nil, ('could not create %s'):format(path)
  end

  if vim.trim(name):sub(-1) == '/' then
    vim.fn.mkdir(path, 'p')
    if not vim.uv.fs_stat(path) then
      return nil, ('could not create %s'):format(path)
    end
    return nil, nil
  end

  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  if not vim.uv.fs_stat(path) and vim.fn.writefile({}, path) ~= 0 then
    return nil, ('could not create %s'):format(path)
  end
  return M.open_path(path)
end

--- Rename a scratchpad, moving it across folders when the new name holds `/`.
---@param path string
---@param name string The new relative name (`reports/monthly.sql`).
---@return string|nil renamed Where the scratchpad now is.
---@return string|nil error
function M.rename(path, name)
  path = vim.fs.normalize(path)

  if not is_pad_path(path) or has_symlink_component(path) then
    return nil, ('%s is not a scratchpad'):format(path)
  end
  if not vim.uv.fs_stat(path) then
    return nil, ('there is no scratchpad at %s'):format(path)
  end

  local target = vim.fs.normalize(M.path(name))

  if target == path then
    return target
  end
  if not is_pad_path(target) or target == vim.fs.normalize(M.directory()) then
    return nil, ('`%s` is not a usable scratchpad name'):format(name)
  end
  if not is_real_pad_path(target) then
    return nil, ('`%s` is not a usable scratchpad name'):format(name)
  end
  if vim.uv.fs_stat(target) then
    return nil, ('there is already a scratchpad called %s'):format(M.relative(target))
  end

  vim.fn.mkdir(vim.fs.dirname(target), 'p')
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

  if not is_pad_path(path) or has_symlink_component(path) then
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

--- Every loaded buffer holding a file at or under a directory.
---@param dir string Already normalised.
---@return integer[]
local function buffers_under(dir)
  local prefix = dir .. '/'
  return vim.tbl_filter(function(handle)
    if not vim.api.nvim_buf_is_valid(handle) then
      return false
    end
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(handle))
    return name == dir or name:sub(1, #prefix) == prefix
  end, vim.api.nvim_list_bufs())
end

--- Move a scratchpad folder to a new relative path under the scratch directory,
--- carrying open buffers along.
---@param path string
---@param name string The new relative path (`archive/2026`).
---@return string|nil renamed Where the folder now is.
---@return string|nil error
function M.rename_dir(path, name)
  path = vim.fs.normalize(path)

  if not is_pad_dir(path) then
    return nil, ('%s is not a scratchpad folder'):format(path)
  end
  if not vim.uv.fs_stat(path) then
    return nil, ('there is no scratchpad folder at %s'):format(path)
  end

  local target = vim.fs.normalize(M.path(name))
  if target == path then
    return target
  end
  if not is_pad_dir(target) then
    return nil, ('`%s` is not a usable folder name'):format(name)
  end
  if vim.uv.fs_stat(target) then
    return nil, ('there is already something called %s'):format(M.relative(target))
  end

  vim.fn.mkdir(vim.fs.dirname(target), 'p')
  local ok, err = vim.uv.fs_rename(path, target)
  if not ok then
    return nil, ('could not rename %s: %s'):format(path, err)
  end

  for _, handle in ipairs(buffers_under(path)) do
    local suffix = vim.fs.normalize(vim.api.nvim_buf_get_name(handle)):sub(#path + 1)
    -- Otherwise `:w` writes the scratchpad back under its old folder.
    vim.api.nvim_buf_set_name(handle, target .. suffix)
    vim.api.nvim_buf_call(handle, function()
      vim.cmd('silent! write!')
    end)
  end

  -- Renaming a buffer leaves an unlisted one behind under the old name.
  for _, stale in ipairs(buffers_under(path)) do
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end

  return target
end

--- Delete a scratchpad folder and everything under it.
---@param path string
---@return boolean removed
---@return string|nil error
function M.remove_dir(path)
  path = vim.fs.normalize(path)

  if not is_pad_dir(path) then
    return false, ('%s is not a scratchpad folder'):format(path)
  end
  if not vim.uv.fs_stat(path) then
    return false, ('there is no scratchpad folder at %s'):format(path)
  end

  for _, handle in ipairs(buffers_under(path)) do
    vim.api.nvim_buf_delete(handle, { force = true })
  end

  if vim.fn.delete(path, 'rf') ~= 0 then
    return false, ('could not delete %s'):format(path)
  end
  return true
end

--- Actions the scratchpad's keys are bound to.
M.actions = {
  execute_statement = function()
    require('sqmeow.api.query').execute_statement()
  end,
  execute_selection = function()
    require('sqmeow.api.query').execute_selection()
  end,
  execute_buffer = function()
    require('sqmeow.api.query').execute_buffer()
  end,
  cancel = function()
    require('sqmeow.api.query').cancel()
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

--- Re-bind a buffer to a connection and update the winbar.
---@param target integer
---@param connection string|nil The database this buffer runs against.
function M.rebind(target, connection)
  if not target or not vim.api.nvim_buf_is_valid(target) then
    return false
  end
  vim.b[target].sqmeow_connection = connection
  M.update_winbar()
  return true
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
      local connection, reason = require('sqmeow.api.connection').target(buf)
      local label = connection and require('sqmeow.core.state').label(connection) or reason

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
