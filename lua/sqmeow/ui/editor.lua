--- Scratchpad buffers.
---
--- One file per connection, under `stdpath('data')`, opened as an ordinary buffer with the `sql`
--- filetype. A real file rather than a scratch buffer, so it survives a restart, `:w` does what
--- `:w` always does, and every SQL plugin the user already has keeps working in it.

local M = {}

--- Where scratchpads are kept.
---@return string
function M.directory()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow', 'scratch')
end

--- Turn a connection name into something safe to use as a file name.
---
---@param name string
---@return string
function M.slug(name)
  local slug = name:gsub('[^%w%-_%.]', '-'):gsub('%-+', '-'):gsub('^%-', ''):gsub('%-$', '')
  return slug == '' and 'scratch' or slug
end

--- The scratchpad file for a connection.
---
---@param name string|nil Connection name. Defaults to the current connection.
---@return string
function M.path(name)
  if not name then
    local connection = require('sqmeow.state').current_connection()
    name = connection and connection.name or 'scratch'
  end
  return vim.fs.joinpath(M.directory(), M.slug(name) .. '.sql')
end

--- The connection a scratchpad belongs to.
---
--- Worked out from the file name, which is the connection's own name run through `M.slug`. Every
--- connection the plugin knows about is checked, open or merely saved, so a scratchpad written for
--- a database that is not open still knows which one it wants.
---
---@param path string
---@return string|nil name
function M.connection_for(path)
  local slug = vim.fn.fnamemodify(path, ':t:r')

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
---@return { name: string, path: string, modified: integer }[] # Most recently written first.
function M.list()
  local directory = M.directory()
  local pads = {}

  for entry, kind in vim.fs.dir(directory) do
    if kind == 'file' and entry:sub(-4) == '.sql' then
      local path = vim.fs.joinpath(directory, entry)
      local stat = vim.uv.fs_stat(path)
      table.insert(pads, {
        name = entry:sub(1, -5),
        path = path,
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
---
--- Used by the drawer, which already knows where the file is and should not have to turn a name
--- back into one.
---
--- The window is chosen rather than assumed. A plain `:edit` opens in the current window, and the
--- current window when the drawer's `<CR>` fires is the drawer itself, which would put a SQL file
--- where the tree was.
---
---@param path string
---@return integer buf
function M.open_path(path)
  require('sqmeow.ui.layout').editing_window()
  vim.cmd.edit(vim.fn.fnameescape(path))

  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = 'sql'
  M.attach(buf, M.connection_for(path))
  return buf
end

--- Show a statement in a buffer of its own.
---
--- Used for a query out of the log whose rows the engine no longer holds. A scratch buffer rather
--- than the connection's scratchpad, so nothing anyone wrote is overwritten, and it carries the
--- scratchpad's keys so running it again is `<CR>`.
---
---@param statement string
---@param connection string|nil The connection it last ran on, so it goes back to the same one.
---@return integer buf
function M.open_statement(statement, connection)
  require('sqmeow.ui.layout').editing_window()

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(statement, '\n', { plain = true }))
  vim.bo[buf].filetype = 'sql'
  vim.bo[buf].bufhidden = 'wipe'

  vim.api.nvim_win_set_buf(0, buf)
  M.attach(buf, connection)
  return buf
end

--- Rename a scratchpad.
---
--- The new name goes through the same slug as every other one, so a name typed with a slash or a
--- space cannot land outside the scratchpad directory or produce a file nobody can open again.
---
---@param path string
---@param name string The new name, without the extension.
---@return string|nil renamed Where the scratchpad now is.
---@return string|nil error
function M.rename(path, name)
  path = vim.fs.normalize(path)
  local directory = vim.fs.normalize(M.directory())

  if vim.fs.dirname(path) ~= directory then
    return nil, ('%s is not a scratchpad'):format(path)
  end
  if not vim.uv.fs_stat(path) then
    return nil, ('there is no scratchpad at %s'):format(path)
  end

  local slug = M.slug(name)
  local target = vim.fs.normalize(vim.fs.joinpath(directory, slug .. '.sql'))

  if target == path then
    return target
  end
  -- The slug should make this impossible. Checked anyway, because the cost of being wrong is
  -- writing over a file somewhere else on the disk.
  if vim.fs.dirname(target) ~= directory then
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

  -- Only ever a file this plugin wrote. A path from anywhere else reaching here would delete
  -- something nobody was asked about.
  if vim.fs.dirname(path) ~= vim.fs.normalize(M.directory()) then
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

--- Open the scratchpad for a connection.
---
---@param name string|nil Connection name. Defaults to the current connection.
---@return integer buf
function M.open(name)
  vim.fn.mkdir(M.directory(), 'p')
  return M.open_path(M.path(name))
end

--- Whether a buffer is one of ours.
---@param target integer|nil Defaults to the current buffer.
---@return boolean
function M.is_scratchpad(target)
  return vim.b[target or 0].sqmeow_editor == true
end

return M
