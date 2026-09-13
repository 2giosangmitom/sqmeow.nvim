--- Scratchpad buffers.
---
--- Files under `core.path`, created only when asked for: `a` in the drawer, `:Sqmeow scratch`, or
--- `<Plug>(sqmeow-scratch)`. Each lives in a folder named after its connection, which is what ties
--- it to that database, and has the extension of what the connection speaks: `.sql`, or `.redis`.
--- Real files rather than scratch buffers, so they survive a restart, `:w` does what `:w` always
--- does, and every SQL plugin the user already has keeps working in them.
---
--- A file straight under the directory and named after a connection is how scratchpads were kept
--- before they had folders. It is still listed, and still tied to that connection.

local M = {}

--- The filetype for each extension a scratchpad can have.
local filetypes = { sql = 'sql', redis = 'redis' }

--- Where scratchpads are kept.
---@return string
function M.directory()
  return require('sqmeow.paths').scratch()
end

--- Turn a connection or scratchpad name into something safe to use as a file name.
---
---@param name string
---@return string
function M.slug(name)
  local slug = name:gsub('[^%w%-_%.]', '-'):gsub('%-+', '-'):gsub('^%-', ''):gsub('%-$', '')
  return slug == '' and 'scratch' or slug
end

--- The filetype a scratchpad file opens with, or nil for a file that is not one.
---
---@param path string
---@return string|nil
function M.filetype(path)
  return filetypes[path:match('%.(%w+)$') or '']
end

--- What a connection speaks, whether it is open or only saved.
---@param name string
---@return string|nil
local function dialect_of(name)
  local dialects = require('sqmeow.dialects')
  local open = require('sqmeow.state').connection_by_name(name)
  if open then
    return open.dialect or (open.url and dialects.of_url(open.url))
  end
  local spec = require('sqmeow.sources').find(name)
  return spec and dialects.of_url(spec.url) or nil
end

--- Where a connection's scratchpad of this name is kept.
---
--- The extension follows the connection's dialect, so a Redis script is not opened as SQL.
---
---@param connection string Connection name.
---@param name string Scratchpad name, without an extension.
---@return string
function M.path(connection, name)
  local extension = dialect_of(connection) == 'redis' and 'redis' or 'sql'
  return vim.fs.joinpath(M.directory(), M.slug(connection), M.slug(name) .. '.' .. extension)
end

--- Whether a path is somewhere a scratchpad can be: in the directory, or one folder below it.
---
--- Every rename and delete is checked against this, because a path from anywhere else reaching
--- them would change a file nobody was asked about.
---
---@param path string Already normalised.
---@return boolean
local function is_pad_path(path)
  local directory = vim.fs.normalize(M.directory())
  local parent = vim.fs.dirname(path)
  return parent == directory or vim.fs.dirname(parent) == directory
end

--- The connection a scratchpad belongs to.
---
--- The folder it is in names the connection. A file straight under the directory is one from
--- before folders, and its own name does instead. Every connection the plugin knows about is
--- checked, open or merely saved, so a scratchpad written for a database that is not open still
--- knows which one it wants.
---
---@param path string
---@return string|nil name
function M.connection_for(path)
  path = vim.fs.normalize(path)
  if not is_pad_path(path) then
    return nil
  end

  local parent = vim.fs.dirname(path)
  local slug = parent == vim.fs.normalize(M.directory()) and vim.fn.fnamemodify(path, ':t:r')
    or vim.fs.basename(parent)

  for _, connection in ipairs(require('sqmeow.state').connection_list()) do
    if M.slug(connection.name) == slug then
      return connection.name
    end
  end
  for _, spec in ipairs((require('sqmeow.sources').load())) do
    if M.slug(spec.name) == slug then
      return spec.name
    end
  end
  return nil
end

--- Every loaded buffer holding one file.
---
---@param path string Already normalised.
---@return integer[]
function M.buffers_for(path)
  return vim.tbl_filter(function(handle)
    return vim.api.nvim_buf_is_valid(handle)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(handle)) == path
  end, vim.api.nvim_list_bufs())
end

