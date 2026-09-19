--- A table grid in the result's style, structured after Nui's `Table`: nested column
--- definitions with `row_span`/`col_span`, per-cell ranges, and cursor movement over one
--- continuous header/data/footer grid. Drawn with the `Sqmeow*` highlights and `│`/`─┼─`
--- separators instead of a box border.
---
---@alias sqmeow.TableAlign 'left'|'center'|'right'
---@alias sqmeow.TableHeaderKind 1|-1
---@alias sqmeow.TableSegment { [1]: string, [2]: string|nil }

---@class sqmeow.Table.ColumnDef
---@field id? string Required when `header` is not a string.
---@field accessor_key? string
---@field accessor_fn? fun(row: table, index: integer): any
---@field header? string|table|fun(info: { column: table }): any
---@field footer? string|table|fun(info: { column: table }): any
---@field cell? fun(info: sqmeow.Table.Cell): any
---@field align? sqmeow.TableAlign
---@field hl? string Default highlight for the column's cells.
---@field width? integer Fixed width; content is cut to it.
---@field min_width? integer
---@field max_width? integer
---@field columns? sqmeow.Table.ColumnDef[] Nested children.
---@field depth? integer Assigned by the table.
---@field parent? sqmeow.Table.ColumnDef|nil Assigned by the table.
---@field _fixed_width? integer|nil Private; a set `width` never flexes.

---@class sqmeow.Table.Row
---@field id string
---@field index integer
---@field original table

---@class sqmeow.Table.Cell
---@field type 'data'
---@field row sqmeow.Table.Row
---@field column sqmeow.Table.ColumnDef
---@field content any Raw value; `segments` is what is drawn.
---@field segments sqmeow.TableSegment[]
---@field get_value fun(): any
---@field range integer[] { line, start_display, line, end_display }

---@class sqmeow.Table.HeaderCell
---@field type 'header'|'footer'
---@field column sqmeow.Table.ColumnDef
---@field content any
---@field segments sqmeow.TableSegment[]
---@field col_span integer
---@field row_span integer
---@field ridx integer Which slice of a tall cell this line shows.
---@field range integer[] { line, start_display, line, end_display }

---@class sqmeow.Table.BuiltLine
---@field text string
---@field hls { [1]: integer, [2]: integer, [3]: string }[] Byte ranges with a highlight.

local utils = require('sqmeow.utils')

local M = {}
M.__index = M

local HEADER_HL = 'SqmeowHeader'
local RULE_HL = 'SqmeowRule'

--- Characters the grid is drawn with.
local function glyphs()
  return require('sqmeow.config').get().icons.grid
end

---@param text string
---@return integer
local function strwidth(text)
  return vim.api.nvim_strwidth(text)
end

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

--- Whatever a header, footer or cell returned, as drawable pieces.
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

---@param internal table
---@param columns sqmeow.Table.ColumnDef[]
---@param parent? sqmeow.Table.ColumnDef
---@param depth? integer
local function prepare_columns(internal, columns, parent, depth)
  for _, col in ipairs(columns) do
    if col.header then
      internal.has_header = true
    end
    if col.footer then
      internal.has_footer = true
    end

    if not col.id then
      local header = col.header
      col.id = col.accessor_key or (type(header) == 'string' and header or nil)
    end
    if not col.id then
      error('sqmeow: table column is missing an id')
    end

    if col.accessor_key and not col.accessor_fn then
      local key = col.accessor_key
      col.accessor_fn = function(row)
        return row[key]
      end
    end

    col.depth = depth or 0
    col.parent = parent

    if parent and not col.header then
      col.header = col.id
      internal.has_header = true
    end

    if col.columns then
      prepare_columns(internal, col.columns, col, col.depth + 1)
    else
      table.insert(internal.columns, col)
    end

    if col.depth == 0 then
      table.insert(internal.headers, col)
    else
      internal.headers.depth = math.max(internal.headers.depth, col.depth + 1)
    end

    col.align = col.align or 'left'
    col._fixed_width = col.width
    col.width = col.width or col.min_width or 0
  end
end

---@param columns sqmeow.Table.ColumnDef[]
local function reset_column_widths(columns)
  for _, col in ipairs(columns) do
    col.width = col._fixed_width or col.min_width or 0
    if col.columns then
      reset_column_widths(col.columns)
    end
  end
