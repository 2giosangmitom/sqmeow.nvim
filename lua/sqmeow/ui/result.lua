--- The result grid.
---
--- Built here rather than in the engine. The engine holds the rows and hands over the slice this
--- window is showing, along with what each column holds and how wide its widest value is; laying
--- that out is this module's work, and `nui.line` and `nui.text` assemble the highlighted lines.
---
--- Laid out here rather than with `nui.table`, which draws every other structured thing in the
--- plugin. A nui table is either boxed in, with a rule after every single row, or borderless with
--- no column separators and no rule at all; the characters cannot separate those cases, because
--- one `hor` slot draws the top rule, the header rule and each row's rule alike, and one `ver`
--- slot is both the column separator and the outer edge. The grid wants a third thing: `" │ "`
--- between columns, one rule under the names, and nothing around the outside.
---
--- Columns are sized from the measurement the engine took over the *whole* result, not from the
--- page on screen. A column sized from one page would change width when the user turned to the
--- next, and the grid would appear to shift under them.

local M = {}

local buf = nil
local win = nil

--- The rows this window is showing, and where they start in the result.
---
--- Held because the grid is drawn from them: paging, resizing and reopening all redraw from what is
--- here rather than asking the engine again for rows it already sent.
local page = { offset = 0, rows = {} }

--- How many lines the grid opens with before the first row: the column names, and the rule.
local HEADER_LINES = 2

--- Where the grid puts its highlights.
---
--- Named rather than anonymous, so a colourscheme, a test or anything else looking for the grid's
--- marks can find them.
local NAMESPACE = vim.api.nvim_create_namespace('sqmeow')

local function valid(handle, check)
  return handle ~= nil and check(handle)
end

local function valid_buf()
  return valid(buf, vim.api.nvim_buf_is_valid)
end

--- Whether the result window is still the result window.
---
--- A valid handle is not enough. Something else can take a window over, which `:bdelete` on the
--- buffer it held, a session restore, and anything else opening a file all do, and the window would
--- then still be valid while showing someone else's buffer. Treating that as closed means the
--- next query opens a window of its own rather than painting into whatever moved in.
local function valid_win()
  return valid(win, vim.api.nvim_win_is_valid)
    and valid_buf()
    and vim.api.nvim_win_get_buf(win) == buf
end

--- How many rows fit in one page.
---@return integer
local function page_size()
  return math.max(require('sqmeow.config').get().ui.result.page_size, 1)
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

--- How many pages a result has, and which one is showing.
---
--- Worked out here rather than sent by the engine: the engine does not know how tall this window
--- is or where the user has scrolled to, and two windows on one result need not agree.
---
---@param summary sqmeow.CallSummary|nil
---@return integer page
---@return integer pages
function M.pages(summary)
  local rows = summary and summary.rows or 0
  local size = page_size()
  local pages = math.max(math.ceil(rows / size), 1)
  return math.min(math.floor(page.offset / size) + 1, pages), pages
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

  local current, total = M.pages(summary)
  if total > 1 then
    table.insert(parts, ('page %d/%d'):format(current, total))
  end
  if summary.elapsed_ms then
    table.insert(parts, M.format_duration(summary.elapsed_ms))
  end
  -- A result from the log is what the query returned then, and the table may say otherwise now.
  if summary.ran_at then
    table.insert(parts, 'ran ' .. require('sqmeow.ui.log').ago(summary.ran_at))
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
  vim.bo[handle].modifiable = false

  return handle
end

--- The buffer the grid is drawn into.
---@return integer
function M.buffer()
  if not valid_buf() then
    buf = scratch('sqmeow://result', 'sqmeow-result')
    require('sqmeow.keymap').apply('result', buf, M.actions)
  end
  return buf
end

-- -- drawing ---------------------------------------------------------------------------------

--- nui's pieces, or nil with a message when it is not installed.
---
--- Loaded through `pcall` rather than required at the top, so a missing nui.nvim is one clear
--- message rather than a stack trace from whichever call happened to run first.
local function nui()
  local parts = {}
  for name, module in pairs({
    Line = 'nui.line',
    Text = 'nui.text',
  }) do
    local ok, loaded = pcall(require, module)
    if not ok then
      return nil, 'sqmeow: the result grid needs nui.nvim (MunifTanjim/nui.nvim)'
    end
    parts[name] = loaded
  end
  return parts
end

