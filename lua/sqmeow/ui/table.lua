--- A table grid in the result's style: a header line, a `─┼─` rule, then one line per row,
--- with per-cell ranges and cursor movement over the header and data lines. Drawn with
--- the `Sqmeow*` highlights and `│` separators instead of a box border.
---
---@alias sqmeow.TableAlign 'left'|'center'|'right'
---@alias sqmeow.TableSegment { [1]: string, [2]: string|nil }

---@class sqmeow.Table.ColumnDef
---@field id? string Required when `header` is not a string.
---@field accessor_key? string
---@field accessor_fn? fun(row: table, index: integer): any
---@field header? string|table|fun(info: { column: table }): any
---@field cell? fun(info: sqmeow.Table.Cell): any A `fill` field on the result highlights the whole cell.
---@field align? sqmeow.TableAlign
---@field width? integer Fixed width; content is cut to it.
---@field _fixed_width? integer|nil Private; a set `width` never flexes.

---@class sqmeow.Table.Row
---@field id string
---@field index integer
---@field original table

---@class sqmeow.Table.Cell
---@field type 'data'|'header'
---@field row? sqmeow.Table.Row Data cells only.
---@field column sqmeow.Table.ColumnDef
---@field content any Raw value; `segments` is what is drawn.
---@field segments sqmeow.TableSegment[]
---@field get_value? fun(): any
---@field range integer[] { line, start_display, line, end_display }

---@class sqmeow.Table.BuiltLine
---@field text string
---@field hls { [1]: integer, [2]: integer, [3]: string, [4]: integer|nil }[] Byte ranges with a highlight and priority.
---@field line_hl string|nil Highlight for the whole line.

---@alias sqmeow.Table.RowMark { mark: string, mark_hl: string|nil, line_hl: string|nil }

local utils = require('sqmeow.core.utils')

local M = {}
M.__index = M

local HEADER_HL = 'SqmeowHeader'
local LINE_PRIORITY = 100
local FILL_PRIORITY = 150
local RULE_HL = 'SqmeowRule'

--- Characters the grid is drawn with.
local function glyphs()
  return require('sqmeow.config').get().icons.grid
end

local strwidth = vim.api.nvim_strwidth

--- Display width of every segment together.
---@param segments sqmeow.TableSegment[]
---@return integer
local function segments_width(segments)
  local total = 0
  for _, segment in ipairs(segments) do
    total = total + strwidth(segment[1])
  end
  return total
end

--- Escapes what a buffer line cannot hold.
---@param text string
---@return string
local function sanitize(text)
  return (text:gsub('[\n\r\t]', { ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }))
end

--- Whatever a header or cell returned, as drawable pieces.
---@param content any A string, a `{ text, hl }` pair, or a list of either.
---@param default_hl string|nil
---@return sqmeow.TableSegment[]
local function normalize(content, default_hl)
  if content == nil or content == vim.NIL then
    return default_hl and { { '', default_hl } } or {}
  end
  if type(content) ~= 'table' then
    return { { sanitize(tostring(content)), default_hl } }
  end
  if type(content[1]) == 'string' and #content <= 2 then
    return { { sanitize(content[1]), content[2] or default_hl } }
  end

  local out = {}
  for _, entry in ipairs(content) do
    if type(entry) == 'string' then
      table.insert(out, { sanitize(entry), default_hl })
    elseif type(entry) == 'table' and type(entry[1]) == 'string' then
      table.insert(out, { sanitize(entry[1]), entry[2] or default_hl })
    end
  end
  if #out == 0 then
    return { { sanitize(tostring(content)), default_hl } }
  end
  return out
end

---@param self table
---@param columns sqmeow.Table.ColumnDef[]
local function prepare_columns(self, columns)
  self.columns, self.has_header = columns, false
  for _, col in ipairs(columns) do
    if col.header then
      self.has_header = true
    end
    local header = col.header
    col.id = col.id or col.accessor_key or (type(header) == 'string' and header or nil)
    if not col.id then
      error('sqmeow: table column is missing an id')
    end
    if col.accessor_key and not col.accessor_fn then
      local key = col.accessor_key
      col.accessor_fn = function(row)
        return row[key]
      end
    end
    col.align = col.align or 'left'
    col._fixed_width = col.width
  end
end

--- Grow a column to fit `segments`, unless its width is fixed.
---@param column sqmeow.Table.ColumnDef
---@param segments sqmeow.TableSegment[]
local function fit(column, segments)
  if not column._fixed_width then
    column.width = math.max(column.width, segments_width(segments))
  end
