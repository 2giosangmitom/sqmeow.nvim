local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = require('sqmeow.api')
local state = require('sqmeow.state')
local rpc = require('sqmeow.rpc')

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
  redis_cluster = { query = 'ECHO "a;b"' },
  redis_sentinel = { query = 'ECHO "a;b"' },
  mongodb = { query = '{"ping":1}' },
  surrealdb = { query = "RETURN 'a;b';" },
  scylla = { query = 'SELECT cluster_name FROM system.local;' },
  cassandra = { query = 'SELECT cluster_name FROM system.local;' },
  cockroach = {},
  questdb = {},
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
          api.disconnect(id)
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
    local execute, accepted = api.execute, nil
    helpers.stub(api, 'execute', function(sql, opts)
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
    local execute, accepted = api.execute, nil
    helpers.stub(api, 'execute', function(sql, opts)
      accepted = execute(sql, opts)
      return accepted
    end)
    vim.cmd('2Sqmeow execute')
    wait(assert(accepted, 'range was accepted'))
    eq(state.call.statement, query)
  end

  group['whole buffer uses unsaved content'] = function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })
    wait(assert(api.execute_buffer()))
    eq(state.call.statement, query)
  end
end

T['mssql keeps variables within GO batches'] = function()
  local url = vim.env.SQMEOW_TEST_MSSQL_URL
  if not url then
    MiniTest.skip('set SQMEOW_TEST_MSSQL_URL')
  end
  local id = helpers.connect(url, { name = 'mssql_batches' }, 15000)
  MiniTest.finally(function()
    api.disconnect(id)
  end)
  local buf =
    helpers.temp_buf({ 'DECLARE @n int = 7;', 'SELECT @n AS n;', 'GO', 'SELECT 99 AS n;' })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  wait(assert(api.execute_statement()))
  local row = assert(rpc.request('row', { call_id = state.call.call_id, row = 0 }))
  eq(row[1].value, '7')
  wait(assert(api.execute_buffer()))
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
    api.disconnect(id)
  end)
  local call, err = api.execute('SELECT 1 AS n', {
    conn_id = id,
    confirmed = true,
    where = '1=1; DELETE FROM sqmeow_should_never_be_executed',
  })
  eq(call, nil)
  helpers.contains(err, 'read-only')
  wait(assert(api.execute('SELECT 1 AS n', { conn_id = id, confirmed = true, where = 'n=1' })))
end

return T