--- What a cell reads as in the grid.
---
--- The engine sends values as the types they really are, so `NULL` arrives as `vim.NIL` and a
--- number as a number. Everything is turned into text here, because that is a presentation
--- question: what `NULL` looks like is the user's to set.
---
---@param value any
---@param null_text string
---@return string text
---@return boolean is_null
local function cell_text(value, null_text)
  if value == nil or value == vim.NIL then
    return null_text, true
  end
  if type(value) == 'boolean' then
    return value and 'true' or 'false', false
  end
  return tostring(value), false
end

--- Which result column each display column belongs to.
---
--- Recorded as the grid is built rather than measured afterwards: the layout is decided here, so
--- where each column starts is already known and nothing has to be counted back out of the text.
---
---@type { start: integer, width: integer }[]
local spans = {}

--- The characters the grid is drawn with.
local function glyphs()
  return require('sqmeow.config').get().icons.grid
end

--- Cut text to `limit` display columns, marking it when anything was dropped.
---
--- The marker takes its own room out of the budget, so the result never exceeds the limit. A limit
--- of zero yields nothing rather than a lone marker.
---
---@param text string
---@param limit integer
---@param marker string
---@return string
local function truncate(text, limit, marker)
  if vim.api.nvim_strwidth(text) <= limit then
    return text
  end
  if limit == 0 then
    return ''
  end

  local budget = math.max(limit - vim.api.nvim_strwidth(marker), 0)
  local out, at = {}, 0

  -- One character at a time, because cutting by byte would split a wide one in half.
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local step = vim.api.nvim_strwidth(char)
    if at + step > budget then
      break
    end
    at = at + step
    table.insert(out, char)
  end

  return table.concat(out) .. marker
end

--- What each column of a result is drawn as: how wide, how aligned, and what marks it.
---
---@param columns table[] As the engine described them.
---@return table[]
local function measure(columns)
  local config = require('sqmeow.config').get()
  local icons = require('sqmeow.icons')

  local cap = math.max(config.ui.result.max_column_width, 1)
  local null_text = config.ui.result.null_text

  local measured = {}
  for index, column in ipairs(columns) do
    -- The icon says what the column holds, or which key it is. Its own piece of the header, so a
    -- colourscheme can reach it without touching the name beside it.
    local icon, icon_group
    if config.ui.result.column_icons then
      local glyph, group = icons.get(column.key or column.class or 'unknown')
      if glyph ~= ' ' then
        icon, icon_group = glyph, group
      end
    end

    local name = truncate(column.name, cap, glyphs().ellipsis)
    local header = vim.api.nvim_strwidth(name)
    if icon then
      -- The icon is chrome rather than content, so it is added on top of the cap instead of
      -- competing with the value for it: capping the pair together would narrow the values of
      -- every column to pay for a glyph. A column whose values are already wider pays nothing.
      header = header + vim.api.nvim_strwidth(icon) + 1
    end

    -- Sized from the engine's measurement over every row, so paging does not move the columns.
    local content = column.widest or 0
    if column.nulls then
      content = math.max(content, vim.api.nvim_strwidth(null_text))
    end

    measured[index] = {
      name = name,
      icon = icon,
      icon_group = icon_group,
      numeric = column.numeric == true,
      width = math.max(math.min(content, cap), header),
    }
  end

  return measured
end

--- How wide a cell's pieces are together.
local function segments_width(segments)
  local total = 0
  for _, segment in ipairs(segments) do
    total = total + vim.api.nvim_strwidth(segment[1])
  end
  return total
end

