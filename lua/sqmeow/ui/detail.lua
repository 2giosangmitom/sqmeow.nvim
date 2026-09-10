--- One row, read down the page instead of across it.
---
--- A grid is the wrong shape for a wide table or a long text column: the value is either truncated
--- or off the side of the window. This shows one row as a list, with each value whole, including
--- the line breaks a grid cell has to flatten.

local M = {}

local buf = nil
local win = nil

local function valid_buf()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Lay a row out as lines.
---
--- A value holding line breaks is indented under its name rather than escaped, because having
--- room for it is the whole point of this view.
---
---@param columns table[] As the engine sends them: name, value, type_name, is_null.
---@return string[]
function M.lines(columns)
  local widest = 0
  for _, column in ipairs(columns) do
    widest = math.max(widest, vim.fn.strdisplaywidth(column.name))
  end

  local lines = {}
  for _, column in ipairs(columns) do
    local padding = (' '):rep(widest - vim.fn.strdisplaywidth(column.name))
    local value = column.is_null and 'NULL' or column.value
    local first, rest = value:match('^([^\n]*)\n(.*)$')

    if first then
      table.insert(lines, ('%s%s  %s'):format(column.name, padding, first))
      for _, continuation in ipairs(vim.split(rest, '\n', { plain = true })) do
        table.insert(lines, ('%s  %s'):format((' '):rep(widest), continuation))
      end
    else
      table.insert(lines, ('%s%s  %s'):format(column.name, padding, value))
    end
  end

  return lines
end

--- The detail buffer, created on first use.
---@return integer
function M.buffer()
  if valid_buf() then
    return buf
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'sqmeow://row')

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'sqmeow-row'
  vim.bo[buf].modifiable = false

  vim.keymap.set('n', 'q', M.close, { buffer = buf, nowait = true, desc = 'sqmeow: Close' })
  return buf
end

--- Show one row of the current result.
---
---@param row integer Zero-based row index within the whole result.
function M.open(row)
  local call = require('sqmeow.state').call
  if not (call and call.call_id) then
    return
  end

  local columns, err = require('sqmeow.rpc').request('row', { call_id = call.call_id, row = row })
  if not columns then
    vim.notify('sqmeow: ' .. (err or 'that row is not there'), vim.log.levels.WARN)
    return
  end

  local lines = M.lines(columns)
  vim.bo[M.buffer()].modifiable = true
  vim.api.nvim_buf_set_lines(M.buffer(), 0, -1, false, lines)
  vim.bo[M.buffer()].modifiable = false

  if not valid_win() then
    local previous = vim.api.nvim_get_current_win()
    vim.cmd('vertical rightbelow split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, M.buffer())

    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].wrap = false

    if vim.api.nvim_win_is_valid(previous) then
      vim.api.nvim_set_current_win(previous)
    end
  end

  vim.wo[win].winbar = ('%%#SqmeowWinbar# row %d '):format(row + 1)
end

--- Hide the detail window.
function M.close()
  if valid_win() then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

--- Whether the detail window is showing.
---@return boolean
function M.is_open()
  return valid_win()
end

return M
