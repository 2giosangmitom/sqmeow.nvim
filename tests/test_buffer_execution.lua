local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local state = require('sqmeow.core.state')
local rpc = require('sqmeow.rpc.client')

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ query = { persist_history = false } })
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

local adapters = {
  sqlite = { url = 'sqlite::memory:' },
  duckdb = { url = 'duckdb::memory:' },
  postgres = {},
  mysql = {},
  mssql = {},
  oracle = {},
  clickhouse = {},
  redis = { query = 'ECHO "a;b"' },
  dragonfly = { query = 'ECHO "a;b"' },
  mongodb = {
    query = '{"ping":1}',
    view_query = [[{"aggregate":1,"pipeline":[{"$documents":[
      {"id":1,"name":"alice","active":true},
      {"id":2,"name":"bob","active":false},
      {"id":3,"name":"carol","active":true}
    ]}],"cursor":{}}]],
  },
  surrealdb = { query = "RETURN 'a;b';" },
  scylla = { query = 'SELECT cluster_name FROM system.local;' },
  cassandra = { query = 'SELECT cluster_name FROM system.local;' },
  cockroach = {
    view_query = [[SELECT * FROM (VALUES (1::INT8, 'alice'), (2::INT8, 'bob'),
      (3::INT8, 'carol')) AS people(id, name)]],
  },
}

local function wait(id)
  helpers.wait_for('buffer execution settles', function()
    return state.call ~= nil and state.call.call_id == id and state.call.state ~= 'executing'
  end, 15000)
  eq(state.call.state, 'done')
  eq(state.call.rows > 0, true)
end

for name, spec in pairs(adapters) do
  local variable = 'SQMEOW_TEST_' .. name:upper() .. '_URL'
  local query = spec.query
    or (name == 'oracle' and "SELECT 'a;b' AS note FROM dual;" or "SELECT 'a;b' AS note;")
  local id, buf, path
  local group = MiniTest.new_set({
    hooks = {
      pre_case = function()
        local url = spec.url or vim.env[variable]
        if not url then
          MiniTest.skip('set ' .. variable)
        end
        id = helpers.connect(url, { name = name }, 15000)
        eq(state.connections[id].state, 'connected')
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(
          buf,
          0,
          -1,
          false,
          { 'unselected invalid query', query, 'unselected invalid query' }
        )
        vim.api.nvim_set_current_buf(buf)
        path = vim.fn.tempname()
        vim.fn.writefile({ 'stale invalid query on disk' }, path)
        vim.api.nvim_buf_set_name(buf, path)
        vim.bo[buf].modified = true
        vim.b[buf].sqmeow_connection = name
      end,
      post_case = function()
        if id then
          require('sqmeow.api.connection').disconnect(id)
        end
        if buf then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        if path then
          vim.fn.delete(path)
        end
        id, buf, path = nil, nil, nil
      end,
    },
  })
  T[name] = group

  group['visual key executes only unsaved selection'] = function()
    local execute, accepted = require('sqmeow.api.query').execute, nil
    helpers.stub(require('sqmeow.api.query'), 'execute', function(sql, opts)
      accepted = execute(sql, opts)
      return accepted
    end)
    require('sqmeow.ui.editor').attach(0, name)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.keycode('V<CR>'), 'mx', false)
    wait(assert(accepted, 'selection was accepted'))
    eq(state.call.statement, query)
  end

  group['explicit range executes unsaved requested lines'] = function()
    local execute, accepted = require('sqmeow.api.query').execute, nil
    helpers.stub(require('sqmeow.api.query'), 'execute', function(sql, opts)
      accepted = execute(sql, opts)
      return accepted
    end)
    vim.cmd('2Sqmeow execute')
    wait(assert(accepted, 'range was accepted'))
    eq(state.call.statement, query)
  end

  group['whole buffer uses unsaved content'] = function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })
    wait(assert(require('sqmeow.api.query').execute_buffer()))
    eq(state.call.statement, query)
  end

  group['Polars SQL filters and sorts retained rows before and after disconnecting'] = function()
    local result = require('sqmeow.ui.result')
    wait(assert(require('sqmeow.api.query').execute(spec.view_query or query, { conn_id = id })))
    local call_id, total = state.call.call_id, state.call.rows
    local column_name = result.filter_names(state.call)[1]
    local order = result.quote(column_name) .. ' DESC NULLS LAST'
    local views = 0
    local unsub = rpc.on('call:view', function(payload)
      if payload.call_id == call_id then
        eq(payload.error, nil)
        views = views + 1
      end
    end)
    MiniTest.finally(unsub)
    local request = rpc.request
    helpers.stub(rpc, 'request', function(method, args)
      if method == 'execute' then
        error('filtering must not run another query')
      end
      return request(method, args)
    end)
    eq(result.filter('1 = 0', order), true)
    helpers.wait_for('the empty local view arrives', function()
      return views == 1
    end)
    eq(state.call.view_rows, 0)
    eq(result.filter('1 = 1', order), true)
    helpers.wait_for('the sorted original rows return', function()
      return views == 2
    end)
    eq(state.call.call_id, call_id)
    eq(state.call.rows, total)
    if spec.view_query then
      eq(rpc.request('rows', { call_id = call_id, offset = 0, limit = 10 }).indices, { 2, 1, 0 })
      eq(result.filter("name ILIKE '%AL%'", 'id DESC'), true)
      helpers.wait_for('the common SQL predicate arrives', function()
        return views == 3
      end)
      eq(rpc.request('rows', { call_id = call_id, offset = 0, limit = 10 }).indices, { 0 })
    end
    require('sqmeow.api.connection').disconnect(id)
    helpers.wait_for('the database connection closes', function()
      return state.connections[id] == nil
    end)
    local before = views
    eq(result.filter('1 = 1', order), true)
    helpers.wait_for('the disconnected local view arrives', function()
      return views == before + 1
    end)
    eq(state.call.call_id, call_id)
    eq(rpc.request('rows', { call_id = call_id, offset = 0, limit = total }).total, total)
  end
