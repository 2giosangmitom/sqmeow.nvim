--- A small table grid in the result's style, with Nui-inspired structure.
---
--- Nui's `Table` is not used here on purpose: this keeps the `│` separators,
--- the `─┼─` rule and the `Sqmeow*` highlights the result grid already draws
--- with, while borrowing the parts of Nui worth keeping: nested column defs
--- with `row_span`/`col_span`, per-cell ranges, and cursor movement over one
--- continuous header/data/footer grid.
---
---@alias sqmeow.TableAlign 'left'|'center'|'right'
---@alias sqmeow.TableHeaderKind 1|-1
---@alias sqmeow.TableSegment { [1]: string, [2]: string|nil }

---@class sqmeow.Table.ColumnDef
---@field id? string
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

local M = {}
M.__index = M

--- Characters the grid is drawn with, from the configuration.
local function glyphs()
  local ok, config = pcall(require, 'sqmeow.config')
  if ok and config.get then
    return config.get().icons.grid
  end
  return { vertical = '│', horizontal = '─', cross = '┼', ellipsis = '…' }
end

--- Display width of one string.
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

--- Cut `text` to `limit` display columns, ending in `marker` when cut.
---@param text string
---@param limit integer
---@param marker string
---@return string
local function truncate(text, limit, marker)
  if strwidth(text) <= limit then
    return text
  end
  if limit <= 0 then
    return ''
  end
  local budget = math.max(limit - strwidth(marker), 0)
  local out, at = {}, 0
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local step = strwidth(char)
    if at + step > budget then
      break
    end
    at = at + step
    table.insert(out, char)
  end
  return table.concat(out) .. marker
end

--- Read one Nui text-ish value as segments, best effort.
---@param value any
---@param out sqmeow.TableSegment[]
local function append_nui_value(value, out)
  if type(value) == 'string' then
    table.insert(out, { value })
    return
  end
  if type(value) ~= 'table' then
    return
  end
  if type(value.content) == 'string' then
    local hl = value.hl_group or value.hl
    table.insert(out, { value.content, hl })
    return
  end
  if type(value._content) == 'string' then
    table.insert(out, { value._content, value.hl_group })
    return
  end
end

--- Whatever a header/cell/formatter returned, as drawable pieces.
---@param content any
---@param default_hl string|nil
---@return sqmeow.TableSegment[]
local function normalize(content, default_hl)
  if content == nil or content == vim.NIL then
    return default_hl and { { '', default_hl } } or {}
  end
  local kind = type(content)
  if kind == 'string' then
    return { { content, default_hl } }
  end
  if kind == 'number' or kind == 'boolean' then
    return { { tostring(content), default_hl } }
  end
  if kind ~= 'table' then
    return { { tostring(content), default_hl } }
  end
  -- A NuiLine: a list of NuiTexts under `_texts`.
  if content._texts then
    local out = {}
    for _, text in ipairs(content._texts) do
      if type(text) == 'string' then
        table.insert(out, { text, default_hl })
      elseif type(text.content) == 'string' then
        table.insert(out, { text.content, text.hl_group or default_hl })
      elseif type(text._content) == 'string' then
        table.insert(out, { text._content, text.hl_group or default_hl })
      elseif type(text.content) == 'function' then
        local ok, value = pcall(text.content, text)
        if ok and type(value) == 'string' then
          table.insert(out, { value, text.hl_group or default_hl })
        end
      end
    end
    return out
  end
  -- A NuiText.
  if type(content.content) == 'string' or type(content._content) == 'string' then
    local out = {}
    append_nui_value(content, out)
    if #out > 0 then
      if default_hl and not out[1][2] then
        out[1][2] = default_hl
      end
      return out
    end
  end
  if type(content.content) == 'function' then
    local ok, value = pcall(content.content, content)
    if ok then
      return normalize(value, default_hl)
    end
  end
  -- One `{ text, hl }` pair.
  if type(content[1]) == 'string' and (content[2] == nil or type(content[2]) == 'string') then
    return { { content[1], content[2] or default_hl } }
  end
  -- A list of `{ text, hl }` pairs.
  if type(content[1]) == 'table' then
    local out = {}
    for _, entry in ipairs(content) do
      if type(entry) == 'string' then
        table.insert(out, { entry, default_hl })
      elseif type(entry) == 'table' and type(entry[1]) == 'string' then
        table.insert(out, { entry[1], entry[2] or default_hl })
      else
        append_nui_value(entry, out)
      end
    end
    return out
  end
  return { { tostring(content), default_hl } }
