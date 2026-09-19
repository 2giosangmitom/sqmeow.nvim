local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local Table = require('sqmeow.ui.table')

local T = MiniTest.new_set()

--- A column reading one field of a list-shaped row.
---@param id string
---@param at integer
---@param extra table|nil
---@return table
local function column(id, at, extra)
  return vim.tbl_extend('force', {
    id = id,
    header = id,
    accessor_fn = function(row)
      return row[at]
    end,
  }, extra or {})
end

--- A table drawn into a scratch buffer, gone when the case ends.
---@param options table
---@return table table_
---@return integer buf
local function build(options)
  local buf = helpers.temp_buf()
  local table_ =
    Table.new(vim.tbl_extend('force', { bufnr = buf, ns_id = 'sqmeow.test.table' }, options))
  return table_, buf
end

--- Show `buf` in the current window for the rest of the case.
---@param buf integer
---@return integer win
local function showing(buf)
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  MiniTest.finally(function()
    if vim.api.nvim_win_is_valid(win) then
      local back = vim.api.nvim_buf_is_valid(previous) and previous
        or vim.api.nvim_create_buf(false, true)
      pcall(vim.api.nvim_win_set_buf, win, back)
    end
  end)
  return win
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

T['drawing'] = MiniTest.new_set()

T['drawing']['writes a header, a rule and the rows'] = function()
  local table_, buf = build({
    columns = { column('id', 1, { align = 'right' }), column('name', 2) },
    data = { { 1, 'alice' }, { 22, 'bo' } },
  })
  table_:render(1)

  eq(
    lines(buf),
    { ' id │ name ', '────┼──────', '  1 │ alice', ' 22 │ bo   ' }
  )
  eq(table_:get_size(), { width = 11, height = 4 })
  eq(table_:range(), 1)
  eq(select(2, table_:range()), 4)
end

T['drawing']['draws no box border'] = function()
  local table_, buf = build({ columns = { column('a', 1) }, data = { { 'x' } } })
  table_:render(1)
  for _, line in ipairs(lines(buf)) do
    for _, corner in ipairs({ '┌', '┬', '┐', '└', '┴', '┘', '├', '┤' }) do
      eq(line:find(corner, 1, true), nil)
    end
  end
end

T['drawing']['centres, right-aligns and pads to the column width'] = function()
  local table_, buf = build({
    columns = {
      column('left', 1),
      column('middle', 2, { align = 'center' }),
      column('right', 3, { align = 'right' }),
    },
    data = { { 'x', 'y', 'z' } },
  })
  table_:render(1)

  eq(lines(buf)[3], ' x    │   y    │     z')
end

T['drawing']['cuts content to a fixed width, marker included'] = function()
  local table_, buf = build({
    columns = { column('c', 1, { width = 3 }), column('d', 2) },
    data = { { 'abcdef', 'tail' } },
  })
  table_:render(1)

  eq(lines(buf)[3], ' ab… │ tail')
end

T['drawing']['cuts a multi-part cell without overflowing its column'] = function()
  local table_, buf = build({
    columns = {
      {
        id = 'c',
        header = { { '󰀬', 'SqmeowIcon' }, { ' ' }, { 'name', 'SqmeowHeader' } },
        width = 4,
        accessor_fn = function(row)
          return row[1]
        end,
      },
    },
    data = { { 'x' } },
  })
  table_:render(1)

  eq(vim.api.nvim_strwidth(lines(buf)[1]), 5)
  eq(vim.api.nvim_strwidth(lines(buf)[2]), 5)
end

T['drawing']['escapes what a buffer line cannot hold'] = function()
  local table_, buf = build({
    columns = { column('a', 1) },
    data = { { 'one\ttwo\nthree' } },
  })
  table_:render(1)

  eq(lines(buf)[3], ' one\\ttwo\\nthree')
end

