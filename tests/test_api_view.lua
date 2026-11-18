---@diagnostic disable: duplicate-set-field
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local config = require('sqmeow.config')
local helpers = require('tests.helpers')
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
--- The stub is removed when the case ends, even when it fails.
---@return string[] sent Methods requested, in order.
local function stub_engine(replies)
  local rpc = require('sqmeow.rpc.client')
  local collector = require('sqmeow.core.schema')
  local deliver = {
    structure = collector.on_structure,
    relationships = collector.on_relationships,
    introspect = collector.on_nodes,
  }
  local sent = {}
  helpers.stub(rpc, 'request', function(method, args)
    table.insert(sent, method)
    if replies[method] then
      vim.schedule(function()
        local payload = replies[method](args)
        payload.conn_id = payload.conn_id or args.conn_id
        payload.request_id = payload.request_id or args.request_id
        deliver[method](payload)
      end)
    end
    return true
  end)
  return sent
end

--- `public` is the default schema; `tables` lists its tables.
local function catalog(tables)
  return function(args)
    if #args.path == 0 then
      return {
        path = args.path,
        nodes = {
          { kind = 'schema', name = 'audit' },
          { kind = 'schema', name = 'public', is_default = true },
        },
      }
    end
    local nodes = { { kind = 'view', name = 'active_users' } }
    for _, name in ipairs(tables) do
      table.insert(nodes, { kind = 'table', name = name })
    end
    return { path = args.path, nodes = nodes }
  end
end

local function structure(args)
  return {
    schema = args.schema,
    relation = args.relation,
    columns = { { name = 'id', type_name = 'int4', primary_key = true } },
    indexes = {},
    foreign_keys = {},
  }
end

