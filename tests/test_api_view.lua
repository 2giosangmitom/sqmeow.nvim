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

T['erd formats Mermaid erDiagram with cardinality and PK/FK/UK badges'] = function()
  local erd, err = view.erd({
    schema = 'public',
    relation = 'orders',
    tables = {
      {
        schema = 'public',
        relation = 'users',
        structure = {
          columns = {
            { name = 'id', type_name = 'int4', primary_key = true, nullable = false },
            { name = 'email', type_name = 'character varying(255)', nullable = false },
          },
          indexes = {
            { name = 'users_email_key', columns = { 'email' }, unique = true, primary = false },
          },
          foreign_keys = {},
        },
      },
      {
        schema = 'public',
        relation = 'orders',
        structure = {
          columns = {
            { name = 'id', type_name = 'int4', primary_key = true, nullable = false },
            { name = 'user_id', type_name = 'int4', nullable = false },
            { name = 'coupon_id', type_name = 'int4', nullable = true },
          },
          indexes = {
            {
              name = 'orders_coupon_uq',
              columns = { 'coupon_id' },
              unique = true,
              primary = false,
            },
          },
          foreign_keys = {
            {
              name = 'orders_user_id_fkey',
              columns = { 'user_id' },
              target = 'users',
              referenced = { 'id' },
            },
            {
              name = 'orders_coupon_id_fkey',
              columns = { 'coupon_id' },
              target = 'coupons',
              referenced = { 'id' },
            },
          },
        },
      },
      {
        schema = 'public',
        relation = 'coupons',
        structure = {
          columns = {
            { name = 'id', type_name = 'int4', primary_key = true, nullable = false },
          },
          indexes = {},
          foreign_keys = {},
        },
      },
    },
  })

  eq(err, nil)
  assert(erd, 'erd is nil')
  eq(erd.mode, 'neighborhood')
  eq(#erd.edges, 2)
  eq(erd.edges[1].connector, '||--o{')
  eq(erd.edges[1].cardinality_label, '1:N')
  eq(erd.edges[2].connector, '|o--|o')
  eq(erd.edges[2].cardinality_label, '1:1 (optional)')
  eq(
    erd.mermaid,
    table.concat({
      'erDiagram',
      '  users ||--o{ orders : "user_id -> id"',
      '  coupons |o--|o orders : "coupon_id -> id"',
      '',
      '  users {',
      '    int4 id PK',
      '    varchar(255) email UK "NOT NULL"',
      '  }',
      '  orders {',
      '    int4 id PK',
      '    int4 user_id FK "NOT NULL -> users.id"',
      '    int4 coupon_id FK "-> coupons.id"',
      '  }',
      '  coupons {',
      '    int4 id PK',
      '  }',
    }, '\n')
  )
end

T['erd collects neighborhood and schema metadata over RPC events'] = function()
  state.add_connection({
    id = 1,
    name = 'app',
    url = 'postgres://localhost/app',
    dialect = 'postgres',
    state = 'connected',
  })

  local rpc = require('sqmeow.rpc.client')
  local erd_mod = require('sqmeow.core.erd')
  local orig_request = rpc.request
  rpc.request = function(method, params)
    if method == 'relationships' then
      vim.schedule(function()
        erd_mod.on_relationships({
          conn_id = params.conn_id,
          schema = params.schema,
          relation = params.relation,
          request_id = params.request_id,
          resolved_schema = 'public',
          resolved_relation = 'orders',
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
        })
      end)
      return true, nil
    elseif method == 'structure' then
      vim.schedule(function()
        if params.relation == 'orders' then
          erd_mod.on_structure({
            conn_id = params.conn_id,
            schema = 'public',
            relation = 'orders',
            columns = {
              { name = 'id', type_name = 'int4', primary_key = true, nullable = false },
              { name = 'user_id', type_name = 'int4', nullable = false },
            },
            indexes = {},
            foreign_keys = {},
          })
        else
          erd_mod.on_structure({
            conn_id = params.conn_id,
            schema = 'public',
            relation = 'users',
            columns = {
              { name = 'id', type_name = 'int4', primary_key = true, nullable = false },
            },
            indexes = {},
            foreign_keys = {},
          })
        end
      end)
      return true, nil
    end
    return orig_request(method, params)
  end

  local got_erd, got_err
  local started, start_err = view.erd(
    { conn_id = 1, schema = 'public', relation = 'orders', hops = 1 },
    function(res, err)
      got_erd, got_err = res, err
    end
  )
  eq(started, true)
  eq(start_err, nil)
  vim.wait(500, function()
    return got_erd ~= nil or got_err ~= nil
  end)
  rpc.request = orig_request

  eq(got_err, nil)
  assert(got_erd, 'got_erd is nil')
  eq(got_erd.mode, 'neighborhood')
  eq(got_erd.center_relation, 'orders')
  eq(#got_erd.table_order, 2)
  eq(#got_erd.edges, 1)
  eq(got_erd.edges[1].connector, '||--o{')
end

T['erd rejects disconnected and unsupported NoSQL connections'] = function()
  local started, err = view.erd({ schema = 'public' })
  eq(started, false)
  eq(err, 'ERD generation needs an open connection')

  state.add_connection({
    id = 2,
    name = 'cache',
    url = 'redis://localhost:6379/0',
    dialect = 'redis',
    state = 'connected',
  })
  started, err = view.erd({ conn_id = 2 })
  eq(started, false)
  eq(err, 'ERD is not supported for redis')
end

return T