T['drawing']['highlights the rule, the header and the column default'] = function()
  local table_, buf = build({
    columns = { column('a', 1, { hl = 'SqmeowNumber' }) },
    data = { { 'x' } },
  })
  table_:render(1)

  eq(
    helpers.marks_on(buf, 'sqmeow.test.table', 1),
    { { group = 'SqmeowHeader', from = 1, to = 2 } }
  )
  eq(helpers.marks_on(buf, 'sqmeow.test.table', 2), { { group = 'SqmeowRule', from = 0, to = 6 } })
  eq(
    helpers.marks_on(buf, 'sqmeow.test.table', 3),
    { { group = 'SqmeowNumber', from = 1, to = 2 } }
  )
end

T['drawing']['trims the trailing padding when asked'] = function()
  local table_, buf = build({
    columns = { column('a', 1), column('b', 2) },
    data = { { 'x', 'y' } },
    trim = true,
  })
  table_:render(1)

  eq(lines(buf)[1], ' a │ b')
  eq(lines(buf)[3], ' x │ y')
end

T['drawing']['leaves the header out when it is turned off'] = function()
  local table_, buf = build({
    columns = { column('a', 1) },
    data = { { 'x' } },
    show_header = false,
  })
  table_:render(1)

  eq(lines(buf), { ' x' })
end

T['drawing']['draws a footer under its own rule'] = function()
  local table_, buf = build({
    columns = { column('a', 1, { footer = 'sum' }) },
    data = { { 'x' } },
  })
  table_:render(1)

  eq(lines(buf), { ' a  ', '────', ' x  ', '────', ' sum' })
end

T['drawing']['keeps a footer-only column off the header line'] = function()
  local table_, buf = build({
    columns = {
      {
        id = 'a',
        footer = 'sum',
        accessor_fn = function(row)
          return row[1]
        end,
      },
    },
    data = { { 'x' } },
  })
  table_:render(1)

  eq(lines(buf), { ' x  ', '────', ' sum' })
end

T['drawing']['spans a group header over its children'] = function()
  local table_, buf = build({
    columns = {
      { id = 'g', header = 'g', columns = { column('x', 1), column('y', 2) } },
    },
    data = { { 'longvalue', 's' } },
  })
  table_:render(1)

  local held = lines(buf)
  eq(#held, 4)
  eq(held[1], ' g            ')
  eq(held[2], ' x         │ y')
  eq(held[4], ' longvalue │ s')
end

T['drawing']['shrinks back when the data gets shorter'] = function()
  local table_ = build({
    columns = { column('a', 1) },
    data = { { 'longvalue' } },
  })
  table_:render(1)
  local wide = table_:get_size().width

  table_:set_data({ { 'a' } }):render()
  eq(table_:get_size().width < wide, true)
end

T['drawing']['redraws in place, leaving nothing of the last render'] = function()
  local table_, buf = build({ columns = { column('a', 1) }, data = { { 'x' }, { 'y' } } })
  table_:render(1)
  table_:set_data({ { 'z' } }):render()

  eq(lines(buf), { ' a', '──', ' z' })
end

T['drawing']['keeps the lines above a later start'] = function()
  local table_, buf = build({ columns = { column('a', 1) }, data = { { 'x' } } })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'note', '' })
  table_:render(3)

  eq(lines(buf), { 'note', '', ' a', '──', ' x' })
  eq(table_:range(), 3)
end

T['drawing']['draws into another buffer after set_buffer'] = function()
  local table_ = build({ columns = { column('a', 1) }, data = { { 'x' } } })
  table_:render(1)

  local other = helpers.temp_buf()
  table_:set_buffer(other):render(1)
  eq(lines(other), { ' a', '──', ' x' })
end

T['columns'] = MiniTest.new_set()

T['columns']['reads a row by its accessor key'] = function()
  local table_, buf = build({
    columns = { { accessor_key = 'name' } },
    data = { { name = 'alice' } },
  })
  table_:render(1)

  eq(table_:leaf_columns()[1].id, 'name')
  -- No header was given, so none is drawn.
  eq(lines(buf), { ' alice' })
end

T['columns']['refuses a column it cannot name'] = function()
  MiniTest.expect.error(function()
    build({ columns = { { header = { { 'a', 'SqmeowHeader' } } } } })
  end, 'missing an id')
