--- The result grid.
---
--- The lines are written by the engine, not from here. This module decides that the window
--- exists, where it is, and what the winbar says.
---
--- One window and one buffer hold the whole grid: the column names, the rule under them, and the
--- rows. The engine reports how many lines come before the first row, so a cursor position still
--- maps to a cell without the plugin knowing how the grid was laid out.

local M = {}

local buf = nil
local win = nil

local function valid(handle, check)
  return handle ~= nil and check(handle)
end

local function valid_buf()
  return valid(buf, vim.api.nvim_buf_is_valid)
end

local function valid_win()
  return valid(win, vim.api.nvim_win_is_valid)
end

--- How many lines of the buffer are header rather than data.
---
--- Taken from the page the engine painted rather than assumed, so a change to what a header is
--- does not need a matching change here.
---@return integer
local function header_lines()
  local call = require('sqmeow.state').call
  return call and call.header_lines or 0
end

--- Round a duration for display, keeping it short without lying about the magnitude.
---@param ms integer
---@return string
function M.format_duration(ms)
  if ms < 1000 then
    return ('%dms'):format(ms)
  end
  return ('%.2fs'):format(ms / 1000)
end

--- Describe a result for the winbar.
---
---@param summary sqmeow.CallSummary|nil
---@return string
function M.describe(summary)
  if not summary then
    return 'sqmeow'
  end

  if summary.state == 'executing' then
    return 'running…'
  end
  if summary.state == 'error' then
    return 'error: ' .. (summary.error or 'unknown')
  end
  if summary.state == 'cancelled' then
    return 'cancelled'
  end

  local parts = {}

  if summary.rows and summary.rows > 0 then
    table.insert(parts, ('%d row%s'):format(summary.rows, summary.rows == 1 and '' or 's'))
  elseif summary.affected then
    table.insert(
      parts,
      ('%d row%s affected'):format(summary.affected, summary.affected == 1 and '' or 's')
    )
  else
    table.insert(parts, 'no rows')
  end

  if summary.truncated then
    table.insert(parts, 'truncated')
  end
  if summary.pages and summary.pages > 1 then
    table.insert(parts, ('page %d/%d'):format(summary.page, summary.pages))
  end
  if summary.elapsed_ms then
    table.insert(parts, M.format_duration(summary.elapsed_ms))
  end

  return table.concat(parts, '  ')
end

local function scratch(name, filetype)
  local handle = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(handle, name)

  vim.bo[handle].buftype = 'nofile'
  vim.bo[handle].bufhidden = 'hide'
  vim.bo[handle].swapfile = false
  vim.bo[handle].filetype = filetype
  -- The engine lifts this around each paint. Between paints the grid is not something to type in.
  vim.bo[handle].modifiable = false

  return handle
end

--- The buffer the grid is written into.
---@return integer
function M.buffer()
  if not valid_buf() then
    buf = scratch('sqmeow://result', 'sqmeow-result')
    require('sqmeow.keymap').apply('result', buf, M.actions)
  end
  return buf
end

--- Where the cursor is in the result, as a row and a column of the data.
---
--- The row is the cursor line, less the header the grid begins with, plus the page's offset. The
--- column comes from the display spans the engine sent with the page: a cursor byte position
--- means nothing on a line of CJK text, but its display width does.
---
---@return { row: integer, column: integer, name: string }|nil # Nil when the cursor is on the
--- header rather than on a row.
function M.current_cell()
  local call = require('sqmeow.state').call
  if not (valid_win() and call and call.column_spans) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1 - header_lines()
  if row < 0 then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(M.buffer(), cursor[1] - 1, cursor[1], false)[1]
  if not line then
    return nil
  end

  local display = vim.fn.strdisplaywidth(line:sub(1, cursor[2]))
  local found = 1

  for index, span in ipairs(call.column_spans) do
    if display >= span.start then
      found = index
    end
  end

  return {
    row = (call.offset or 0) + row,
    column = found - 1,
    name = call.column_spans[found] and call.column_spans[found].name or '',
  }
end

-- One UTF-8 character at a time. The grid is aligned by display width, so a byte offset means
-- nothing on a line holding CJK text or an emoji, and walking characters is the only way to turn
-- one into the other.
local function characters(line)
  return line:gmatch('[%z\1-\127\194-\244][\128-\191]*')
end

--- The part of a line that lies inside a display-column span.
---
---@param line string
---@param from integer Display column the span starts at.
---@param width integer How many display columns it covers.
---@return string # Trimmed, since a grid cell is padded to its column's width.
function M.display_slice(line, from, width)
  local at = 0
  local parts = {}

  for char in characters(line) do
    if at >= from + width then
      break
    end
    if at >= from then
      table.insert(parts, char)
    end
    at = at + vim.api.nvim_strwidth(char)
  end

  return vim.trim(table.concat(parts))
end