end

--- Create a table bound to a buffer.
---@param options { bufnr: integer, ns_id?: integer|string, columns?: sqmeow.Table.ColumnDef[], data?: table[], trim?: boolean, row_mark?: fun(row: sqmeow.Table.Row): sqmeow.Table.RowMark|nil }
---@return table
function M.new(options)
  assert(options and options.bufnr, 'sqmeow: table needs a bufnr')
  assert(vim.api.nvim_buf_is_valid(options.bufnr), 'sqmeow: table bufnr is not valid')
  local ns = options.ns_id
  if type(ns) == 'string' then
    ns = vim.api.nvim_create_namespace(ns)
  end

  local self = setmetatable({
    bufnr = options.bufnr,
    ns_id = ns or vim.api.nvim_create_namespace('sqmeow.table'),
    trim = options.trim or false,
    --- A one-column marker before a data row, and a highlight for its line.
    row_mark = options.row_mark,
    _ = { data = options.data or {}, linenr = {}, line_cells = {}, nav_linenrs = {} },
  }, M)
  prepare_columns(self._, options.columns or {})
  return self
end

--- Draw into another buffer from the next render on.
---@param bufnr integer
---@return table self
function M:set_buffer(bufnr)
  assert(vim.api.nvim_buf_is_valid(bufnr), 'sqmeow: table bufnr is not valid')
  self.bufnr = bufnr
  self._.linenr = {}
  self._.line_cells = {}
  self._.nav_linenrs = {}
  return self
end

--- Replace the columns and forget computed widths.
---@param columns sqmeow.Table.ColumnDef[]
---@return table self
function M:set_columns(columns)
  prepare_columns(self._, columns or {})
  return self
end

--- Replace the rows; widths are recomputed on the next render.
---@param data table[]|nil
---@return table self
function M:set_data(data)
  self._.data = data or {}
  return self
end

---@return integer separator display width between columns
local function separator_width()
  return strwidth(glyphs().vertical) + 2
end

