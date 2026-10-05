--- Displays a result row vertically in a popup.

local M = {}

local utils = require('sqmeow.core.utils')

local popup = nil

-- Cap type-name width to leave room for values.
local TYPE_WIDTH = 16

--- Lay a row out as lines, each value on one line and cut to fit.
---@param columns table[] As the engine sends them, each with `key` from the result's columns.
---@param width integer The width the lines have to fit in.
---@return NuiLine[]
function M.lines(columns, width)
  local Line = require('nui.line')
  local truncate = require('sqmeow.core.utils').truncate
  local config = require('sqmeow.config').get()
  local ellipsis = config.icons.grid.ellipsis

  local types = {}
  local name_width, type_width = 0, 0
  for index, column in ipairs(columns) do
    -- Reserve space for the PK/FK suffix before truncating the type name.
    local key = ({ primary_key = ' (PK)', foreign_key = ' (FK)' })[column.key] or ''
    local declared = column.declared_type or column.type_name or ''
    types[index] = truncate(declared, TYPE_WIDTH - #key, ellipsis) .. key

    name_width = math.max(name_width, vim.api.nvim_strwidth(column.name))
    type_width = math.max(type_width, vim.api.nvim_strwidth(types[index]))
  end

  local value_width = math.max(width - name_width - type_width - 4, 1)
  local lines = {}
  for index, column in ipairs(columns) do
    local line = Line()
    local name_pad = (' '):rep(name_width - vim.api.nvim_strwidth(column.name) + 2)
    local type_pad = (' '):rep(type_width - vim.api.nvim_strwidth(types[index]) + 2)
    line:append(column.name .. name_pad, 'SqmeowDetailName')
    line:append(types[index] .. type_pad, 'SqmeowDetailType')

    if column.is_null then
      line:append(config.ui.result.null_text, 'SqmeowNull')
    else
      -- Keep each value on one line.
      local value = column.value:gsub('[\r\n]', ' ')
      line:append(truncate(value, value_width, ellipsis))
    end
    lines[index] = line
  end

  return lines
end

--- Show one row of the current result.
---@param row integer Zero-based row index within the whole result.
function M.open(row)
  local call = require('sqmeow.core.state').call
  if not (call and call.call_id) then
    return
  end

  local columns, err =
    require('sqmeow.rpc.client').request('row', { call_id = call.call_id, row = row })
  if not columns then
    utils.notify(err or 'that row is not there', vim.log.levels.WARN)
    return
  end

  -- Copy key metadata from the result's column definitions.
  for index, column in ipairs(columns) do
    local described = call.columns and call.columns[index]
    column.key = described and described.key
  end

  M.close()
  local width = math.floor(vim.o.columns * 0.8)
  local lines = M.lines(columns, width)
  local opened, open_err = require('sqmeow.ui.popup').open({
    title = ' Row details ',
    lines = lines,
    width = width,
    height = math.max(math.min(#columns, math.floor(vim.o.lines * 0.8)), 1),
    filetype = 'sqmeow-row',
    on_close = M.close,
  })
  if not opened then
    return utils.notify(open_err or 'could not open the popup', vim.log.levels.ERROR)
  end
  popup = opened
end

--- Close the popup.
function M.close()
  -- Clear popup before unmounting: BufLeave can call close() again.
  local closing = popup
  popup = nil
  if closing then
    closing:unmount()
  end
end

return M