--- Every scratchpad that has been saved.
---
--- Read from the directory each time rather than remembered, so one written in another Neovim, or
--- deleted outside the editor, is right without a refresh.
---
---@return { name: string, path: string, folder: string|nil, modified: integer }[] # Most recently
--- written first. `folder` is the connection folder it is in, and nil for one from before folders.
function M.list()
  local directory = M.directory()
  local pads = {}

  local function add(path, folder)
    local stat = vim.uv.fs_stat(path)
    table.insert(pads, {
      name = vim.fn.fnamemodify(path, ':t:r'),
      path = path,
      folder = folder,
      modified = stat and stat.mtime.sec or 0,
    })
  end

  for entry, kind in vim.fs.dir(directory) do
    local path = vim.fs.joinpath(directory, entry)
    if kind == 'file' and M.filetype(entry) then
      add(path, nil)
    elseif kind == 'directory' then
      for inner, inner_kind in vim.fs.dir(path) do
        if inner_kind == 'file' and M.filetype(inner) then
          add(vim.fs.joinpath(path, inner), entry)
        end
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
---
--- Used by the drawer, which already knows where the file is and should not have to turn a name
--- back into one.
---
--- The window is chosen rather than assumed. A plain `:edit` opens in the current window, and the
--- current window when the drawer's `<CR>` fires is the drawer itself, which would put a file
--- where the tree was.
---
---@param path string
---@return integer buf
function M.open_path(path)
  require('sqmeow.ui.layout').editing_window()
  vim.cmd.edit(vim.fn.fnameescape(path))

  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = M.filetype(path) or 'sql'
  M.attach(buf, M.connection_for(path))
  return buf
end

--- Create a scratchpad for a connection, and open it.
---
--- The file is written straight away, empty, so the drawer lists it before anything is typed. A
--- name that is already taken opens that scratchpad rather than failing: somewhere to write under
--- that name is what was asked for, and it is there.
---
---@param connection string Connection name.
---@param name string
---@return integer|nil buf
---@return string|nil error
function M.create(connection, name)
  if vim.trim(name or '') == '' then
    return nil, 'a scratchpad needs a name'
  end

  local path = M.path(connection, name)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  if not vim.uv.fs_stat(path) and vim.fn.writefile({}, path) ~= 0 then
    return nil, ('could not create %s'):format(path)
  end
  return M.open_path(path)
end

--- Rename a scratchpad.
---
--- The new name goes through the same slug as every other one, so a name typed with a slash or a
--- space cannot land outside the scratchpad's folder or produce a file nobody can open again. The
--- folder and the extension stay, so a renamed scratchpad keeps its connection and its filetype.
---
---@param path string
---@param name string The new name, without the extension.
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
  local extension = path:match('%.(%w+)$') or 'sql'
  local target = vim.fs.normalize(vim.fs.joinpath(folder, slug .. '.' .. extension))

  if target == path then
    return target
  end
  -- The slug should make this impossible. Checked anyway, because the cost of being wrong is
  -- writing over a file somewhere else on the disk.
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
    -- A buffer still holding the old path would write the scratchpad back under its old name on
    -- the next `:w`. Renaming it and writing once settles it: the file is already there, so an
    -- ordinary write would refuse, and the contents are what was just renamed.
    vim.api.nvim_buf_set_name(handle, target)
    vim.api.nvim_buf_call(handle, function()
      vim.cmd('silent! write!')
    end)
  end

  -- Renaming a buffer leaves an unlisted one behind under the old name, which would put the old
  -- scratchpad back if anything ever wrote it.
  for _, stale in ipairs(M.buffers_for(path)) do
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end

  return target
end

--- Delete a scratchpad.
---
--- The buffer goes with the file. Leaving it loaded would write the scratchpad back on the next
--- `:w`, which is a confusing way to learn that a delete did not stick.
---
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
---
--- Only scratchpads get these. A user's own `.sql` file is theirs, and taking `<CR>` in it would
--- be an unpleasant surprise; `<Plug>(sqmeow-execute)` is there for that.
---
---@param target integer
---@param connection string|nil The database this buffer runs against, whatever else is active.
function M.attach(target, connection)
  require('sqmeow.keymap').apply('editor', target, M.actions)
  vim.b[target].sqmeow_editor = true
  vim.b[target].sqmeow_connection = connection
  M.update_winbar()
end

--- Say which database the buffer under the cursor will run against.
---
--- On the scratchpad rather than only on the result window, because the result window may be
--- closed, or showing something from another database entirely, at the moment someone presses
--- `<CR>`. The one place a person is looking when they run a query is the query.
function M.update_winbar()
  if not require('sqmeow.config').get().ui.winbar then
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    -- Scratchpads, and any other buffer someone has tied to a connection with `:Sqmeow bind`.
    if M.is_scratchpad(buf) or vim.b[buf].sqmeow_connection then
      local connection, reason = require('sqmeow.api').target(buf)
      local label = connection and ('%s (%s)'):format(connection.name, connection.dialect or '?')
        or reason

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
