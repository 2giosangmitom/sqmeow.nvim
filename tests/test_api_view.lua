local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local config = require('sqmeow.config')
local edit = require('sqmeow.ui.edit')
local result = require('sqmeow.ui.result')
local state = require('sqmeow.core.state')
local view = require('sqmeow.api.view')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      pcall(result.close)
      result.forget()
      edit.reset()
      state.reset()
      config.apply({})
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and buf ~= vim.api.nvim_get_current_buf() then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end,
  },
})

T['status is nil outside database buffers'] = function()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].filetype = 'lua'
  eq(view.status(buf), nil)
  eq(view.column(), '')
end

T['status reports connection and query telemetry for SQL editor buffers'] = function()
  state.add_connection({
    id = 1,
    name = 'analytics',
    url = 'postgres://localhost/analytics',
    dialect = 'postgres',
    state = 'connected',
    read_only = true,
  })
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].filetype = 'sql'
  vim.b[buf].sqmeow_connection = 'analytics'

  local info = assert(view.status(buf), 'status is nil')
  eq(info.connection, 'analytics')
  eq(info.dialect, 'postgres')
  eq(info.read_only, true)
  eq(info.role, 'query')
  eq(info.staged_changes, 0)
  eq(info.filtered, false)
  eq(info.state, nil)

  state.call = {
    call_id = 10,
    conn_id = 1,
    state = 'executing',
  }
  eq(assert(view.status(buf), 'status is nil').state, 'executing')

  state.call = {
    call_id = 10,
    conn_id = 1,
    state = 'error',
    error = 'syntax error at or near "form"',
  }
  eq(assert(view.status(buf), 'status is nil').error, 'syntax error at or near "form"')

  state.call = {
    call_id = 10,
    conn_id = 1,
    state = 'done',
    rows = 142,
    elapsed_ms = 12,
    columns = {
      { name = 'id', type_name = 'int4', class = 'number', nulls = false, numeric = true },
    },
  }
  info = assert(view.status(buf), 'status is nil')
  eq(info.state, 'done')
  eq(info.rows, 142)
  eq(info.view_rows, nil)
  eq(info.elapsed_ms, 12)
  eq(info.elapsed, '12ms')
  eq(info.page, 1)
  eq(info.total_pages, 2)
  eq(info.truncated, false)
  eq(info.error, nil)

  -- A buffer bound to a different connection does not show another connection's call telemetry.
  local other = vim.api.nvim_create_buf(true, true)
  vim.bo[other].filetype = 'sql'
  vim.b[other].sqmeow_connection = 'staging'
  info = assert(view.status(other), 'status is nil')
  eq(info.connection, 'staging')
  eq(info.state, nil)
  eq(info.rows, nil)
end

T['status and column follow the result grid'] = function()
  state.add_connection({
    id = 1,
    name = 'dev',
    url = 'sqlite://:memory:',
    dialect = 'sqlite',
    state = 'connected',
  })
  local win = result.open()
  vim.api.nvim_set_current_win(win)

  state.call = {
    call_id = 1,
    conn_id = 1,
    state = 'done',
    rows = 10,
    view_rows = 4,
    elapsed_ms = 5,
    columns = {
      { name = 'user_id', type_name = 'INTEGER', class = 'number', nulls = false, numeric = true },
      { name = 'email', type_name = 'TEXT', class = 'text', nulls = true, numeric = false },
    },
  }
  result.spec().where = 'user_id > 2'
  result.redraw()
  vim.api.nvim_win_set_cursor(win, { 1, 2 })

  eq(view.column(), '󰠵 user_id (integer)')
  local info = assert(view.status(), 'status is nil')
  eq(info.role, 'result')
  eq(info.connection, 'dev')
  eq(info.rows, 10)
  eq(info.view_rows, 4)
  eq(info.filtered, true)
  eq(info.staged_changes, 0)
  local column = assert(info.column, 'column is nil')
  eq(column.index, 1)
  eq(column.total, 2)
  eq(column.name, 'user_id')
  eq(column.type_name, 'INTEGER')

  result.goto_column(2)
  eq(view.column(), '󰠵 email (text)')
  eq(assert(assert(view.status(), 'status is nil').column, 'column is nil').index, 2)

  edit.set({ row = 0 }, 1, 'new@example.com')
  eq(assert(view.status(), 'status is nil').staged_changes, 1)
end

return T