--- Build one line of the grid, and record where each column landed.
---
--- A cell is a list of `{ text, group }` pieces, so the header's glyph can be coloured apart from
--- the name beside it while still being one cell as far as the layout is concerned.
---
---@param cells table[][] One list of pieces per column.
---@param measured table[]
---@param align boolean Whether to right-align the columns that hold numbers.
---@return table line A `NuiLine`.
local function build_row(cells, measured, align)
  local parts = assert(nui())
  local vertical = glyphs().vertical
  local separator_width = vim.api.nvim_strwidth(vertical) + 2

  local line = parts.Line()
  line:append(' ')

  local at = 1
  for index, column in ipairs(measured) do
    if index > 1 then
      -- The same group as the rule under the header: both are the grid's own lines rather than
      -- anything the result said, and one group for the pair is what stops them drifting apart.
      -- The spaces either side stay ungrouped, so a colourscheme that gives the group a background
      -- paints the glyph and not the gap around it.
      line:append(' ')
      line:append(parts.Text(vertical, 'SqmeowRule'))
      line:append(' ')
      at = at + separator_width
    end
    -- Where the column sits, in display columns. Recorded as the line is built, so nothing has to
    -- be measured back out of the text afterwards.
    spans[index] = { start = at, width = column.width }

    local segments = cells[index] or {}
    local room = column.width - segments_width(segments)
    if room < 0 then
      -- Only the last piece can overflow: everything before it was sized to fit.
      local last = segments[#segments]
      if last then
        last[1] = truncate(last[1], vim.api.nvim_strwidth(last[1]) + room, glyphs().ellipsis)
        room = column.width - segments_width(segments)
      end
    end

    local right = align and column.numeric
    -- The padding carries no group, so a highlight only ever covers the value and not the empty
    -- room beside it.
    if right and room > 0 then
      line:append((' '):rep(room))
    end
    for _, segment in ipairs(segments) do
      line:append(segment[2] and parts.Text(segment[1], segment[2]) or parts.Text(segment[1]))
    end
    if not right and room > 0 then
      line:append((' '):rep(room))
    end

    at = at + column.width
  end

  return line
end

--- The rule under the column names.
local function build_rule(measured)
  local parts = assert(nui())
  local marks = glyphs()
  local joint = ('%s%s%s'):format(marks.horizontal, marks.cross, marks.horizontal)

  local text = marks.horizontal
  for index, column in ipairs(measured) do
    if index > 1 then
      text = text .. joint
    end
    text = text .. marks.horizontal:rep(column.width)
  end

  local line = parts.Line()
  line:append(parts.Text(text, 'SqmeowRule'))
  return line
end

--- A line's text with its trailing padding trimmed.
---
--- Nothing needs the room past the last visible character, and a buffer full of lines with
--- invisible trailing spaces is a nuisance to yank from and to diff.
local function trimmed(line)
  return (line:content():gsub('%s+$', ''))
end

--- Draw the rows this window is showing.
local function draw()
  local call = require('sqmeow.state').call
  local handle = M.buffer()

  local parts, err = nui()
  if not parts then
    return vim.notify(err, vim.log.levels.ERROR)
  end

  vim.bo[handle].modifiable = true
  vim.api.nvim_buf_clear_namespace(handle, NAMESPACE, 0, -1)

  if not (call and call.columns and #call.columns > 0) then
    spans = {}
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, {})
    vim.bo[handle].modifiable = false
    return
  end

  spans = {}

  local measured = measure(call.columns)
  local null_text = require('sqmeow.config').get().ui.result.null_text
  local lines = {}

  local names = {}
  for index, column in ipairs(measured) do
    local cell = {}
    if column.icon then
      table.insert(cell, { column.icon, column.icon_group })
      table.insert(cell, { ' ' })
    end
    table.insert(cell, { column.name, 'SqmeowHeader' })
    names[index] = cell
  end

  table.insert(lines, build_row(names, measured, false))
  table.insert(lines, build_rule(measured))

  for _, row in ipairs(page.rows) do
    local cells = {}
    for index, column in ipairs(measured) do
      local text, is_null = cell_text(row[index], null_text)
      local group = 'SqmeowText'
      if is_null then
        group = 'SqmeowNull'
      elseif column.numeric then
        group = 'SqmeowNumber'
      end
      cells[index] = { { text, group } }
    end
    table.insert(lines, build_row(cells, measured, true))
  end

  vim.api.nvim_buf_set_lines(handle, 0, -1, false, vim.tbl_map(trimmed, lines))
  for number, line in ipairs(lines) do
    line:highlight(handle, NAMESPACE, number)
  end

  vim.bo[handle].modifiable = false
end

--- Ask the engine for a slice of the current result and draw it.
---
---@param offset integer Row the page should start at.
---@return boolean drawn
function M.show_page(offset)
  local state = require('sqmeow.state')
  local call = state.call
  if not (call and call.call_id) then
    return false
  end

  local size = page_size()
  local total = call.rows or 0
  -- Past either end settles on the last or first page rather than emptying the view, which is what
  -- `L` at the end of a result should do.
  local last = math.max(math.ceil(total / size) - 1, 0) * size
  offset = math.max(math.min(offset, last), 0)

  local rows, err = require('sqmeow.rpc').request('rows', {
    call_id = call.call_id,
    offset = offset,
    limit = size,
  })
  if err then
    vim.notify('sqmeow: ' .. err, vim.log.levels.WARN)
    return false
  end

  page = { offset = offset, rows = rows or {} }
  draw()
  M.update_winbar(call)
  return true
end

--- Draw a result from its beginning.
---
---@param summary sqmeow.CallSummary|nil
function M.render(summary)
  page = { offset = 0, rows = {} }

  if not (summary and summary.call_id and summary.state == 'done') then
    draw()
    M.update_winbar(summary)
    return
  end

  M.show_page(0)
end

--- The row the page on screen starts at.
---@return integer
function M.offset()
  return page.offset
end

--- How many rows the page on screen holds.
---@return integer
function M.row_count()
  return #page.rows
end

-- -- where the cursor is ---------------------------------------------------------------------

-- One UTF-8 character at a time. The grid is aligned by display width, so a byte offset means
-- nothing on a line holding CJK text or an emoji, and walking characters is the only way to turn
-- one into the other.
local function characters(line)
  return line:gmatch('[%z\1-\127\194-\244][\128-\191]*')
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

--- Where the cursor is in the result, as a row and a column of the data.
---
--- The row is the cursor line, less the two the grid opens with, plus the page's offset. The
--- column comes from where each one was put when the grid was built: a cursor's byte position
--- means nothing on a line of CJK text, but its display width does.
---
---@return { row: integer, column: integer, name: string }|nil # Nil when the cursor is on the
--- header rather than on a row.
function M.current_cell()
  local call = require('sqmeow.state').call
  if not (valid_win() and call and call.columns and #spans > 0) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1 - HEADER_LINES
  if row < 0 then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(M.buffer(), cursor[1] - 1, cursor[1], false)[1]
  if not line then
    return nil
  end

  local display = vim.fn.strdisplaywidth(line:sub(1, cursor[2]))
  local found = 1
  for index, span in ipairs(spans) do
    if display >= span.start then
      found = index
    end
  end

  return {
    row = page.offset + row,
    column = found - 1,
    name = call.columns[found] and call.columns[found].name or '',
  }
end

--- The values of one column, as the page on screen holds them.
---
--- Read out of what was fetched rather than asked of the engine. These are for a preview beside a
--- list, so what the user is already looking at is the right answer and it costs no round trip.
---
---@param index integer One-based column.
---@param limit integer How many rows at most.
---@return string[]
function M.column_values(index, limit)
  local null_text = require('sqmeow.config').get().ui.result.null_text
  local values = {}

  for at = 1, math.min(limit, #page.rows) do
    values[at] = (cell_text(page.rows[at][index], null_text))
  end
  return values
end

--- Put the cursor on a column, keeping the row it is already on.
---
---@param index integer One-based column.
---@return boolean moved
function M.goto_column(index)
  local span = spans[index]
  if not (span and valid_win()) then
    return false
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(M.buffer(), row - 1, row, false)[1] or ''

  vim.api.nvim_win_set_cursor(win, { row, M.byte_at(line, span.start) })
  vim.api.nvim_set_current_win(win)
  return true
end

-- -- actions --------------------------------------------------------------------------------

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
---
--- The range travels with the request now: only this side knows how many rows a page holds and
--- which one is on screen.
function M.actions.yank_page()
  engine_export({
    scope = 'range',
    format = 'csv',
    row = page.offset,
    limit = #page.rows,
    register = vim.v.register,
  })
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

function M.actions.help()
  require('sqmeow.ui.help').open('result')
end

function M.actions.close()
  M.close()
end

-- -- the window -----------------------------------------------------------------------------

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
    require('sqmeow.ui.layout').close_window(win)
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

  -- The connection the result came from, not the active one. They differ the moment someone
  -- switches, and relabelling an old grid with a database it never touched is a lie.
  local state = require('sqmeow.state')
  local connection = summary and summary.conn_id and state.connections[summary.conn_id]
  if not connection and summary and summary.connection then
    -- A result shown from the log names the database it came from, whether or not that is open.
    connection = { name = summary.connection, dialect = summary.dialect }
  end
  connection = connection or state.current_connection()
  local label = connection and ('%s (%s)'):format(connection.name, connection.dialect or '?')
    or 'not connected'

  vim.wo[win].winbar = ('%%#SqmeowWinbar# %s  %%*%s'):format(label, M.describe(summary))
end

return M
