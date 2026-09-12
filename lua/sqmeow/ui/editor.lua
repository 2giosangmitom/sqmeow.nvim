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
--- Used by the drawer and the picker, both of which already know where the file is and should not
--- have to turn a name back into one.
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
  M.attach(buf)
  return buf
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

  for _, handle in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(handle)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(handle)) == path
    then
      vim.api.nvim_buf_delete(handle, { force = true })
    end
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
function M.attach(target)
  require('sqmeow.keymap').apply('editor', target, M.actions)
  vim.b[target].sqmeow_editor = true
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