end

---@param column sqmeow.Table.ColumnDef
---@param width integer
local function fit_col_width(column, width)
  if column._fixed_width then
    return
  end
  local next_width = math.max(column.width, width)
  if column.max_width and next_width > column.max_width then
    next_width = column.max_width
  end
  column.width = next_width
end

---@param idx integer
---@param grid table
---@param kind sqmeow.TableHeaderKind
---@return table
local function get_header_row_at(idx, grid, kind)
  local row = grid[idx]
  if not row then
    row = { len = 0 }
    grid[idx] = row
    grid.len = math.max(grid.len, kind * idx)
  end
  return row
end

---@param kind sqmeow.TableHeaderKind
---@param columns table[]
---@param grid table
---@param max_depth integer
local function prepare_header_grid(kind, columns, grid, max_depth)
  for column_idx = 1, #columns do
    local column = columns[column_idx]
    local row_idx = kind + kind * column.depth
    local row = get_header_row_at(row_idx, grid, kind)

    -- A column with only a footer must not show it on the header line.
    local raw = kind == 1 and column.header or nil
    if kind == -1 then
      raw = column.footer
    end
    if type(raw) == 'function' then
      raw = raw({ column = column })
    end
    local segments = normalize(raw == nil and '' or raw, HEADER_HL)
    fit_col_width(column, segments_width(segments))

    local cell = {
      type = kind == 1 and 'header' or 'footer',
      column = column,
      content = raw,
      segments = segments,
      col_span = 1,
      row_span = 1,
      ridx = 1,
    }
    row.len = row.len + 1
    row[row.len] = cell

    if column.columns then
      cell.col_span = #column.columns
      prepare_header_grid(kind, column.columns, grid, max_depth)
    else
      cell.row_span = max_depth - column.depth
      for i = 1, cell.row_span - 1 do
        local span_row = get_header_row_at(row_idx + i * kind, grid, kind)
        span_row.len = span_row.len + 1
        span_row[span_row.len] = vim.tbl_extend('keep', { ridx = i + 1 }, cell)
      end
    end
  end
end

---@param cell sqmeow.Table.Cell
---@return any
local function prepare_cell_content(cell)
  if cell.column.cell then
    return cell.column.cell(cell)
  end
  return cell.get_value()
end

--- Create a table bound to a buffer.
---@param options { bufnr: integer, ns_id?: integer|string, columns?: sqmeow.Table.ColumnDef[], data?: table[], show_header?: boolean, trim?: boolean }
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
    show_header = options.show_header ~= false,
    _ = {
      headers = { depth = 1 },
      columns = {},
      data = options.data or {},
      has_header = false,
      has_footer = false,
      linenr = {},
      line_cells = {},
      nav_linenrs = {},
      size = nil,
    },
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
  self._.headers = { depth = 1 }
  self._.columns = {}
  self._.has_header = false
  self._.has_footer = false
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

--- Leaf columns, left to right.
---@return sqmeow.Table.ColumnDef[]
function M:leaf_columns()
  return self._.columns
end

--- Dimensions of the last render.
---@return { width: integer, height: integer }|nil
function M:get_size()
  return self._.size
end

--- First and last buffer lines of the last render.
---@return integer|nil first
---@return integer|nil last
function M:range()
  return self._.linenr[1], self._.linenr[2]
end

---@return integer separator display width between leaf columns
function M:_separator_width()
  return strwidth(glyphs().vertical) + 2
end

--- Display width a cell occupies: its column's, or its leaves' together.
---@param cell table
---@return integer
function M:_cell_width(cell)
  local column = cell.column
  if not column.columns then
    return column.width
  end
  local total = 0
  for i = 1, cell.col_span do
    total = total + column.columns[i].width
  end
  return total + self:_separator_width() * (cell.col_span - 1)
end