--- The byte offset of a display column on a line.
---
---@param line string
---@param display integer
---@return integer
function M.byte_at(line, display)
  local at, bytes = 0, 0

  for char in characters(line) do
    if at >= display then
      break
    end
    at = at + vim.api.nvim_strwidth(char)
    bytes = bytes + #char
  end

  return bytes
end

--- The values of one column, as the painted page shows them.
---
--- Read back out of the grid rather than asked of the engine. These are for a preview beside a
--- picker, so what the user is already looking at is exactly the right answer, and it costs no
--- round trip.
---
---@param index integer One-based column.
---@param limit integer How many rows at most.
---@return string[]
function M.column_values(index, limit)
  local call = require('sqmeow.state').call
  local span = call and call.column_spans and call.column_spans[index]
  if not (span and valid_buf()) then
    return {}
  end

  -- Skipped, because a preview of a column's values should not open with the column's own name
  -- and the rule under it.
  local first = header_lines()

  return vim.tbl_map(function(line)
    return M.display_slice(line, span.start, span.width)
  end, vim.api.nvim_buf_get_lines(buf, first, first + limit, false))
end

--- Put the cursor on a column, keeping the row it is already on.
---
---@param index integer One-based column.
---@return boolean moved
function M.goto_column(index)
  local call = require('sqmeow.state').call
  local span = call and call.column_spans and call.column_spans[index]
  if not (span and valid_win()) then
    return false
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''

  vim.api.nvim_win_set_cursor(win, { row, M.byte_at(line, span.start) })
  vim.api.nvim_set_current_win(win)
  return true
end

local function engine_export(request)
  local call = require('sqmeow.state').call
  if not (call and call.call_id) then
    vim.notify('sqmeow: there is no result to export', vim.log.levels.WARN)
    return
  end

  request.call_id = call.call_id
  local _, err = require('sqmeow.rpc').request('export', request)
  if err then
    vim.notify('sqmeow: ' .. err, vim.log.levels.ERROR)
  end
end

--- Actions the result window's keys are bound to.
M.actions = {}

function M.actions.next_page()
  require('sqmeow.api').next_page()
end

function M.actions.prev_page()
  require('sqmeow.api').prev_page()
end

function M.actions.first_page()
  require('sqmeow.api').first_page()
end

function M.actions.last_page()
  require('sqmeow.api').last_page()
end

--- Copy the value under the cursor, exactly as it is rather than as the grid shows it.
function M.actions.yank_cell()
  local cell = M.current_cell()
  if not cell then
    return
  end
  engine_export({ scope = 'cell', row = cell.row, column = cell.column, register = vim.v.register })
end

--- Copy the row under the cursor as CSV.
function M.actions.yank_row()
  local cell = M.current_cell()
  if not cell then
    return
  end
  engine_export({ scope = 'row', format = 'csv', row = cell.row, register = vim.v.register })
end

--- Copy the visible page as CSV.
function M.actions.yank_page()
  engine_export({ scope = 'page', format = 'csv', register = vim.v.register })
end

--- Write the whole result to a file.
function M.actions.export()
  require('sqmeow.api').export()
end

--- Show the row under the cursor as a list of columns and values.
function M.actions.detail()
  local cell = M.current_cell()
  if not cell then
    return
  end
  require('sqmeow.ui.detail').open(cell.row)
end

--- Jump to a column, chosen from a list rather than scrolled to.
function M.actions.find()
  require('sqmeow.pickers').columns()
end

function M.actions.help()
  require('sqmeow.ui.help').open('result')
end

function M.actions.close()
  M.close()
end

--- Show the result window, creating it if needed.
---@return integer win
function M.open()
  if valid_win() then
    return win
  end

  local config = require('sqmeow.config').get()
  require('sqmeow.ui.layout').remember()
  local previous = vim.api.nvim_get_current_win()

  vim.cmd(('botright %dsplit'):format(config.ui.result.height))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M.buffer())

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  -- Other splits must not squash the grid, which would silently hide columns.
  vim.wo[win].winfixheight = true

  -- Opening a result should not steal the cursor from the query being written.
  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return win
end

--- Hide the result window, keeping what it holds.
function M.close()
  if valid_win() then
    vim.api.nvim_win_close(win, true)
  end
  win = nil

  require('sqmeow.ui.detail').close()
  require('sqmeow.ui.layout').restore()
end

--- Whether the result window is showing.
---@return boolean
function M.is_open()
  return valid_win()
end

--- Update the line above the grid.
---
---@param summary sqmeow.CallSummary|nil
function M.update_winbar(summary)
  if not valid_win() or not require('sqmeow.config').get().ui.winbar then
    return
  end

  local connection = require('sqmeow.state').current_connection()
  local label = connection and ('%s (%s)'):format(connection.name, connection.dialect or '?')
    or 'not connected'

  vim.wo[win].winbar = ('%%#SqmeowWinbar# %s  %%*%s'):format(label, M.describe(summary))
end

return M