local function orders_relationships()
  return {
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

local function names(schema)
  return vim.tbl_map(function(t)
    return t.schema .. '.' .. t.relation
  end, schema.tables)
end

T['schema reads a table neighborhood over relationships and structure'] = function()
  connect()
  local sent = stub_engine({
    introspect = catalog({ 'orders', 'users' }),
    relationships = orders_relationships,
    structure = structure,
  })
  -- The catalog's spelling wins over the caller's.
  local schema, err = collect({ conn_id = 1, relation = 'ORDERS' })

  eq(err, nil)
  schema = assert(schema, 'schema is nil')
  eq({ schema.schema, schema.relation, schema.hops }, { 'public', 'orders', 1 })
  eq(names(schema), { 'public.orders', 'public.users' })
  eq(sent, { 'introspect', 'introspect', 'relationships', 'structure', 'structure' })
end

T['schema with zero hops reads only the focal table'] = function()
  connect()
  local sent = stub_engine({
    introspect = catalog({ 'orders', 'users' }),
    relationships = orders_relationships,
    structure = structure,
  })
  local schema = assert(collect({ conn_id = 1, relation = 'orders', hops = 0 }), 'schema is nil')

  eq(names(schema), { 'public.orders' })
  eq(schema.hops, 0)
  eq(vim.tbl_contains(sent, 'relationships'), false)
end

T['schema keeps dotted names in different schemas apart'] = function()
  connect()
  stub_engine({
    introspect = catalog({ 'root' }),
    relationships = function()
      return {
        relationships = {
          {
            source_schema = 'public',
            source_relation = 'root',
            target_schema = 'a.b',
            target_relation = 'c',
          },
          {
            source_schema = 'public',
            source_relation = 'root',
            target_schema = 'a',
            target_relation = 'b.c',
          },
        },
      }
    end,
    structure = structure,
  })
  local schema = assert(collect({ conn_id = 1, relation = 'root' }), 'schema is nil')

  eq(names(schema), { 'public.root', 'a.b.c', 'a.b.c' })
  eq(schema.tables[2].schema, 'a.b')
  eq(schema.tables[3].schema, 'a')
end

T['schema reports a table missing from the catalog'] = function()
  connect()
  local sent = stub_engine({ introspect = catalog({ 'orders' }) })
  local schema, err = collect({ conn_id = 1, relation = 'missing' })

  eq(schema, nil)
  eq(err, 'table missing not found in public')
  eq(sent, { 'introspect', 'introspect' })
end

T['schema reads every table of the default schema'] = function()
  connect()
  stub_engine({ introspect = catalog({ 'users' }), structure = structure })
  local schema, err = collect({ conn_id = 1 })

  eq(err, nil)
  schema = assert(schema, 'schema is nil')
  eq(schema.schema, 'public')
  eq(names(schema), { 'public.users' })
end

T['schema sends a server connection to its databases'] = function()
  connect()
  stub_engine({
    introspect = function(args)
      return { path = args.path, nodes = { { kind = 'database', name = 'app' } } }
    end,
  })
  local _, err = collect({ conn_id = 1 })
  eq(err, 'this connection is a server; read the schema from one of its databases')
end

T['schema reports the first structure error'] = function()
  connect()
  stub_engine({
    introspect = catalog({ 't' }),
    structure = function(args)
      return vim.tbl_extend('force', structure(args), { error = 'permission denied' })
    end,
  })
  local schema, err = collect({ conn_id = 1, schema = 'public' })

  eq(schema, nil)
  eq(err, 'permission denied')
end

T['schema ignores replies to other requests for the same table'] = function()
  connect()
  local collector = require('sqmeow.core.schema')
  local requests = {}
  helpers.stub(require('sqmeow.rpc.client'), 'request', function(method, args)
    table.insert(requests, { method = method, args = args })
    return true
  end)
  local got
  view.schema({ conn_id = 1, schema = 'public' }, function(schema)
    got = schema
  end)
  local listing = requests[1].args
  -- The drawer's own read of the same path carries no id of this request.
  collector.on_nodes({ conn_id = 1, path = listing.path, nodes = {} })
  collector.on_nodes({ conn_id = 1, path = listing.path, request_id = listing.request_id + 1000 })
  eq(#requests, 1)
  collector.on_nodes({
    conn_id = 1,
    path = listing.path,
    request_id = listing.request_id,
    nodes = { { kind = 'table', name = 't' } },
  })
  eq(requests[2].method, 'structure')
  collector.on_structure(vim.tbl_extend('force', structure(requests[2].args), {
    conn_id = 1,
    request_id = requests[2].args.request_id,
  }))
  eq(names(assert(got, 'schema is nil')), { 'public.t' })
end

T['schema fails pending reads on disconnect and engine stop'] = function()
  connect()
  helpers.stub(require('sqmeow.rpc.client'), 'request', function()
    return true
  end)
  local errors = {}
  local function read()
    view.schema({ conn_id = 1, schema = 'public' }, function(_, err)
      table.insert(errors, err)
    end)
  end

  -- An explicit disconnect forgets the connection before `closed` arrives.
  read()
  state.remove_connection(1)
  require('sqmeow.rpc.events').on_connection({ id = 1, state = 'closed' })
  eq(errors, { 'connection closed' })

  connect()
  read()
  require('sqmeow.rpc.events').on_engine_stop()
  eq(errors, { 'connection closed', 'engine stopped' })
end

T['schema isolates a failing callback from other reads'] = function()
  connect()
  helpers.stub(require('sqmeow.rpc.client'), 'request', function()
    return true
  end)
  local messages = {}
  helpers.stub(vim, 'notify', function(message)
    table.insert(messages, message)
  end)
  local second
  view.schema({ conn_id = 1, schema = 'public' }, function()
    error('boom')
  end)
  view.schema({ conn_id = 1, schema = 'public' }, function(_, err)
    second = err
  end)
  require('sqmeow.core.schema').invalidate(1)

  eq(second, 'connection closed')
  eq(#messages, 1)
  helpers.contains(messages[1], 'boom')
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