---@return table data_grid
---@return table header_grid
function M:_prepare_grid()
  reset_column_widths(self._.headers)

  ---@type table
  local header_grid = { len = 0 }
  if self._.has_header and self.show_header then
    prepare_header_grid(1, self._.headers, header_grid, self._.headers.depth)
  end

  ---@type table
  local data_grid = { len = #self._.data }
  local columns = self._.columns
  for row_idx = 1, data_grid.len do
    data_grid[row_idx] = {}
    local row = { id = tostring(row_idx), index = row_idx, original = self._.data[row_idx] }
    for column_idx = 1, #columns do
      local column = columns[column_idx]
      local cell = {
        type = 'data',
        row = row,
        column = column,
        get_value = function()
          return column.accessor_fn and column.accessor_fn(row.original, row.index) or nil
        end,
      }
      cell.content = prepare_cell_content(cell)
      cell.segments = normalize(cell.content, column.hl)
      fit_col_width(column, segments_width(cell.segments))
      data_grid[row_idx][column_idx] = cell
    end
  end

  if self._.has_footer then
    prepare_header_grid(-1, self._.headers, header_grid, self._.headers.depth)
  end

  return data_grid, header_grid
end

---@return sqmeow.Table.BuiltLine
function M:_new_line()
  return { text = '', hls = {} }
end

---@param built sqmeow.Table.BuiltLine
---@param text string
---@param hl string|nil
function M:_append(built, text, hl)
  if text == '' then
    return
  end
  local from = #built.text
  built.text = built.text .. text
  if hl then
    table.insert(built.hls, { from, #built.text, hl })
  end
end

--- Append `segments` cut and padded to exactly `width` display columns.
---@param built sqmeow.Table.BuiltLine
---@param segments sqmeow.TableSegment[]
---@param width integer
---@param align sqmeow.TableAlign
function M:_append_padded(built, segments, width, align)
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

  self:_append(built, (' '):rep(left))
  for _, segment in ipairs(fitted) do
    self:_append(built, segment[1], segment[2])
  end
  self:_append(built, (' '):rep(right))
end

--- One visual line of cells, separated by the vertical glyph.
---@param cells table[]
---@return sqmeow.Table.BuiltLine
function M:_build_cells_line(cells)
  local vertical = glyphs().vertical
  local built = self:_new_line()
  self:_append(built, ' ')
  for index, cell in ipairs(cells) do
    if index > 1 then
      self:_append(built, ' ')
      self:_append(built, vertical, RULE_HL)
      self:_append(built, ' ')
    end
    -- A tall cell only draws its text on the line its span ends at.
    local drawn = (cell.ridx == nil or cell.ridx == cell.row_span) and cell.segments or {}
    self:_append_padded(built, drawn, self:_cell_width(cell), cell.column.align)
  end
  if self.trim then
    built.text = built.text:gsub('%s+$', '')
  end
  return built
end

--- The `─┼─` rule under the header or over the footer.
---@param leaves sqmeow.Table.ColumnDef[]
---@return sqmeow.Table.BuiltLine
function M:_build_rule(leaves)
  local marks = glyphs()
  local joint = marks.horizontal .. marks.cross .. marks.horizontal
  local parts = {}
  for _, column in ipairs(leaves) do
    table.insert(parts, marks.horizontal:rep(column.width))
  end
  local built = self:_new_line()
  self:_append(built, marks.horizontal .. table.concat(parts, joint), RULE_HL)
  return built
end

--- Draw the table into its buffer.
---@param linenr_start? integer First buffer line, 1-based.
function M:render(linenr_start)
  if not vim.api.nvim_buf_is_valid(self.bufnr) or #self._.columns == 0 then
    return
  end
  linenr_start = math.max(1, linenr_start or self._.linenr[1] or 1)
  local prev_first, prev_last = self._.linenr[1], self._.linenr[2]

  local data_grid, header_grid = self:_prepare_grid()
  local leaves = self._.columns

  self._.line_cells = {}
  self._.nav_linenrs = {}
  ---@type sqmeow.Table.BuiltLine[]
  local built_lines = {}

  --- Draw one row of cells and remember where each cell landed.
  local function emit(cells)
    local built = self:_build_cells_line(cells)
    table.insert(built_lines, built)
    local lnum = linenr_start + #built_lines - 1
    local at = 0
    for _, cell in ipairs(cells) do
      cell.range = { lnum, at, lnum, at + self:_cell_width(cell) }
      at = cell.range[4] + self:_separator_width()
    end
    self._.line_cells[lnum] = cells
    table.insert(self._.nav_linenrs, lnum)
  end

  --- The cells of one header or footer grid row, as a plain list.
  local function cells_of(row)
    local cells = {}
    for i = 1, row.len do
      cells[i] = row[i]
    end
    return cells
  end

  for row_idx = 1, header_grid.len do
    local row = header_grid[row_idx]
    if not row then
      break
    end
    emit(cells_of(row))
  end
  if #built_lines > 0 then
    table.insert(built_lines, self:_build_rule(leaves))
  end

  for row_idx = 1, data_grid.len do
    emit(data_grid[row_idx])
  end

  if header_grid[-1] then
    table.insert(built_lines, self:_build_rule(leaves))
    for row_idx = -header_grid.len, -1 do
      local row = header_grid[row_idx]
      if row then
        emit(cells_of(row))
      end
    end
  end

  local texts, width = {}, 0
  for i, built in ipairs(built_lines) do
    texts[i] = built.text
    width = math.max(width, strwidth(built.text))
  end
  self._.size = { width = width, height = #built_lines }

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)

  local from = math.min(linenr_start, prev_first or linenr_start)
  local to = prev_last or from - 1
  -- An untouched buffer holds one empty line, which the first render replaces.
  if not prev_first and from == 1 and vim.api.nvim_buf_line_count(self.bufnr) == 1 then
    to = vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] == '' and 1 or 0
  end
  if linenr_start > from then
    -- Rendering lower than before leaves the lines above it blank.
    local padded = {}
    for _ = 1, linenr_start - from do
      table.insert(padded, '')
    end
    texts = vim.list_extend(padded, texts)
  end
  vim.api.nvim_buf_set_lines(self.bufnr, from - 1, to, false, texts)

  for index, built in ipairs(built_lines) do
    local lnum = linenr_start + index - 1
    for _, hl in ipairs(built.hls) do
      vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, lnum - 1, hl[1], {
        end_col = hl[2],
        hl_group = hl[3],
      })
    end
  end

  vim.bo[self.bufnr].modifiable = false
  self._.linenr[1], self._.linenr[2] = linenr_start, linenr_start + #built_lines - 1
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
    local ok = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == self.bufnr
    return ok and win or nil
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
  local text = vim.api.nvim_buf_get_lines(self.bufnr, target_line - 1, target_line, false)[1] or ''
  vim.api.nvim_win_set_cursor(win, { target_line, utils.byte_at(text, target_display) })
  return cell
end

--- Put the cursor on a leaf column, keeping its line.
---@param index integer One-based leaf column.
---@param win? integer Window showing the table.
---@return boolean moved
function M:goto_column(index, win)
  win = self:_win(win)
  local wanted = self._.columns[index]
  if not (win and wanted) then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local cells = self._.line_cells[line]
  if not cells then
    return false
  end

  -- On a group header line the column to land on is the leaf's ancestor.
  local family = { [wanted] = true }
  local parent = wanted.parent
  while parent do
    family[parent] = true
    parent = parent.parent
  end

  for _, cell in ipairs(cells) do
    if family[cell.column] then
      local text = vim.api.nvim_buf_get_lines(self.bufnr, line - 1, line, false)[1] or ''
      vim.api.nvim_win_set_cursor(win, { line, utils.byte_at(text, cell.range[2] + 1) })
      return true
    end
  end
  return false
end

--- Redraw one data cell in place, or the whole table when its column must grow.
---@param cell sqmeow.Table.Cell
function M:refresh_cell(cell)
  assert(cell and cell.range, 'sqmeow: refresh_cell needs a rendered cell')
  local column = cell.column
  cell.content = prepare_cell_content(cell)
  cell.segments = normalize(cell.content, column.hl)

  local capped = column._fixed_width or (column.max_width and column.width >= column.max_width)
  if segments_width(cell.segments) > column.width and not capped then
    self:render()
    return
  end

  local lnum = cell.range[1]
  local cells = self._.line_cells[lnum]
  if not cells then
    return
  end
  local built = self:_build_cells_line(cells)

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, lnum - 1, lnum, false, { built.text })
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, lnum - 1, lnum)
  for _, hl in ipairs(built.hls) do
    vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, lnum - 1, hl[1], {
      end_col = hl[2],
      hl_group = hl[3],
    })
  end
  vim.bo[self.bufnr].modifiable = false
end

return M