end

T['mssql keeps variables within GO batches'] = function()
  local url = vim.env.SQMEOW_TEST_MSSQL_URL
  if not url then
    MiniTest.skip('set SQMEOW_TEST_MSSQL_URL')
  end
  local id = helpers.connect(url, { name = 'mssql_batches' }, 15000)
  MiniTest.finally(function()
    require('sqmeow.api.connection').disconnect(id)
  end)
  local buf =
    helpers.temp_buf({ 'DECLARE @n int = 7;', 'SELECT @n AS n;', 'GO', 'SELECT 99 AS n;' })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  wait(assert(require('sqmeow.api.query').execute_statement()))
  local row = assert(rpc.request('row', { call_id = state.call.call_id, row = 0 }))
  eq(row[1].value, '7')
  wait(assert(require('sqmeow.api.query').execute_buffer()))
  row = assert(rpc.request('row', { call_id = state.call.call_id, row = 0 }))
  eq(row[1].value, '99')
  eq(#state.call.results, 2)
end

T['mssql read-only checks filter fragments before execution'] = function()
  local url = vim.env.SQMEOW_TEST_MSSQL_URL
  if not url then
    MiniTest.skip('set SQMEOW_TEST_MSSQL_URL')
  end
  local id = helpers.connect(url, { name = 'mssql_readonly', read_only = true }, 15000)
  MiniTest.finally(function()
    require('sqmeow.api.connection').disconnect(id)
  end)
  local call, err = require('sqmeow.api.query').execute('SELECT 1 AS n', {
    conn_id = id,
    confirmed = true,
    where = '1=1; DELETE FROM sqmeow_should_never_be_executed',
  })
  eq(call, nil)
  helpers.contains(err, 'read-only')
  wait(
    assert(
      require('sqmeow.api.query').execute(
        'SELECT 1 AS n',
        { conn_id = id, confirmed = true, where = 'n=1' }
      )
    )
  )
end

return T