end

--- Width of a column's header/footer/data text.
---@param content any
---@return integer
local function content_width(content)
  return segments_width(normalize(content, nil))
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
      if col.accessor_key then
        col.id = col.accessor_key
      elseif type(col.header) == 'string' then
        col.id = col.header --[[@as string]]
      elseif type(col.header) == 'table' then
        local ok, width = pcall(content_width, col.header)
        if ok then
          col.id = tostring(width)
        end
      end
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

    if not col.align then
      col.align = 'left'
    end

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

---@generic C: table
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

    local raw = kind == 1 and column.header or column.footer
    if type(raw) == 'function' then
      raw = raw({ column = column })
    end
    local default_hl = kind == 1 and 'SqmeowHeader' or 'SqmeowHeader'
    local segments = normalize(raw == nil and '' or raw, default_hl)
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
  local column = cell.column
  if column.cell then
    return column.cell(cell)
  end
  return cell.get_value()
end

--- Create a table bound to a buffer.
---@param options { bufnr: integer, ns_id?: integer|string, columns?: sqmeow.Table.ColumnDef[], data?: table[], show_header?: boolean }
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
    show_header = options.show_header == nil and true or options.show_header,
  }, M)

  prepare_columns(self._, options.columns or {})

  return self
end

--- Replace the columns and forget computed widths.
---@param columns sqmeow.Table.ColumnDef[]
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

---@param cell table A header cell with `col_span`.
---@return integer span display width across its leaves
function M:_span_width(cell)
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
  local data_grid = {}
  local rows = self._.data
  local columns = self._.columns
  for row_idx = 1, #rows do
    local original = rows[row_idx]
    data_grid[row_idx] = {}
    local row = { id = tostring(row_idx), index = row_idx, original = original }
    for column_idx = 1, #columns do
      local column = columns[column_idx]
      local cell = {
        type = 'data',
        row = row,
        column = column,
        get_value = function()
          if column.accessor_fn then
            return column.accessor_fn(row.original, row.index)
          end
          return nil
        end,
      }
      local raw = prepare_cell_content(cell)
      if type(raw) == 'table' and raw.sql then
        raw = '= ' .. raw.sql
      end
      if type(raw) == 'string' then
        raw = raw:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
      end
      cell.content = raw
      cell.segments = normalize(raw, column.hl)
      fit_col_width(column, segments_width(cell.segments))
      data_grid[row_idx][column_idx] = cell
    end
  end
  data_grid.len = #rows

  if self._.has_footer then
    prepare_header_grid(-1, self._.headers, header_grid, self._.headers.depth)
  end

  return data_grid, header_grid
end

---@class sqmeow.Table.BuiltLine
---@field text string
---@field hls { [1]: integer, [2]: integer, [3]: string }[] byte ranges with highlight

