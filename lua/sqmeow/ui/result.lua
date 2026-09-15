--- The result grid.

local M = {}

local utils = require('sqmeow.utils')

local buf = nil
local win = nil
--- The float the grid is in, when it is not in its split.
local popup = nil

--- The rows on screen, their offset in the view, and their result indices.
local page = { offset = 0, rows = {}, indices = {} }

--- How each result is shown, by call id.
local specs = {}

--- The call the grid was last drawn for, which tells a new result from the same one redrawn.
local drawn = nil
--- A view to put on the next result, and the call it is waiting for.
local carried, pending = nil, nil
--- Where the page and cursor were, for the next result to open at.
local resume = nil

--- How many lines the grid opens with before the first row: the column names, and the rule.
local HEADER_LINES = 2

--- Where the grid puts its highlights.
local NAMESPACE = vim.api.nvim_create_namespace('sqmeow')

--- How many rows fit in one page.
---@return integer
local function page_size()
  return math.max(require('sqmeow.config').get().ui.result.page_size, 1)
end

--- A view that shows everything as the query returned it.
local function fresh()
  return { filters = {}, sort = {}, hidden = {}, where = '', order_by = '' }
end

--- How the current result is shown. `where` and `order_by` are run in its query, which `base`
--- holds as written once it has been filtered.
---@return { filters: table[], sort: table[], hidden: table<integer, boolean>, where: string, order_by: string, base: string|nil }
function M.spec()
  local call = require('sqmeow.state').call
  local id = call and call.call_id
  if not id then
    return fresh()
  end
  specs[id] = specs[id] or fresh()
  return specs[id]
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
---@param summary sqmeow.CallSummary|nil
---@return integer page
---@return integer pages
function M.pages(summary)
  local rows = summary and (summary.view_rows or summary.rows) or 0
  local size = page_size()
  local pages = math.max(math.ceil(rows / size), 1)
  return math.min(math.floor(page.offset / size) + 1, pages), pages
end

