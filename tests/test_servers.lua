local MiniTest = require('mini.test')
-- One Lua-to-engine connection/query smoke case per server; adapter details live in Rust.
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local state = require('sqmeow.core.state')
local rpc = require('sqmeow.rpc.client')
local TIMEOUT = 15000

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({})
    end,
    post_case = function()
      require('sqmeow.api.connection').disconnect()
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

for _, spec in ipairs({
  { 'postgres', 'postgres', 'select 42 as answer' },
  { 'cockroach', 'postgres', 'select 42 as answer' },
  { 'mysql', 'mysql', 'select 42 as answer' },
  { 'mariadb', 'mysql', 'select 42 as answer' },
  { 'mssql', 'mssql', 'select 42 as answer' },
  { 'redis', 'redis', 'SET test:lua:visits 41\nINCR test:lua:visits' },
  { 'dragonfly', 'redis', 'SET test:lua:visits 41\nINCR test:lua:visits' },
  { 'mongodb', 'mongodb', '{"ping": 1}' },
  { 'scylla', 'scylla', 'select keyspace_name from system_schema.keyspaces' },
  { 'cassandra', 'scylla', 'select keyspace_name from system_schema.keyspaces' },
  { 'surrealdb', 'surrealdb', 'RETURN 42' },
  { 'clickhouse', 'clickhouse', 'select 42 as answer' },
  { 'oracle', 'oracle', 'select 42 as answer from dual' },
}) do
  local server, dialect, query = unpack(spec)
  T[server .. ' connects and executes through RPC'] = function()
    local variable = ('SQMEOW_TEST_%s_URL'):format(server:upper())
    local url = vim.env[variable]
    if not url then
      MiniTest.skip(('set %s, or run `just db-up`'):format(variable))
    end
    if server == 'surrealdb' then
      url = url .. '/lua'
    end
    helpers.connect(url, nil, TIMEOUT)
    eq(state.current_connection().dialect, dialect)
    if server == 'surrealdb' then
      helpers.run('DEFINE DATABASE IF NOT EXISTS lua', nil, TIMEOUT)
    end
    local summary = helpers.run(query, nil, TIMEOUT)
    eq(summary.state, 'done')
    eq(summary.rows > 0, true)
    local row = rpc.request('row', { call_id = summary.call_id, row = 0 })
    eq(#row > 0, true)
    if server ~= 'mongodb' and server ~= 'scylla' and server ~= 'cassandra' then
      eq(row[1].value, '42')
    end
  end
end

return T