---@param built sqmeow.Table.BuiltLine
---@param text string
---@param hl string|nil
---@param priority integer|nil
local function append(built, text, hl, priority)
  if text == '' then
    return
  end
  local from = #built.text
  built.text = built.text .. text
  if hl then
    table.insert(built.hls, { from, #built.text, hl, priority })
  end
end

--- Append `segments` cut and padded to exactly `width` display columns.
---@param built sqmeow.Table.BuiltLine
---@param segments sqmeow.TableSegment[]
---@param width integer
---@param align sqmeow.TableAlign
local function append_padded(built, segments, width, align)
  local ellipsis = glyphs().ellipsis
  local fitted, used = {}, 0
  for _, segment in ipairs(segments) do
    local room = width - used
    if room <= 0 then
      break
    end
    local text = utils.truncate(segment[1], room, ellipsis)
    used = used + strwidth(text)
    table.insert(fitted, { text, segment[2] })
  end

  local room = width - used
  local left, right = 0, room
  if align == 'right' then
    left, right = room, 0
  elseif align == 'center' then
    left = math.floor(room / 2)
    right = room - left
  end

  append(built, (' '):rep(left))
  for _, segment in ipairs(fitted) do
    append(built, segment[1], segment[2])
  end
  append(built, (' '):rep(right))
end

--- One visual line of cells, separated by the vertical glyph.
---@param cells table[]
---@return sqmeow.Table.BuiltLine
function M:_build_cells_line(cells)
  local vertical = glyphs().vertical
  local built = { text = '', hls = {} }
  local row = cells[1] and cells[1].type == 'data' and cells[1].row
  local mark = row and self.row_mark and self.row_mark(row)
  if mark then
    append(built, mark.mark, mark.mark_hl)
    built.line_hl = mark.line_hl
  else
    append(built, ' ')
  end
  for index, cell in ipairs(cells) do
    if index > 1 then
      append(built, ' ')
      append(built, vertical, RULE_HL)
      append(built, ' ')
    end
    local from = #built.text
    append_padded(built, cell.segments, cell.column.width, cell.column.align)
    if cell.fill then
      -- Under the text's own highlight, so it keeps its colour.
      table.insert(built.hls, { from, #built.text, cell.fill, FILL_PRIORITY })
    end
  end
  if self.trim then
    built.text = built.text:gsub('%s+$', '')
    for _, hl in ipairs(built.hls) do
      hl[2] = math.min(hl[2], #built.text)
    end
  end
  return built
end

--- Place a built line's highlights on buffer line `lnum`.
---@param lnum integer 1-based.
---@param built sqmeow.Table.BuiltLine
function M:_mark_line(lnum, built)
  if built.line_hl then
    vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, lnum - 1, 0, {
      line_hl_group = built.line_hl,
      priority = LINE_PRIORITY,
    })
  end
  for _, hl in ipairs(built.hls) do
    if hl[2] > hl[1] then
      vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, lnum - 1, hl[1], {
        end_col = hl[2],
        hl_group = hl[3],
        priority = hl[4],
      })
    end
  end
end

--- Every line of cells: the header, if any column has one, then one per data row.
---@return table[][] lines
---@return boolean has_header
function M:_prepare_grid()
  local columns = self._.columns
  for _, column in ipairs(columns) do
    column.width = column._fixed_width or 0
  end

  local lines = {}
  if self._.has_header then
    local cells = {}
    for index, column in ipairs(columns) do
      local raw = column.header
      if type(raw) == 'function' then
        raw = raw({ column = column })
      end
      local segments = normalize(raw == nil and '' or raw, HEADER_HL)
      fit(column, segments)
      cells[index] = { type = 'header', column = column, content = raw, segments = segments }
    end
    table.insert(lines, cells)
  end

  for row_idx, original in ipairs(self._.data) do
    local row = { id = tostring(row_idx), index = row_idx, original = original }
    local cells = {}
    for index, column in ipairs(columns) do
      local cell = {
        type = 'data',
        row = row,
        column = column,
        get_value = function()
          return column.accessor_fn and column.accessor_fn(row.original, row.index) or nil
        end,
      }
      if column.cell then
        cell.content = column.cell(cell)
      else
        cell.content = cell.get_value()
      end
      cell.segments = normalize(cell.content)
      cell.fill = type(cell.content) == 'table' and cell.content.fill or nil
      fit(column, cell.segments)
      cells[index] = cell
    end
    table.insert(lines, cells)
  end
  return lines, self._.has_header
end

--- Draw the table into its buffer, from its first line.
function M:render()
  if not vim.api.nvim_buf_is_valid(self.bufnr) or #self._.columns == 0 then
    return
  end
  local prev_first, prev_last = self._.linenr[1], self._.linenr[2]
  local grid, has_header = self:_prepare_grid()

  self._.line_cells = {}
  self._.nav_linenrs = {}
  ---@type sqmeow.Table.BuiltLine[]
  local built_lines = {}
  for index, cells in ipairs(grid) do
    table.insert(built_lines, self:_build_cells_line(cells))
    local lnum = #built_lines
    local at = 0
    for _, cell in ipairs(cells) do
      cell.range = { lnum, at, lnum, at + cell.column.width }
      at = cell.range[4] + separator_width()
    end
    self._.line_cells[lnum] = cells
    table.insert(self._.nav_linenrs, lnum)

    if index == 1 and has_header then
      local marks = glyphs()
      local parts = {}
      for _, column in ipairs(self._.columns) do
        table.insert(parts, marks.horizontal:rep(column.width))
      end
      local joint = marks.horizontal .. marks.cross .. marks.horizontal
      local rule = { text = '', hls = {} }
      append(rule, marks.horizontal .. table.concat(parts, joint), RULE_HL)
      table.insert(built_lines, rule)
    end
  end

  local texts = {}
  for i, built in ipairs(built_lines) do
    texts[i] = built.text
  end

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)
  local to = prev_last or 0
  -- An untouched buffer holds one empty line, which the first render replaces.
  if not prev_first and vim.api.nvim_buf_line_count(self.bufnr) == 1 then
    to = vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] == '' and 1 or 0
  end
  vim.api.nvim_buf_set_lines(self.bufnr, 0, to, false, texts)
  for index, built in ipairs(built_lines) do
    self:_mark_line(index, built)
  end
  vim.bo[self.bufnr].modifiable = false
  self._.linenr[1], self._.linenr[2] = 1, #built_lines
end

--- The cell on a line whose display range holds `display`.
--- On a separator, bias to the cell on the right.
---@param cells table[]
---@param display integer
---@return table|nil
local function resolve_cell_at(cells, display)
  for _, cell in ipairs(cells) do
    if cell.range and cell.range[2] < display and display <= cell.range[4] then
      return cell
    end
  end
  for _, cell in ipairs(cells) do
    if cell.range and cell.range[2] >= display then
      return cell
    end
  end
  return nil
end

--- Find a window showing this table's buffer.
---@param win integer|nil
---@return integer|nil
function M:_win(win)
  if win then
    return utils.shows(win, self.bufnr) and win or nil
  end
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == self.bufnr then
    return current
  end
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(candidate) == self.bufnr then
      return candidate
    end
  end
  return nil
end

---@param line integer Buffer line.
---@param display integer Display column.
---@param position? integer[] `{ row_delta, col_delta }` relative move.
---@return table|nil cell
---@return integer|nil target_line
---@return integer|nil target_display
function M:_resolve_cell(line, display, position)
  local row_delta = position and position[1] or 0
  local col_delta = position and position[2] or 0

  local nav = self._.nav_linenrs
  local index = nil
  for i = 1, #nav do
    if nav[i] == line then
      index = i
      break
    end
  end
  if not index then
    return nil
  end

  local target_line = line
  if row_delta ~= 0 then
    target_line = nav[index + row_delta]
    if not target_line then
      return nil
    end
  end

  local cells = self._.line_cells[target_line]
  local cell = cells and resolve_cell_at(cells, display)
  if not cell then
    return nil
  end

  if col_delta == 0 then
    -- A vertical move keeps the display column; staying put snaps to the cell.
    return cell, target_line, row_delta ~= 0 and display or cell.range[2] + 1
  end

  local cell_index = nil
  for i = 1, #cells do
    if cells[i] == cell then
      cell_index = i
      break
    end
  end
  cell = cell_index and cells[cell_index + col_delta] or nil
  if not cell then
    return nil
  end
  return cell, target_line, cell.range[2] + 1
end

---@param win integer
---@return integer line
---@return integer display
function M:_cursor(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local text = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
  return cursor[1], utils.display_at(text, cursor[2])
end

--- Put the cursor in `win` on a display column of a line.
---@param win integer
---@param line integer
---@param display integer
function M:_place(win, line, display)
  local text = vim.api.nvim_buf_get_lines(self.bufnr, line - 1, line, false)[1] or ''
  vim.api.nvim_win_set_cursor(win, { line, utils.byte_at(text, display) })
end

--- The cell under the cursor, or relative to it.
---@param position? integer[] `{ row_delta, col_delta }`, e.g. `{ 1, 0 }` for below.
---@param win? integer Window showing the table; defaults to one that does.
---@return table|nil
function M:get_cell(position, win)
  win = self:_win(win)
  if not win then
    return nil
  end
  local line, display = self:_cursor(win)
  return (self:_resolve_cell(line, display, position))
end

--- Move the cursor to the cell relative to the one under it.
--- Vertical moves keep the display column; horizontal ones snap to content.
---@param position? integer[] `{ row_delta, col_delta }`.
---@param win? integer Window showing the table; defaults to one that does.
---@return table|nil cell The cell moved to, or nil past the edges.
function M:goto_cell(position, win)
  win = self:_win(win)
  if not win then
    return nil
  end
  local line, display = self:_cursor(win)
  local cell, target_line, target_display = self:_resolve_cell(line, display, position)
  if not (cell and target_line and target_display) then
    return nil
  end
  self:_place(win, target_line, target_display)
  return cell
end

--- Put the cursor on a column, keeping its line.
---@param index integer One-based column.
---@param win? integer Window showing the table.
---@return boolean moved
function M:goto_column(index, win)
  win = self:_win(win)
  local wanted = self._.columns[index]
  if not (win and wanted) then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  for _, cell in ipairs(self._.line_cells[line] or {}) do
    if cell.column == wanted then
      self:_place(win, line, cell.range[2] + 1)
      return true
    end
  end
  return false
end

--- Move one column over, wrapping to the column at `wrap` past the edge.
---@param win integer|nil
---@param step integer
---@param wrap integer
---@return table|nil
function M:_step_column(win, step, wrap)
  win = self:_win(win)
  if not win then
    return nil
  end
  local cell = self:goto_cell({ 0, step }, win)
  if cell then
    return cell
  end
  if wrap > 0 and self:goto_column(wrap, win) then
    return self:get_cell(nil, win)
  end
  return nil
end

--- Move one column right, wrapping to the first column past the last one.
---@param win? integer Window showing the table.
---@return table|nil cell The cell moved to, or nil off the grid.
function M:next_column(win)
  return self:_step_column(win, 1, math.min(#self._.columns, 1))
end

--- Move one column left, wrapping to the last column past the first one.
---@param win? integer Window showing the table.
---@return table|nil cell The cell moved to, or nil off the grid.
function M:prev_column(win)
  return self:_step_column(win, -1, #self._.columns)
end

return M