---@param built sqmeow.Table.BuiltLine
---@param segments sqmeow.TableSegment[]
---@param width integer
---@param align sqmeow.TableAlign
---@return integer display width appended
function M:_append_padded(built, segments, width, align)
  local marks = glyphs()
  local fitted = {}
  for i, segment in ipairs(segments) do
    fitted[i] = { segment[1], segment[2] }
  end
  local room = width - segments_width(fitted)
  if room < 0 and #fitted > 0 then
    local last = fitted[#fitted]
    last[1] = truncate(last[1], strwidth(last[1]) + room, marks.ellipsis)
    room = width - segments_width(fitted)
  end
  room = math.max(room, 0)

  local left, right = 0, 0
  if align == 'right' then
    left = room
  elseif align == 'center' then
    left = math.floor(room / 2)
    right = room - left
  else
    right = room
  end

  local function push(text, hl)
    if text == '' then
      return
    end
    local from = #built.text
    built.text = built.text .. text
    if hl then
      table.insert(built.hls, { from, #built.text, hl })
    end
  end

  if left > 0 then
    push((' '):rep(left))
  end
  for _, segment in ipairs(fitted) do
    push(segment[1], segment[2])
  end
  if right > 0 then
    push((' '):rep(right))
  end
  return width
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

---@return sqmeow.Table.BuiltLine
function M:_new_line()
  return { text = '', hls = {} }
end

---@param row_cells table[] Cells on one visual line, each with `column`.
---@param get_segments fun(cell: table): sqmeow.TableSegment[]
---@param get_width fun(cell: table): integer
---@return sqmeow.Table.BuiltLine built
---@return integer[] displays Display offset after each cell, for ranges.
function M:_build_cells_line(row_cells, get_segments, get_width)
  local marks = glyphs()
  local built = self:_new_line()
  self:_append(built, ' ')
  local displays, at = {}, 1
  for index, cell in ipairs(row_cells) do
    if index > 1 then
      self:_append(built, ' ')
      self:_append(built, marks.vertical, 'SqmeowRule')
      self:_append(built, ' ')
      at = at + self:_separator_width()
    end
    local width = get_width(cell)
    local start = at
    if cell.ridx == nil or cell.ridx == cell.row_span then
      self:_append_padded(built, get_segments(cell), width, cell.column.align or 'left')
    else
      self:_append_padded(built, {}, width, 'left')
    end
    at = start + width
    displays[index] = at
  end
  return built, displays
end

---@param leaves sqmeow.Table.ColumnDef[]
---@return sqmeow.Table.BuiltLine
function M:_build_rule(leaves)
  local marks = glyphs()
  local built = self:_new_line()
  local joint = marks.horizontal .. marks.cross .. marks.horizontal
  local text = marks.horizontal
  for index, column in ipairs(leaves) do
    if index > 1 then
      text = text .. joint
    end
    text = text .. marks.horizontal:rep(column.width)
  end
  self:_append(built, text, 'SqmeowRule')
  return built
end

--- Draw the table into its buffer.
---@param linenr_start? integer First buffer line, 1-based.
function M:render(linenr_start)
  if #self._.columns == 0 then
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

  local function push_navigable(built, cells)
    table.insert(built_lines, built)
    local lnum = linenr_start + #built_lines - 1
    local at = 1
    for _, cell in ipairs(cells) do
      local width = cell.column.columns and self:_span_width(cell) or cell.column.width
      cell.range = { lnum, at, lnum, at + width }
      at = cell.range[4] + self:_separator_width()
    end
    self._.line_cells[lnum] = cells
    table.insert(self._.nav_linenrs, lnum)
  end

  if header_grid.len > 0 then
    for row_idx = 1, header_grid.len do
      local row = header_grid[row_idx]
      if not row then
        break
      end
      local cells = {}
      for i = 1, row.len do
        cells[i] = row[i]
      end
      local built = self:_build_cells_line(cells, function(cell)
        return cell.segments
      end, function(cell)
        return self:_span_width(cell)
      end)
      push_navigable(built, cells)
    end
    table.insert(built_lines, self:_build_rule(leaves))
  end

  for row_idx = 1, data_grid.len do
    local row = data_grid[row_idx]
    local cells = {}
    for i = 1, #leaves do
      cells[i] = row[i]
    end
    local built = self:_build_cells_line(cells, function(cell)
      return cell.segments
    end, function(cell)
      return cell.column.width
    end)
    push_navigable(built, cells)
  end

  if header_grid[-1] then
    table.insert(built_lines, self:_build_rule(leaves))
    for row_idx = -header_grid.len, -1 do
      local row = header_grid[row_idx]
      if row then
        local cells = {}
        for i = 1, row.len do
          cells[i] = row[i]
        end
        local built = self:_build_cells_line(cells, function(cell)
          return cell.segments
        end, function(cell)
          return self:_span_width(cell)
        end)
        push_navigable(built, cells)
      end
    end
  end

  local width = 0
  for _, built in ipairs(built_lines) do
    width = math.max(width, strwidth(built.text))
  end
  self._.size = { width = width, height = #built_lines }

  local texts = {}
  for i, built in ipairs(built_lines) do
    texts[i] = built.text
  end

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)

  if prev_first and linenr_start < prev_first then
    vim.api.nvim_buf_set_lines(self.bufnr, linenr_start - 1, prev_first - 1, false, {})
  end

  if prev_first then
    vim.api.nvim_buf_set_lines(self.bufnr, linenr_start - 1, prev_last, false, texts)
  else
    if vim.api.nvim_buf_line_count(self.bufnr) == 1 then
      local first = vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1]
      if first == '' then
        vim.api.nvim_buf_set_lines(self.bufnr, 0, 1, false, texts)
      else
        vim.api.nvim_buf_set_lines(self.bufnr, linenr_start - 1, linenr_start - 1, false, texts)
      end
    else
      vim.api.nvim_buf_set_lines(self.bufnr, linenr_start - 1, linenr_start - 1, false, texts)
    end
  end

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

--- Byte offset of a display column on a line.
---@param line string
---@param display integer
---@return integer bytes
function M.byte_at(line, display)
  local at, bytes = 0, 0
  for char in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    if at >= display then
      break
    end
    at = at + strwidth(char)
    bytes = bytes + #char
  end
  return bytes
end

--- Display column of a byte offset on a line.
---@param line string
---@param bytes integer 0-based byte column.
---@return integer display
function M.display_at(line, bytes)
  local prefix = line:sub(1, bytes)
  return vim.fn.strdisplaywidth(prefix)
end

--- The cell on `line` whose display range holds `display`.
--- On a separator, bias to the cell on the right.
---@param cells table[]
---@param display integer
---@return table|nil
local function resolve_cell_at(cells, display)
  for i = 1, #cells do
    local range = cells[i].range
    if range and range[2] < display and display <= range[4] then
      return cells[i]
    end
  end
  for i = 1, #cells do
    local range = cells[i].range
    if range and range[2] >= display then
      return cells[i]
    end
  end
  return nil
end

--- Find a window showing this table's buffer.
---@param win integer|nil
---@return integer|nil
function M:_win(win)
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == self.bufnr then
    return win
  end
  if win then
    return nil
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
  if not cells then
    return nil
  end
  local cell = resolve_cell_at(cells, display)
  if not cell then
    return nil
  end

  local target_display
  if col_delta ~= 0 then
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
    target_display = cell.range[2] + 1
  elseif row_delta ~= 0 then
    target_display = display
  else
    target_display = cell.range[2] + 1
  end

  return cell, target_line, target_display
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
  local cursor = vim.api.nvim_win_get_cursor(win)
  local text = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
  local display = M.display_at(text, cursor[2])
  local cell = self:_resolve_cell(cursor[1], display, position)
  return cell
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
  local cursor = vim.api.nvim_win_get_cursor(win)
  local text = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
  local display = M.display_at(text, cursor[2])
  local cell, target_line, target_display = self:_resolve_cell(cursor[1], display, position)
  if not (cell and target_line and target_display) then
    return nil
  end
  local target_text = vim.api.nvim_buf_get_lines(self.bufnr, target_line - 1, target_line, false)[1]
    or ''
  local byte = M.byte_at(target_text, target_display)
  vim.api.nvim_win_set_cursor(win, { target_line, byte })
  return cell
end

--- Put the cursor on a leaf column, keeping its line.
---@param index integer One-based leaf column.
---@param win? integer Window showing the table.
---@return boolean moved
function M:goto_column(index, win)
  win = self:_win(win)
  if not (win and self._.columns[index]) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local cells = self._.line_cells[cursor[1]]
  if not cells then
    return false
  end
  local wanted = self._.columns[index].id
  for _, cell in ipairs(cells) do
    local column = cell.column
    local id = column.id
    if column.columns then
      -- A group line: jump to the group holding the leaf.
      local leaves = {}
      local function collect(col)
        if col.columns then
          for _, child in ipairs(col.columns) do
            collect(child)
          end
        else
          leaves[col.id] = true
        end
      end
      collect(column)
      if leaves[wanted] then
        id = wanted
      end
    end
    if id == wanted or column == self._.columns[index] then
      local text = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
      vim.api.nvim_win_set_cursor(win, { cursor[1], M.byte_at(text, cell.range[2] + 1) })
      return true
    end
  end
  return false
end

--- Redraw one data cell in place when its width still fits.
--- Falls back to a full render when the column must grow.
---@param cell sqmeow.Table.Cell
function M:refresh_cell(cell)
  assert(cell and cell.range, 'sqmeow: refresh_cell needs a rendered cell')
  local column = cell.column
  local raw = prepare_cell_content(cell)
  cell.content = raw
  cell.segments = normalize(raw, column.hl)

  local needed = segments_width(cell.segments)
  if needed > column.width and not column._fixed_width then
    local capped = column.max_width and column.width >= column.max_width
    if not capped then
      self:render()
      return
    end
  end

  local lnum = cell.range[1]
  local cells = self._.line_cells[lnum]
  if not cells then
    return
  end
  local built = self:_build_cells_line(cells, function(entry)
    return entry == cell and cell.segments or (entry.segments or {})
  end, function(entry)
    if entry.column.columns then
      return self:_span_width(entry)
    end
    return entry.column.width
  end)

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
