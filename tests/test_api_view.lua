---@diagnostic disable: duplicate-set-field
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

--- Answer engine requests from `replies[method](args)` through the schema collector's events.
local function stub_engine(replies)
  local rpc = require('sqmeow.rpc.client')
  local collector = require('sqmeow.core.schema')
  local deliver = {
    structure = collector.on_structure,
    relationships = collector.on_relationships,
    introspect = collector.on_nodes,
  }
  local original = rpc.request
  local sent = {}
  rpc.request = function(method, args)
    if not replies[method] then
      return original(method, args)
    end
    table.insert(sent, method)
    vim.schedule(function()
      deliver[method](replies[method](args))
    end)
    return true
  end
  return sent, function()
    rpc.request = original
  end
end

local function structure(args, columns, foreign_keys)
  return {
    conn_id = args.conn_id,
    schema = args.schema,
    relation = args.relation,
    columns = columns,
    indexes = {},
    foreign_keys = foreign_keys or {},
  }
end

local function connect()
  state.add_connection({
    id = 1,
    name = 'app',
    url = 'postgres://localhost/app',
    dialect = 'postgres',
    state = 'connected',
  })
end

local function collect(opts)
  local got, got_err
  local started, err = view.schema(opts, function(schema, e)
    got, got_err = schema, e
  end)
  eq({ started, err }, { true, nil })
  vim.wait(500, function()
    return got ~= nil or got_err ~= nil
  end)
  return got, got_err
end

T['schema reads a table neighborhood over relationships and structure'] = function()
  connect()
  local sent, restore = stub_engine({
    relationships = function(args)
      return {
        conn_id = args.conn_id,
        request_id = args.request_id,
        resolved_schema = 'public',
        resolved_relation = args.relation,
        relationships = {
          {
            name = 'orders_user_id_fkey',
            source_schema = 'public',
            source_relation = 'orders',
            columns = { 'user_id' },
            target_schema = 'public',
            target_relation = 'users',
            referenced = { 'id' },
          },
        },
      }
    end,
    structure = function(args)
      return structure(args, { { name = 'id', type_name = 'int4', primary_key = true } })
    end,
  })
  local schema, err = collect({ conn_id = 1, relation = 'orders' })
  restore()

  eq(err, nil)
  schema = assert(schema, 'schema is nil')
  eq(schema.schema, 'public')
  eq(schema.relation, 'orders')
  eq(schema.hops, 1)
  eq(
    vim.tbl_map(function(t)
      return t.schema .. '.' .. t.relation
    end, schema.tables),
    { 'public.orders', 'public.users' }
  )
  eq(sent, { 'relationships', 'structure', 'structure' })
end

T['schema reads every table of the default schema'] = function()
  connect()
  local _, restore = stub_engine({
    introspect = function(args)
      local nodes = #args.path == 0
          and {
            { kind = 'schema', name = 'audit' },
            { kind = 'schema', name = 'public', is_default = true },
          }
        or { { kind = 'table', name = 'users' }, { kind = 'view', name = 'active_users' } }
      return { conn_id = args.conn_id, path = args.path, nodes = nodes }
    end,
    structure = function(args)
      return structure(args, {})
    end,
  })
  local schema, err = collect({ conn_id = 1 })
  restore()

  eq(err, nil)
  schema = assert(schema, 'schema is nil')
  eq(schema.schema, 'public')
  eq(#schema.tables, 1)
  eq(schema.tables[1].relation, 'users')
end

T['schema reports the first structure error'] = function()
  connect()
  local _, restore = stub_engine({
    introspect = function(args)
      return { conn_id = args.conn_id, path = args.path, nodes = { { kind = 'table', name = 't' } } }
    end,
    structure = function(args)
      return vim.tbl_extend('force', args, { error = 'permission denied' })
    end,
  })
  local schema, err = collect({ conn_id = 1, schema = 'public' })
  restore()

  eq(schema, nil)
  eq(err, 'permission denied')
end

T['schema fails pending requests when the connection closes'] = function()
  connect()
  local rpc = require('sqmeow.rpc.client')
  local original = rpc.request
  rpc.request = function()
    return true
  end
  local got_err
  view.schema({ conn_id = 1, schema = 'public' }, function(_, err)
    got_err = err
  end)
  rpc.request = original
  require('sqmeow.core.schema').invalidate(1)
  eq(got_err, 'connection closed')
end

T['schema rejects disconnected and non-relational connections'] = function()
  eq(
    { view.schema({ schema = 'public' }, function() end) },
    { false, 'connect to a database first' }
  )

  connect()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].sqmeow_connection = 'closed_conn'
  eq({ view.schema({}, function() end) }, { false, '`closed_conn` is not open' })

  state.add_connection({
    id = 2,
    name = 'cache',
    url = 'redis://localhost:6379/0',
    dialect = 'redis',
    state = 'connected',
  })
  eq({ view.schema({ conn_id = 2 }, function() end) }, { false, 'redis has no relational schema' })
end

return T
