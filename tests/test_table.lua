local MiniTest = require('mini.test')
-- The project's own table grid: sqmeow style, Nui-inspired structure.
local eq = MiniTest.expect.equality
local Table = require('sqmeow.ui.table')

local T = MiniTest.new_set()

--- A scratch buffer holding nothing, gone when the case ends.
---@return integer
local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = true
  MiniTest.finally(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
  return buf
end

local function first(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
end

T['flat table'] = MiniTest.new_set({
  hooks = {
    pre_case = function() end,
  },
})

T['flat table']['draws header, rule and right-aligned rows'] = function()
  local buf = scratch()
  local table_ = Table.new({
    bufnr = buf,
    ns_id = 'sqmeow.test.table.flat',
    columns = {
      {
        id = 'id',
        header = 'id',
        align = 'right',
        accessor_fn = function(row)
          return row[1]
        end,
      },
      {
        id = 'name',
        header = 'name',
        accessor_fn = function(row)
          return row[2]
        end,
      },
    },
    data = { { 1, 'alice' }, { 22, 'bo' } },
  })
  table_:render(1)

  local held = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#held, 4)
  eq(held[1], ' id │ name ')
  eq(held[2], '────┼──────')
  eq(held[3], '  1 │ alice')
  eq(table_:get_size(), { width = 11, height = 4 })
end

T['flat table']['keeps no box-drawing borders'] = function()
  local buf = scratch()
  local table_ = Table.new({
    bufnr = buf,
    ns_id = 'sqmeow.test.table.nobox',
    columns = {
      {
        id = 'a',
        header = 'a',
        accessor_fn = function(row)
          return row[1]
        end,
      },
    },
    data = { { 'x' } },
  })
  table_:render(1)
  eq(first(buf):find('┌', 1, true), nil)
  eq(first(buf):find('┬', 1, true), nil)
end

T['movement'] = MiniTest.new_set()

T['movement']['walks the continuous header/data grid'] = function()
  local buf = scratch()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  MiniTest.finally(function()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  end)
  local table_ = Table.new({
    bufnr = buf,
    ns_id = 'sqmeow.test.table.move',
    columns = {
      {
        id = 'a',
        header = 'a',
        accessor_fn = function(row)
          return row[1]
        end,
      },
      {
        id = 'b',
        header = 'b',
        accessor_fn = function(row)
          return row[2]
        end,
      },
    },
    data = { { 'x', 'y' }, { 'p', 'q' } },
  })
  table_:render(1)

  vim.api.nvim_win_set_cursor(win, { 1, 1 })
  local header = table_:get_cell(nil, win)
  eq(header.type, 'header')
  eq(header.column.id, 'a')

  local right = table_:goto_cell({ 0, 1 }, win)
  eq(right.column.id, 'b')

  local down = table_:goto_cell({ 1, 0 }, win)
  eq(down.type, 'data')
  eq(down.column.id, 'b')

  eq(table_:goto_cell({ 9, 0 }, win), nil)
end

T['movement']['goto_column keeps the line'] = function()
  local buf = scratch()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  MiniTest.finally(function()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  end)
  local table_ = Table.new({
    bufnr = buf,
    ns_id = 'sqmeow.test.table.column',
    columns = {
      {
        id = 'a',
        header = 'a',
        accessor_fn = function(row)
          return row[1]
        end,
      },
      {
        id = 'b',
        header = 'b',
        accessor_fn = function(row)
          return row[2]
        end,
      },
    },
    data = { { 'x', 'y' } },
  })
  table_:render(1)

  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  eq(table_:goto_column(2, win), true)
  eq(vim.api.nvim_win_get_cursor(win)[1], 3)
  eq((table_:get_cell(nil, win) or {}).column.id, 'b')
end

T['structure'] = MiniTest.new_set()

T['structure']['spans group headers and shrinks with the data'] = function()
  local buf = scratch()
  local table_ = Table.new({
    bufnr = buf,
    ns_id = 'sqmeow.test.table.nested',
    columns = {
      {
        id = 'g',
        header = 'g',
        columns = {
          {
            id = 'x',
            header = 'x',
            accessor_fn = function(row)
              return row[1]
            end,
          },
          {
            id = 'y',
            header = 'y',
            accessor_fn = function(row)
              return row[2]
            end,
          },
        },
      },
    },
    data = { { 'longvalue', 's' } },
  })
  table_:render(1)
  eq(#vim.api.nvim_buf_get_lines(buf, 0, -1, false), 4)

  local wide = table_:get_size().width
  table_:set_data({ { 'a', 'b' } }):render()
  eq(table_:get_size().width < wide, true)
end

T['structure']['fixed widths truncate and refresh_cell patches'] = function()
  local buf = scratch()
  local rows = { { 'abcdef' } }
  local table_ = Table.new({
    bufnr = buf,
    ns_id = 'sqmeow.test.table.fixed',
    columns = {
      {
        id = 'c',
        header = 'c',
        width = 3,
        accessor_fn = function(row)
          return row[1]
        end,
      },
    },
    data = rows,
  })
  table_:render(1)
  eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1], ' ab…')

  rows[1][1] = 'xy'
  table_:refresh_cell(table_._.line_cells[3][1])
  eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1], ' xy ')
end

return T