end

T['columns']['replaces the columns and their widths'] = function()
  local table_, buf = build({ columns = { column('a', 1) }, data = { { 'longvalue' } } })
  table_:render(1)

  table_:set_columns({ column('b', 2) }):set_data({ { 'longvalue', 'z' } })
  table_:render(1)
  eq(lines(buf), { ' b', '──', ' z' })
end

T['movement'] = MiniTest.new_set()

T['movement']['walks the continuous header and data grid'] = function()
  local table_, buf = build({
    columns = { column('a', 1), column('b', 2) },
    data = { { 'x', 'y' }, { 'p', 'q' } },
  })
  local win = showing(buf)
  table_:render(1)

  vim.api.nvim_win_set_cursor(win, { 1, 1 })
  local header = table_:get_cell(nil, win)
  eq(header.type, 'header')
  eq(header.column.id, 'a')

  eq(table_:goto_cell({ 0, 1 }, win).column.id, 'b')
  local down = table_:goto_cell({ 1, 0 }, win)
  eq(down.type, 'data')
  eq(down.column.id, 'b')

  eq(table_:goto_cell({ 9, 0 }, win), nil)
  eq(table_:goto_cell({ 0, 1 }, win), nil)
end

T['movement']['lands on the first character of a cell'] = function()
  local table_, buf = build({
    columns = { column('a', 1), column('b', 2) },
    data = { { 'x', 'y' } },
  })
  local win = showing(buf)
  table_:render(1)

  -- ' x │ y': the cells start at byte 1 and byte 7, the `│` being three bytes.
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  table_:goto_cell({ 0, 1 }, win)
  eq(vim.api.nvim_win_get_cursor(win), { 3, 7 })

  table_:goto_cell({ 0, -1 }, win)
  eq(vim.api.nvim_win_get_cursor(win), { 3, 1 })
end

T['movement']['answers with nothing off the grid'] = function()
  local table_, buf = build({ columns = { column('a', 1) }, data = { { 'x' } } })
  local win = showing(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'note' })
  table_:render(2)

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  eq(table_:get_cell(nil, win), nil)
end

T['movement']['goto_column keeps the line'] = function()
  local table_, buf = build({
    columns = { column('a', 1), column('b', 2) },
    data = { { 'x', 'y' } },
  })
  local win = showing(buf)
  table_:render(1)

  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  eq(table_:goto_column(2, win), true)
  eq(vim.api.nvim_win_get_cursor(win)[1], 3)
  eq(table_:get_cell(nil, win).column.id, 'b')

  eq(table_:goto_column(7, win), false)
end

T['movement']['goto_column lands on the group a leaf sits under'] = function()
  local table_, buf = build({
    columns = {
      column('a', 1),
      { id = 'g', header = 'g', columns = { column('x', 2), column('y', 3) } },
    },
    data = { { 'p', 'q', 'r' } },
  })
  local win = showing(buf)
  table_:render(1)

  -- The group line, where the leaf `y` is only reachable through `g`.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  eq(table_:goto_column(3, win), true)
  eq(table_:get_cell(nil, win).column.id, 'g')
end

T['refresh_cell'] = MiniTest.new_set()

T['refresh_cell']['redraws one line when the width still holds'] = function()
  local rows = { { 'abcdef' }, { 'zz' } }
  local table_, buf = build({
    columns = { column('c', 1, { width = 3 }) },
    data = rows,
  })
  table_:render(1)
  eq(lines(buf)[3], ' ab…')

  rows[1][1] = 'xy'
  table_:refresh_cell(table_._.line_cells[3][1])
  eq(lines(buf), { ' c  ', '────', ' xy ', ' zz ' })
end

T['refresh_cell']['redraws the table when the column has to grow'] = function()
  local rows = { { 'x' } }
  local table_, buf = build({ columns = { column('c', 1) }, data = rows })
  table_:render(1)

  rows[1][1] = 'much longer'
  table_:refresh_cell(table_._.line_cells[3][1])
  eq(lines(buf), { ' c          ', '────────────', ' much longer' })
end

return T
