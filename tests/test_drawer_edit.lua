local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.helpers')
local drawer = require('sqmeow.ui.drawer')
local state = require('sqmeow.core.state')

local T = MiniTest.new_set()

T['edit table in drawer'] = MiniTest.new_set()

T['edit table in drawer']['opens editor with ALTER TABLE template'] = function()
  state.connections[1] = {
    id = 1,
    name = 'dev',
    dialect = 'postgres',
    url = 'postgres://localhost/dev',
    state = 'connected',
  }

  local table_node = {
    kind = 'table',
    name = 'users',
    conn_id = 1,
    path = { 'public', 'tables', 'users' },
  }

  helpers.stub(drawer, 'current_node', function()
    return table_node
  end)

  helpers.stub(drawer, 'cached_nodes', function(conn_id, path)
    if conn_id == 1 and path[3] == 'users' then
      return {
        { name = 'id', type_name = 'integer', primary_key = true },
        { name = 'email', type_name = 'text', nullable = false },
      }
    end
    return nil
  end)

  drawer.actions.edit()

  local cur_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  eq(vim.bo[cur_buf].filetype, 'sql')
  eq(vim.bo[cur_buf].buftype, 'nofile')
  eq(vim.b[cur_buf].sqmeow_connection, 'dev')
  assert(content:find('-- Current columns:'))
  assert(content:find('id %(integer, primary key%)'))
  assert(content:find('email %(text, not null%)'))
  assert(content:find('ALTER TABLE "public"."users"'))
  assert(content:find('ADD COLUMN new_column text;'))

  -- Clean up
  vim.api.nvim_buf_delete(cur_buf, { force = true })
end

T['edit table in drawer']['handles dialect specific filetypes and syntax'] = function()
  state.connections[2] = {
    id = 2,
    name = 'surreal_db',
    dialect = 'surrealdb',
    url = 'surrealdb://localhost',
    state = 'connected',
  }

  local table_node = {
    kind = 'table',
    name = 'person',
    conn_id = 2,
    path = { 'main', 'tables', 'person' },
  }

  helpers.stub(drawer, 'current_node', function()
    return table_node
  end)

  drawer.actions.edit()

  local cur_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  eq(vim.bo[cur_buf].filetype, 'surql')
  eq(vim.bo[cur_buf].buftype, 'nofile')
  eq(vim.b[cur_buf].sqmeow_connection, 'surreal_db')
  assert(content:find('DEFINE FIELD new_column ON TABLE `person` TYPE string;'))

  -- Clean up
  vim.api.nvim_buf_delete(cur_buf, { force = true })
end

return T
