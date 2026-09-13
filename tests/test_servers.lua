local MiniTest = require('mini.test')
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

local function grid()
  return vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false)
end

local function header()
  return vim.list_slice(grid(), 1, 2)
end

local function lines()
  return vim.list_slice(grid(), 3)
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      -- ASCII icons, so an expectation on a grid line can be read. The defaults are Nerd Font
      -- glyphs, which a test file cannot assert on without becoming unreadable itself.
      require('sqmeow').setup({
        icons = {
          types = {
            text = 't',
            number = 'n',
            boolean = 'b',
            temporal = 'd',
            json = 'j',
            uuid = 'u',
            binary = 'y',
            unknown = '?',
            primary_key = 'K',
            foreign_key = 'k',
          },
        },
      })
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
    -- Both columns are expressions, so neither is anyone's key, and each is marked with what it
    -- holds instead. The two dialects name these types nothing alike — `int4` and `text` against
    -- `BIGINT` and `VARCHAR` — and classifying them is what makes one expectation serve both.
    eq(header()[1], ' n id │ t name')
    -- The `id` column is four wide rather than two: the glyph and its space are wider than the
    -- values, so the value is padded out to meet them.
    eq(lines()[1], '    1 │ alice')
  end

  T[dialect]['marks a real primary key as a key'] = function()
    run('drop table if exists keyed')
    run('create table keyed (id int primary key, label varchar(10))')
    MiniTest.finally(function()
      run('drop table if exists keyed')
    end)

    run('select id, label from keyed')
    -- Unlike the expression above, this `id` comes from a table and is its primary key. Getting
    -- here means the engine resolved the column back to its table on this dialect.
    eq(header()[1], ' K id │ t label')
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