--- Describe a result for the winbar.
---@param summary sqmeow.CallSummary|nil
---@return string
---@param highlight boolean|nil Colour the icons with winbar markup, for drawing in a winbar.
function M.describe(summary, highlight)
  if not summary then
    return 'sqmeow'
  end

  if summary.state == 'executing' then
    return 'running…'
  end

  -- Which statement's result this is, when several returned rows.
  local position
  for index, entry in ipairs(summary.results or {}) do
    if entry.call_id == summary.call_id then
      position = ('result %d/%d'):format(index, #summary.results)
    end
  end
  if summary.state == 'error' then
    return (position and position .. '  ' or '') .. 'error: ' .. (summary.error or 'unknown')
  end
  if summary.state == 'cancelled' then
    return 'cancelled'
  end

  local parts = { position }

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
  if summary.view_rows then
    table.insert(parts, ('%d shown'):format(summary.view_rows))
  end

  local spec = summary.call_id and specs[summary.call_id]
  if spec then
    local function clause(label, text)
      if vim.fn.strchars(text) > 40 then
        text = vim.fn.strcharpart(text, 0, 39) .. '…'
      end
      -- A winbar reads `%` as the start of an item.
      table.insert(parts, label .. (highlight and text:gsub('%%', '%%%%') or text))
    end
    if (spec.where or '') ~= '' then
      clause('where ', spec.where)
    end

    local keys = {}
    for _, key in ipairs(spec.sort) do
      local column = summary.columns and summary.columns[key.column + 1]
      table.insert(keys, (column and column.name or '?') .. (key.descending and '↓' or '↑'))
    end
    if (spec.order_by or '') ~= '' then
      clause('order by ', spec.order_by)
    elseif #keys > 0 then
      table.insert(parts, 'sorted by ' .. table.concat(keys, ', '))
    end
    local hidden = vim.tbl_count(spec.hidden)
    if hidden > 0 then
      table.insert(parts, ('%d hidden'):format(hidden))
    end
  end

  local changes = require('sqmeow.ui.edit').count()
  if changes > 0 and summary.call_id == drawn then
    table.insert(parts, ('%d change%s'):format(changes, changes == 1 and '' or 's'))
  end

  local current, total = M.pages(summary)
  if total > 1 then
    table.insert(parts, ('page %d/%d'):format(current, total))
  end
  if summary.elapsed_ms then
    local elapsed = M.format_duration(summary.elapsed_ms)
    local icon, group = require('sqmeow.icons').get('elapsed')
    if icon ~= '' then
      icon = highlight and ('%%#%s#%s%%*'):format(group, icon) or icon
      elapsed = icon .. ' ' .. elapsed
    end
    table.insert(parts, elapsed)
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
  if buf and utils.buf_valid(buf) then
    return buf
  end
  buf = scratch('sqmeow://result', 'sqmeow-result')
  require('sqmeow.keymap').apply('result', buf, M.actions)
  return buf
end

-- -- drawing ---------------------------------------------------------------------------------

--- The nui.nvim components the result grid is built from.
local function nui()
  return utils.nui({ 'line', 'text' }, 'the result grid')
end

--- What a cell reads as in the grid.
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
  local text = tostring(value):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return text, false
end

--- Where each display column starts, how wide it is, and which result column it shows.
---@type { start: integer, width: integer, column: integer }[]
local spans = {}

--- The characters the grid is drawn with.
local function glyphs()
  return require('sqmeow.config').get().icons.grid
end

--- Cut text to `limit` display columns, marking it when anything was dropped.
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

--- What each shown column of a result is drawn as.
---@param columns table[] As the engine described them.
---@param hidden table<integer, boolean> Zero-based columns left out.
---@return table[]
local function measure(columns, hidden)
  local config = require('sqmeow.config').get()
  local icons = require('sqmeow.icons')

  local cap = math.max(config.ui.result.max_column_width, 1)
  local null_text = config.ui.result.null_text

  local measured = {}
  for index, column in ipairs(columns) do
    if not hidden[index - 1] then
      -- The icon says what the column holds, or which key it is.
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
        -- The icon is chrome rather than content.
        header = header + vim.api.nvim_strwidth(icon) + 1
      end

      -- Sized from the engine's measurement over every row, so paging does not move the columns.
      local content = column.widest or 0
      if column.nulls then
        content = math.max(content, vim.api.nvim_strwidth(null_text))
      end

      table.insert(measured, {
        index = index,
        name = name,
        icon = icon,
        icon_group = icon_group,
        numeric = column.numeric == true,
        width = math.max(math.min(content, cap), header),
      })
    end
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
---@param cells table[][] One list of pieces per column.
---@param measured table[]
---@param align boolean Whether to right-align the columns that hold numbers.
---@return table line A `NuiLine`.
local function build_row(grid, cells, measured, align)
  local parts, vertical = grid.parts, grid.marks.vertical
  local separator_width = grid.separator_width

  local line = parts.Line()
  line:append(' ')

  local at = 1
  for index, column in ipairs(measured) do
    local segments = cells[index] or {}
    if index > 1 then
      -- The same group as the rule under the header.
      line:append(' ')
      line:append(parts.Text(vertical, 'SqmeowRule'))
      -- The space after the glyph is room before a value.
      if not (index == #measured and segments_width(segments) == 0) then
        line:append(' ')
      end
      at = at + separator_width
    end
    -- Where the column sits, in display columns.
    spans[index] = { start = at, width = column.width, column = column.index }

    local room = column.width - segments_width(segments)
    if room < 0 then
      -- Only the last piece can overflow: everything before it was sized to fit.
      local last = segments[#segments]
      if last then
        last[1] = truncate(last[1], vim.api.nvim_strwidth(last[1]) + room, grid.marks.ellipsis)
        room = column.width - segments_width(segments)
      end
    end

    local right = align and column.numeric
    -- The padding carries no group.
    if right and room > 0 then
      line:append((' '):rep(room))
    end
    for _, segment in ipairs(segments) do
      line:append(segment[2] and parts.Text(segment[1], segment[2]) or parts.Text(segment[1]))
    end
    -- Nothing pads the last column.
    if not right and room > 0 and index < #measured then
      line:append((' '):rep(room))
    end

    at = at + column.width
  end

  return line
end

--- The rule under the column names.
local function build_rule(grid, measured)
  local parts, marks = grid.parts, grid.marks
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

--- How a result that is a query plan reads as lines, or nil for any other result.
---@param call table
---@return string[]|nil
local function plan_lines(call)
  if not (call.sql and call.sql:match('^%s*[Ee][Xx][Pp][Ll][Aa][Ii][Nn]%s')) then
    return nil
  end
  local names = table.concat(
    vim.tbl_map(function(column)
      return column.name
    end, call.columns),
    ','
  )

  local lines = {}
  if names == 'id,parent,notused,detail' then
    local depth = {}
    for _, row in ipairs(page.rows) do
      depth[row[1]] = (depth[row[2]] or -1) + 1
      table.insert(lines, ('  '):rep(depth[row[1]]) .. tostring(row[4]))
    end
    return lines
  end
  if #call.columns ~= 1 then
    return nil
  end

  -- A plan in one value, such as MySQL's `FORMAT=TREE`, spans lines the grid's rows flatten.
  if call.rows == 1 then
    local row = require('sqmeow.rpc').request('row', { call_id = call.call_id, row = 0 })
    if row and row[1] and not row[1].is_null then
      return vim.split(row[1].value, '\n', { plain = true })
    end
  end
  for _, row in ipairs(page.rows) do
    table.insert(lines, row[1] == vim.NIL and '' or tostring(row[1]))
  end
  return lines
end

--- Draw the rows this window is showing, with the changes staged against them.
local function draw()
  local call = require('sqmeow.state').call
  local edit = require('sqmeow.ui.edit')
  local handle = M.buffer()

  local parts, err = nui()
  if not parts then
    return utils.notify(err, vim.log.levels.ERROR)
  end

  -- Read once per draw rather than once per row.
  local grid = { parts = parts, marks = glyphs() }
  grid.separator_width = vim.api.nvim_strwidth(grid.marks.vertical) + 2

  vim.bo[handle].modifiable = true
  vim.api.nvim_buf_clear_namespace(handle, NAMESPACE, 0, -1)

  -- A failed query's error is shown here, where its rows would have been, and nowhere else.
  if call and call.state == 'error' then
    spans = {}
    local lines = vim.split(call.error or 'the query failed', '\n')
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, lines)
    for row, text in ipairs(lines) do
      vim.api.nvim_buf_set_extmark(handle, NAMESPACE, row - 1, 0, {
        end_col = #text,
        hl_group = 'SqmeowError',
      })
    end
    vim.bo[handle].modifiable = false
    return
  end

  if not (call and call.columns and #call.columns > 0) then
    spans = {}
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, {})
    vim.bo[handle].modifiable = false
    return
  end

  spans = {}

  local plan = plan_lines(call)
  if plan then
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, plan)
    vim.bo[handle].modifiable = false
    return
  end

  local measured = measure(call.columns, M.spec().hidden)
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

  table.insert(lines, build_row(grid, names, measured, false))
  table.insert(lines, build_rule(grid, measured))

  for position, row in ipairs(page.rows) do
    local absolute = page.indices[position]
    local deleted = absolute ~= nil and edit.deleted(absolute)
    local cells = {}
    for index, column in ipairs(measured) do
      local value, staged = row[column.index], false
      if absolute then
        local changed, has = edit.staged(absolute, column.index - 1)
        if has then
          value, staged = changed, true
        end
      end

      local text, is_null = cell_text(value, null_text)
      local group = 'SqmeowText'
      if deleted then
        group = 'SqmeowDeleted'
      elseif staged then
        group = 'SqmeowChanged'
      elseif is_null then
        group = 'SqmeowNull'
      elseif column.numeric then
        group = 'SqmeowNumber'
      end
      cells[index] = { { text, group } }
    end
    table.insert(lines, build_row(grid, cells, measured, true))
  end

  -- New rows go under whatever page is showing, so they are in sight wherever the user added them.
  for _, values in ipairs(edit.inserts()) do
    local cells = {}
    for index, column in ipairs(measured) do
      local value = values[column.index - 1]
      cells[index] = { { value == nil and '' or cell_text(value, null_text), 'SqmeowInserted' } }
    end
    table.insert(lines, build_row(grid, cells, measured, true))
  end

  vim.api.nvim_buf_set_lines(
    handle,
    0,
    -1,
    false,
    vim.tbl_map(function(line)
      return line:content()
    end, lines)
  )
  for number, line in ipairs(lines) do
    line:highlight(handle, NAMESPACE, number)
  end

  vim.bo[handle].modifiable = false
end

--- Draw the page on screen again, after something about how it is shown changed.
function M.redraw()
  draw()
  M.update_winbar(require('sqmeow.state').call)
end

--- Ask the engine for a slice of the current result and draw it.
---@param offset integer Where in the view the page should start.
---@return boolean drawn
function M.show_page(offset)
  local state = require('sqmeow.state')
  local call = state.call
  if not (call and call.call_id) then
    return false
  end

  local size = page_size()
  local total = call.view_rows or call.rows or 0
  -- Past either end settles on the last or first page rather than emptying the view.
  local last = math.max(math.ceil(total / size) - 1, 0) * size
  offset = math.max(math.min(offset, last), 0)

  local reply, err = require('sqmeow.rpc').request('rows', {
    call_id = call.call_id,
    offset = offset,
    limit = size,
  })
  if err or type(reply) ~= 'table' then
    utils.notify(err or 'the engine sent no rows', vim.log.levels.WARN)
    return false
  end

  -- How many rows the view holds is the engine's to say, and a count equal to the result's is no
  -- view worth mentioning.
  call.view_rows = reply.total ~= call.rows and reply.total or nil
  page = { offset = offset, rows = reply.rows or {}, indices = reply.indices or {} }
  draw()
  M.update_winbar(call)
  return true
end

--- Ask the engine to filter and sort the current result as its view says.
---@return boolean sent
function M.send_view()
  local call = require('sqmeow.state').call
  if not (call and call.call_id) then
    return false
  end

  local spec = M.spec()
  local _, err = require('sqmeow.rpc').request('view', {
    call_id = call.call_id,
    filters = spec.filters,
    sort = spec.sort,
  })
  if err then
    utils.notify(err, vim.log.levels.WARN)
    return false
  end
  return true
end

--- The engine finished building a view.
---@param payload { call_id: integer, rows: integer|nil, error: string|nil }
function M.on_view(payload)
  if payload.error then
    return utils.notify(payload.error, vim.log.levels.WARN)
  end
  local call = require('sqmeow.state').call
  if call and call.call_id == payload.call_id then
    M.show_page(0)
  end
end

--- Whether a result is filtered and ordered by running its query again, which needs an open SQL
--- connection, rather than in the engine's memory.
---@param call sqmeow.CallSummary|nil
---@return boolean
function M.queried(call)
  local connection = call and call.conn_id and require('sqmeow.state').connections[call.conn_id]
  return connection ~= nil
    and connection.dialect ~= nil
    and not vim.tbl_contains({ 'redis', 'mongodb', 'scylla' }, connection.dialect)
end

--- An identifier quoted for the current result's database.
---@param name string
---@return string
function M.quote(name)
  local state = require('sqmeow.state')
  local connection = state.call and state.call.conn_id and state.connections[state.call.conn_id]
  if connection and connection.dialect == 'mysql' then
    return '`' .. (name:gsub('`', '``')) .. '`'
  end
  return '"' .. (name:gsub('"', '""')) .. '"'
end

--- Whether staged changes keep the result from being replaced, saying so when they do.
---@return boolean
local function blocked()
  local staged = require('sqmeow.ui.edit').count()
  if staged == 0 then
    return false
  end
  utils.notify(
    ('apply or discard the %d staged change%s first'):format(staged, staged == 1 and '' or 's'),
    vim.log.levels.WARN
  )
  return true
end

--- Run the current result's query again, changing the parts of its view `view` names.
---@param view table|nil Fields of the view to replace, such as `where` and `order_by`.
---@param keep boolean|nil Open the new result at the same page and cursor, with the rows inserts returned.
---@return boolean started
function M.rerun(view, keep)
  local call = require('sqmeow.state').call
  if not (call and call.call_id and call.conn_id) then
    return false
  end
  -- A new result would drop them.
  if blocked() then
    return false
  end

  local spec = vim.tbl_extend('force', vim.deepcopy(M.spec()), view or {})
  -- A filtered result's own SQL is the wrapper, not the query as written.
  spec.base = spec.base or call.sql
  if not spec.base then
    return false
  end

  carried = spec
  resume = keep
      and {
        offset = page.offset,
        cursor = M.window() and vim.api.nvim_win_get_cursor(win),
      }
    or nil
  local started = require('sqmeow.api').execute(spec.base, {
    conn_id = call.conn_id,
    history = false,
    where = spec.where,
    order_by = spec.order_by,
    inserted = keep,
  })
  if not started then
    carried = nil
  end
  return started ~= nil
end

--- Filter and order the current result by running its query again.
---@param where string A WHERE condition, or empty for none.
---@param order_by string An ORDER BY list, or empty for none.
---@return boolean started
function M.filter(where, order_by)
  if not M.queried(require('sqmeow.state').call) then
    utils.notify(
      'filtering with WHERE and ORDER BY needs an open SQL connection',
      vim.log.levels.WARN
    )
    return false
  end
  return M.rerun({ where = where, order_by = order_by, sort = {} })
end

--- Draw a result from its beginning.
---@param summary sqmeow.CallSummary|nil
function M.render(summary)
  page = { offset = 0, rows = {}, indices = {} }

  local id = summary and summary.call_id
  if id ~= drawn then
    drawn = id
    -- Staged changes name rows of the result they were made on, which is no longer on screen.
    local dropped = require('sqmeow.ui.edit').reset()
    if dropped > 0 then
      utils.notify(
        ('%d unapplied change%s dropped: another result replaced the one they were made on'):format(
          dropped,
          dropped == 1 and ' was' or 's were'
        ),
        vim.log.levels.WARN
      )
    end
    if carried and id then
      specs[id], pending = carried, id
    end
    carried = nil
  end

  if not (summary and summary.call_id and summary.state == 'done') then
    draw()
    M.update_winbar(summary)
    return
  end

  local at
  if pending == id then
    pending, at, resume = nil, resume, nil
    local spec = M.spec()
    -- A result filtered by its query arrives already narrowed.
    if not M.queried(summary) and (#spec.filters > 0 or #spec.sort > 0) and M.send_view() then
      return
    end
  end
  M.show_page(at and at.offset or 0)
  if at and at.cursor and M.window() then
    pcall(vim.api.nvim_win_set_cursor, win, at.cursor)
  end
end

--- The row the page on screen starts at, counted in the view.
---@return integer
function M.offset()
  return page.offset
end

--- The columns the grid shows, zero-based and in order, or nil when none is hidden.
---@return integer[]|nil
function M.visible_columns()
  local call = require('sqmeow.state').call
  local spec = M.spec()
  if not (call and call.columns) or vim.tbl_isempty(spec.hidden) then
    return nil
  end

  local shown = {}
  for index = 0, #call.columns - 1 do
    if not spec.hidden[index] then
      table.insert(shown, index)
    end
  end
  return shown
end

-- -- where the cursor is ---------------------------------------------------------------------

-- One UTF-8 character at a time.
local function characters(line)
  return line:gmatch('[%z\1-\127\194-\244][\128-\191]*')
end

--- The byte offset of a display column on a line.
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

--- Which result column the cursor is in, wherever it is in the grid, header included.
---@return { column: integer, name: string, line: integer }|nil # `column` zero-based.
local function cursor_column()
  local call = require('sqmeow.state').call
  if not (win and utils.shows(win, buf) and call and call.columns and #spans > 0) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(M.buffer(), cursor[1] - 1, cursor[1], false)[1]
  if not line then
    return nil
  end

  local display = vim.fn.strdisplaywidth(line:sub(1, cursor[2]))
  local found = spans[1]
  for _, span in ipairs(spans) do
    if display >= span.start then
      found = span
    end
  end

  return {
    column = found.column - 1,
    name = call.columns[found.column] and call.columns[found.column].name or '',
    line = cursor[1],
  }
end

--- Where the cursor is in the result, as a row and a column of the data.
---@return { row: integer|nil, insert: integer|nil, column: integer, name: string, value: any }|nil # Nil when the cursor is on the header rather than on a row.
function M.current_cell()
  local found = cursor_column()
  if not found then
    return nil
  end

  local position = found.line - HEADER_LINES
  if position < 1 then
    return nil
  end
  if position <= #page.rows then
    return {
      row = page.indices[position] or (page.offset + position - 1),
      column = found.column,
      name = found.name,
      value = page.rows[position][found.column + 1],
    }
  end

  local insert = position - #page.rows
  if require('sqmeow.ui.edit').inserts()[insert] then
    return { insert = insert, column = found.column, name = found.name }
  end
  return nil
end

--- Put the cursor on a column, keeping the row it is already on.
---@param index integer One-based column.
---@return boolean moved
function M.goto_column(index)
  local span
  for _, candidate in ipairs(spans) do
    if candidate.column == index then
      span = candidate
    end
  end
  if not (span and win and utils.shows(win, buf)) then
    return false
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(M.buffer(), row - 1, row, false)[1] or ''

  vim.api.nvim_win_set_cursor(win, { row, M.byte_at(line, span.start) })
  vim.api.nvim_set_current_win(win)
  return true
end

--- The rows a visual selection covers, leaving visual mode.
---@return { row: integer|nil, insert: integer|nil }[]
local function selected()
  local first, last = vim.fn.line('v'), vim.fn.line('.')
  if first > last then
    first, last = last, first
  end
  vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })

  local inserts = require('sqmeow.ui.edit').inserts()
  local targets = {}
  for position = math.max(first - HEADER_LINES, 1), last - HEADER_LINES do
    if position <= #page.rows then
      table.insert(targets, { row = page.indices[position] or (page.offset + position - 1) })
    elseif inserts[position - #page.rows] then
      table.insert(targets, { insert = position - #page.rows })
    end
  end
  return targets
end

-- -- the float --------------------------------------------------------------------------------

--- Whether the grid is showing in its float.
---@return boolean
function M.is_float()
  return popup ~= nil and utils.shows(win, buf)
end

--- Show the grid in a float, moving it out of its split.
---@return integer|nil win
function M.open_float()
  if win and M.is_float() then
    vim.api.nvim_set_current_win(win)
    return win
  end

  local parts, err = utils.nui({ 'popup' }, 'the result float')
  if not parts then
    utils.notify(err, vim.log.levels.ERROR)
    return nil
  end

  local layout = require('sqmeow.ui.layout')
  layout.remember()
  local cursor
  if win and utils.shows(win, buf) then
    cursor = vim.api.nvim_win_get_cursor(win)
    layout.close_window(win)
  end
  if popup then
    popup:unmount()
  end

  popup = parts.Popup({
    enter = true,
    focusable = true,
    relative = 'editor',
    position = '50%',
    size = { width = '90%', height = '80%' },
    zindex = 40,
    bufnr = M.buffer(),
    border = {
      style = require('sqmeow.config').border(),
      -- A title, as every dialog has.
      text = { top = ' Result ', top_align = 'center' },
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = 'no',
      wrap = false,
      cursorline = true,
    },
  })
  popup:mount()
  win = popup.winid
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  M.update_winbar(require('sqmeow.state').call)
  return win
end

--- Move the grid between its split and its float.
function M.toggle_float()
  -- The bar is docked to the window the grid is leaving.
  require('sqmeow.ui.filter').close()
  if not M.is_float() then
    return M.open_float()
  end
  assert(popup and win, 'a float is open, so it has a popup and a window')

  local cursor = vim.api.nvim_win_get_cursor(win)
  local closing = popup
  popup, win = nil, nil
  closing:unmount()

  win = M.open()
  vim.api.nvim_set_current_win(win)
  pcall(vim.api.nvim_win_set_cursor, win, cursor)
end

--- Whether the keys that change rows may do so on this result, saying why not when they may not.
---@return boolean
local function editing()
  local state = require('sqmeow.state')
  local call = state.call
  local connection = call and call.conn_id and state.connections[call.conn_id]
  if connection and connection.read_only then
    utils.notify(
      ('`%s` is read-only, so its results cannot be edited'):format(connection.name),
      vim.log.levels.WARN
    )
    return false
  end
  if not (call and call.source) then
    utils.notify(
      'this result cannot be edited: its rows cannot be traced back to where they are stored',
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

--- Order the rows by a column: in the query when it can run again, otherwise in the engine.
local function sort_by(column, add)
  local call = require('sqmeow.state').call
  local spec = M.spec()
  local sort = vim.deepcopy(spec.sort)
  local at
  for index, key in ipairs(sort) do
    if key.column == column then
      at = index
    end
  end
  local key = at and sort[at]

  if add then
    if not key then
      table.insert(sort, { column = column, descending = false })
    elseif not key.descending then
      key.descending = true
    else
      table.remove(sort, at)
    end
  elseif not key then
    sort = { { column = column, descending = false } }
  elseif not key.descending then
    sort = { { column = column, descending = true } }
  else
    sort = {}
  end

  if not (call and M.queried(call)) then
    spec.sort = sort
    M.send_view()
    return
  end
  local keys = {}
  for _, entry in ipairs(sort) do
    local described = (call.columns or {})[entry.column + 1]
    table.insert(
      keys,
      M.quote(described and described.name or '') .. (entry.descending and ' DESC' or '')
    )
  end
  M.rerun({ sort = sort, order_by = table.concat(keys, ', ') })
end

-- -- actions --------------------------------------------------------------------------------

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

--- Cut text to a display width, ending in `marker` when anything was cut. The row detail uses it too.
M.truncate = truncate

--- Write the whole result to a file.
function M.actions.export()
  require('sqmeow.api').export()
end

--- Write the rows the visual selection covers to a file.
function M.actions.export_selection()
  local first, last = vim.fn.line('v'), vim.fn.line('.')
  if first > last then
    first, last = last, first
  end
  vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })

  -- Buffer lines to rows of this page: the column names and the rule above them are not rows.
  first = math.max(first - HEADER_LINES, 1)
  last = math.min(last - HEADER_LINES, #page.rows)
  if last < first then
    return
  end
  require('sqmeow.api').export({ offset = page.offset + first - 1, limit = last - first + 1 })
end

--- Show the row under the cursor as a list of columns and values.
function M.actions.detail()
  local cell = M.current_cell()
  if not (cell and cell.row) then
    return
  end
  require('sqmeow.ui.detail').open(cell.row)
end

function M.actions.toggle_float()
  M.toggle_float()
end

--- Show the columns and indexes of the table the column under the cursor comes from.
function M.actions.structure()
  local call = require('sqmeow.state').call
  local tables = call and call.source and call.source.tables
  if not (call and tables and #tables > 0) then
    return utils.notify('this result cannot be traced back to a table', vim.log.levels.WARN)
  end
  local here = cursor_column()
  local chosen = tables[1]
  for _, candidate in ipairs(tables) do
    if here and vim.tbl_contains(candidate.columns, here.column) then
      chosen = candidate
      break
    end
  end
  require('sqmeow.ui.structure').open(call.conn_id, chosen.schema or '', chosen.name)
end

--- Show another statement's result from the same run.
---@param step integer
local function switch(step)
  local state = require('sqmeow.state')
  local call = state.call
  local results = call and call.results
  if not (call and results and #results > 1) then
    return utils.notify('this query returned one result')
  end
  if blocked() then
    return
  end
  local at = 1
  for index, entry in ipairs(results) do
    if entry.call_id == call.call_id then
      at = index
    end
  end
  local shown = vim.tbl_extend(
    'force',
    { conn_id = call.conn_id, statement = call.statement, history = false },
    results[(at - 1 + step) % #results + 1],
    { results = results }
  )
  state.call = shown
  M.render(shown)
end

function M.actions.next_result()
  switch(1)
end

function M.actions.prev_result()
  switch(-1)
end

--- Show only the rows holding the value under the cursor in its column.
function M.actions.filter_cell()
  local cell = M.current_cell()
  if not (cell and cell.row) then
    return
  end

  local call = require('sqmeow.state').call
  if call and M.queried(call) then
    local condition, err = require('sqmeow.rpc').request('condition', {
      call_id = call.call_id,
      row = cell.row,
      column = cell.column,
    })
    if not condition then
      return utils.notify(err or 'the value could not be matched', vim.log.levels.WARN)
    end
    local where = M.spec().where
    M.rerun({ where = where == '' and condition or ('(%s) AND %s'):format(where, condition) })
    return
  end

  local filter = { column = cell.column, op = 'is_null' }
  if cell.value ~= nil and cell.value ~= vim.NIL then
    filter = { column = cell.column, op = 'eq', value = tostring(cell.value) }
  end
  table.insert(M.spec().filters, filter)
  M.send_view()
end

function M.actions.filter()
  require('sqmeow.ui.filter').open(1)
end

function M.actions.order()
  require('sqmeow.ui.filter').open(2)
end

function M.actions.sort()
  local here = cursor_column()
  if here then
    sort_by(here.column, false)
  end
end

function M.actions.sort_add()
  local here = cursor_column()
  if here then
    sort_by(here.column, true)
  end
end

function M.actions.hide_column()
  local call = require('sqmeow.state').call
  local here = cursor_column()
  if not (call and here) then
    return
  end
  local spec = M.spec()
  if #call.columns - vim.tbl_count(spec.hidden) <= 1 then
    return utils.notify('the last column cannot be hidden', vim.log.levels.WARN)
  end
  spec.hidden[here.column] = true
  M.redraw()
end

function M.actions.show_columns()
  M.spec().hidden = {}
  M.redraw()
end

--- Clear the filters, sort and hidden columns, and show every row again.
function M.actions.reset_view()
  local call = require('sqmeow.state').call
  if not (call and call.call_id) then
    return
  end
  local spec = M.spec()
  if spec.where ~= '' or spec.order_by ~= '' then
    M.rerun({ where = '', order_by = '', sort = {}, filters = {}, hidden = {} })
    return
  end
  specs[call.call_id] = fresh()
  M.send_view()
end

function M.actions.edit_cell()
  local cell = editing() and M.current_cell()
  if cell then
    require('sqmeow.ui.edit').edit_cell(cell)
  end
end

function M.actions.set_null()
  local cell = editing() and M.current_cell()
  if not cell then
    return
  end
  local column = require('sqmeow.state').call.columns[cell.column + 1]
  if not (column and column.editable) then
    return utils.notify(('`%s` cannot be edited'):format(cell.name), vim.log.levels.WARN)
  end
  require('sqmeow.ui.edit').set(cell, cell.column, vim.NIL)
end

--- Stage a copy of the row under the cursor as a new row, leaving out its primary key.
function M.actions.duplicate_row()
  local cell = editing() and M.current_cell()
  if not (cell and cell.row) then
    return
  end
  local call = require('sqmeow.state').call
  if not (call and call.source and call.columns) then
    return
  end
  if not call.source.insertable then
    return utils.notify(
      'a row cannot be added to a result that shows more than one table',
      vim.log.levels.WARN
    )
  end
  local row, err = require('sqmeow.rpc').request('row', { call_id = call.call_id, row = cell.row })
  if not row then
    return utils.notify(err or 'that row is not there', vim.log.levels.WARN)
  end

  local edit = require('sqmeow.ui.edit')
  local values = {}
  for index, column in ipairs(call.columns) do
    -- A binary value's text is not the value.
    if column.editable and column.key ~= 'primary_key' and column.class ~= 'binary' then
      local staged, has = edit.staged(cell.row, index - 1)
      if has then
        values[index - 1] = staged
      elseif row[index] then
        values[index - 1] = row[index].is_null and vim.NIL or row[index].value
      end
    end
  end
  edit.add_row(values)
  if win then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(M.buffer()), 0 })
  end
end

function M.actions.add_row()
  if not editing() then
    return
  end
  if not require('sqmeow.state').call.source.insertable then
    return utils.notify(
      'a row cannot be added to a result that shows more than one table',
      vim.log.levels.WARN
    )
  end
  require('sqmeow.ui.edit').add_row()
  if win then
    local last = vim.api.nvim_buf_line_count(M.buffer())
    vim.api.nvim_win_set_cursor(win, { last, 0 })
  end
end

function M.actions.delete_row()
  local cell = editing() and M.current_cell()
  if cell then
    require('sqmeow.ui.edit').toggle_delete({ cell })
  end
end

function M.actions.delete_selection()
  local targets = selected()
  if editing() and #targets > 0 then
    require('sqmeow.ui.edit').toggle_delete(targets)
  end
end

function M.actions.undo()
  if editing() and not require('sqmeow.ui.edit').undo() then
    utils.notify('there is nothing to undo')
  end
end

function M.actions.discard()
  if not editing() then
    return
  end
  local dropped = require('sqmeow.ui.edit').reset()
  M.redraw()
  utils.notify(('discarded %d change%s'):format(dropped, dropped == 1 and '' or 's'))
end

function M.actions.review()
  if editing() then
    require('sqmeow.ui.edit').review()
  end
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
  if win and utils.shows(win, buf) then
    return win
  end
  if popup then
    -- Closed some other way than through here, such as `:close`, which leaves nui a mount to undo.
    popup:unmount()
    popup = nil
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
  M.update_winbar(require('sqmeow.state').call)
  return win
end

--- The window showing the grid, or nil.
---@return integer|nil
function M.window()
  return utils.shows(win, buf) and win or nil
end

--- Hide the result window, keeping what it holds.
function M.close()
  require('sqmeow.ui.filter').close()
  if popup then
    local closing = popup
    popup = nil
    closing:unmount()
  elseif win and utils.shows(win, buf) then
    require('sqmeow.ui.layout').close_window(win)
  end
  win = nil

  require('sqmeow.ui.detail').close()
  require('sqmeow.ui.layout').restore()
end

--- Whether the result window is showing, in its split or its float.
---@return boolean
function M.is_open()
  return utils.shows(win, buf)
end

--- Update the line above the grid.
---@param summary sqmeow.CallSummary|nil
function M.update_winbar(summary)
  if not utils.shows(win, buf) or not require('sqmeow.config').get().ui.winbar then
    return
  end

  -- The connection the result came from, not the active one.
  local state = require('sqmeow.state')
  ---@type { name: string, dialect: string|nil }|nil
  local connection = summary and summary.conn_id and state.connections[summary.conn_id]
  if not connection and summary and summary.connection then
    -- A result shown from the log names the database it came from, whether or not that is open.
    connection = { name = summary.connection, dialect = summary.dialect }
  end
  connection = connection or state.current_connection()
  local label = connection and state.label(connection) or 'not connected'

  vim.wo[win].winbar = ('%%#SqmeowWinbar# %s  %%*%s'):format(label, M.describe(summary, true))
end

return M
