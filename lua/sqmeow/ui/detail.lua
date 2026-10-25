--- Displays a result row vertically in a popup.

local M = {}

local utils = require('sqmeow.core.utils')

local popup = nil
local current_columns = nil
local line_columns = nil

-- Cap type-name width to leave room for values.
local TYPE_WIDTH = 16

--- Lay a row out as lines, showing full values without truncating or flattening newlines.
---@param columns table[] As the engine sends them, each with `key` from the result's columns.
---@param _width integer The width the lines have to fit in.
---@return NuiLine[] lines
---@return integer[] line_to_column 1-based column index for each rendered line.
function M.lines(columns, _width)
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

    name_width = math.max(name_width, vim.fn.strdisplaywidth(column.name))
  end
  for _, declared in ipairs(types) do
    type_width = math.max(type_width, vim.fn.strdisplaywidth(declared, name_width + 2))
  end

  local lines = {}
  local line_to_column = {}
  local indent = (' '):rep(name_width + type_width + 4)
  for index, column in ipairs(columns) do
    local line = Line()
    local name_pad = (' '):rep(name_width - vim.fn.strdisplaywidth(column.name) + 2)
    local type_pad = (' '):rep(
      type_width - vim.fn.strdisplaywidth(types[index], name_width + 2) + 2
    )
    line:append(column.name .. name_pad, 'SqmeowDetailName')
    line:append(types[index] .. type_pad, 'SqmeowDetailType')

    if column.is_null then
      line:append(config.ui.result.null_text, 'SqmeowNull')
      table.insert(lines, line)
      table.insert(line_to_column, index)
    else
      -- Nui cannot measure strings containing NUL; show its conventional visible notation.
      local value = tostring(column.value):gsub('\r\n', '\n'):gsub('%z', '^@')
      local val_lines = vim.split(value, '\n', { plain = true })
      line:append(val_lines[1] or '')
      table.insert(lines, line)
      table.insert(line_to_column, index)

      for l = 2, #val_lines do
        local continuation = Line()
        continuation:append(indent)
        continuation:append(val_lines[l])
        table.insert(lines, continuation)
        table.insert(line_to_column, index)
      end
    end
  end

  return lines, line_to_column
end

--- Follow an outgoing (`gd`) or incoming (`gr`) foreign key from the field under the cursor.
---@param direction 'outgoing'|'incoming'
local function follow(direction)
  if not (popup and current_columns and line_columns) then
    return
  end
  local winid = popup.winid and vim.api.nvim_win_is_valid(popup.winid) and popup.winid or 0
  local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
  local col_index = line_columns[cursor_line]
  local col = col_index and current_columns[col_index]
  if not col then
    return
  end

  local raw_row = {}
  for idx, entry in ipairs(current_columns) do
    raw_row[idx] = entry.is_null and vim.NIL or entry.value
  end

  require('sqmeow.ui.result').follow_cell(direction, {
    column = col_index - 1,
    name = col.name,
    value = col.is_null and vim.NIL or col.value,
  }, raw_row)
end

--- Actions bound in the row-details popup.
M.actions = {}

--- Follow an outgoing foreign key (`gd`) from the field under the cursor to its parent row.
function M.actions.goto_definition()
  follow('outgoing')
end

--- Follow incoming foreign keys (`gr`) from the field under the cursor to referencing child rows.
function M.actions.goto_references()
  follow('incoming')
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
  local lines, mapped_columns = M.lines(columns, width)
  local opened, open_err = require('sqmeow.ui.popup').open({
    title = ' Row details ',
    lines = lines,
    width = width,
    height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.8)), 1),
    filetype = 'sqmeow-row',
    wrap = true,
    tabstop = vim.bo.tabstop,
    on_close = M.close,
  })
  if not opened then
    return utils.notify(open_err or 'could not open the popup', vim.log.levels.ERROR)
  end
  popup = opened
  current_columns = columns
  line_columns = mapped_columns
  require('sqmeow.keymap').apply('result', opened.bufnr, M.actions)
end

--- Close the popup.
function M.close()
  -- Clear popup before unmounting: BufLeave can call close() again.
  local closing = popup
  popup = nil
  current_columns = nil
  line_columns = nil
  if closing then
    closing:unmount()
  end
end

return M
