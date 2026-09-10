-- The plugin against PostgreSQL and MySQL, not just SQLite.
--
-- Skipped unless the servers are up. `just db-up` starts them and `just test-lua` passes their
-- URLs in, so a machine with no Docker still runs the rest of the suite.

local eq = MiniTest.expect.equality
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')
local result = require('sqmeow.ui.result')

local TIMEOUT = 15000

local servers = {
  postgres = vim.env.SQMEOW_TEST_POSTGRES_URL,
  mysql = vim.env.SQMEOW_TEST_MYSQL_URL,
}

local function connect(url)
  local id = assert(api.connect(url), 'the engine should accept the connection')
  local settled = vim.wait(TIMEOUT, function()
    local connection = state.connections[id]
    return connection == nil or connection.state ~= 'connecting'
  end, 20)
  assert(settled, 'the connection should settle')
  return state.connections[id]
end

local function run(sql)
  local call_id = assert(api.execute(sql), 'the engine should accept the query')
  local settled = vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
  end, 20)
  assert(settled, 'the query should settle: ' .. sql)
  return state.call
end

local function lines()
  return vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false)
end

local function header()
  return vim.api.nvim_buf_get_lines(result.header_buffer(), 0, -1, false)
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({})
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

for dialect, url in pairs(servers) do
  T[dialect] = MiniTest.new_set({
    hooks = {
      pre_case = function()
        if not url then
          MiniTest.skip(('set SQMEOW_TEST_%s_URL, or run `just db-up`'):format(dialect:upper()))
        end
        connect(url)
      end,
      post_case = function()
        api.disconnect()
      end,
    },
  })

  T[dialect]['connects and reports its dialect'] = function()
    eq(state.current_connection().dialect, dialect)
  end

  T[dialect]['runs a query and draws a grid'] = function()
    local summary = run("select 1 as id, 'alice' as name")
    eq(summary.state, 'done')
    eq(summary.rows, 1)
    eq(header()[1], ' id │ name')
    eq(lines()[1], '  1 │ alice')
  end

  T[dialect]['renders null distinctly from an empty string'] = function()
    run("select null as a, '' as b")
    eq(lines()[1], ' NULL │')
  end

  T[dialect]['reports an error without losing the connection'] = function()
    local failed = run('select nope_no_such_column')
    eq(failed.state, 'error')
    eq(run('select 1 as ok').state, 'done')
  end

  T[dialect]['survives a password being redacted in the label'] = function()
    -- The connection name comes from the URL, and must never carry the password.
    eq(state.current_connection().name:find('sqmeow:sqmeow', 1, true), nil)
  end
end

return T
