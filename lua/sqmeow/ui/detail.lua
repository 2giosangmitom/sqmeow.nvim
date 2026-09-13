--- One row, read down the page instead of across it.
---
--- A grid is the wrong shape for a wide table or a long text column: the value is either truncated
--- or off the side of the window. This shows one row as a list, with each value whole, including
--- the line breaks a grid cell has to flatten.
---
--- The lines are laid out here rather than by `nui.table`, which is what draws the grid. A table
--- puts each row on one line, and a value holding line breaks is exactly what this view exists to
--- show whole, so the one component that would otherwise fit is the one that cannot.

local M = {}

local split = nil

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

--- The split the row is shown in, or nil with a message when nui is not installed.
local function build()
  local ok, Split = pcall(require, 'nui.split')
  if not ok then
    return nil, 'sqmeow: the row detail needs nui.nvim (MunifTanjim/nui.nvim)'
  end

  return Split({
    relative = 'editor',
    position = 'right',
    size = '40%',
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'hide',
      swapfile = false,
      filetype = 'sqmeow-row',
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = 'no',
      wrap = false,
    },
  })
end

--- The detail buffer, or nil when the view has never been opened.
---@return integer|nil
function M.buffer()
  return split and split.bufnr or nil
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

  if not split then
    local built, build_err = build()
    if not built then
      return vim.notify(build_err, vim.log.levels.ERROR)
    end
    split = built
  end

  local previous = vim.api.nvim_get_current_win()
  split:mount()
  split:map('n', 'q', M.close, { nowait = true })

  vim.bo[split.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(split.bufnr, 0, -1, false, M.lines(columns))
  vim.bo[split.bufnr].modifiable = false

  vim.wo[split.winid].winbar = ('%%#SqmeowWinbar# row %d '):format(row + 1)

  -- Opening a detail should not steal the cursor from the grid it was opened from.
  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

--- Hide the detail window.
function M.close()
  if split then
    split:unmount()
  end
  split = nil
end

--- Whether the detail window is showing.
---@return boolean
function M.is_open()
  return split ~= nil and split.winid ~= nil and vim.api.nvim_win_is_valid(split.winid)
end

return M
