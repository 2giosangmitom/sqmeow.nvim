local MiniTest = require('mini.test')
-- The plugin against PostgreSQL, MySQL and Redis, not just SQLite.
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

local function connect(url, opts)
  local id = assert(api.connect(url, opts), 'the engine should accept the connection')
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

-- Redis speaks no SQL, so it gets cases of its own rather than a turn through the loop above.
-- Dragonfly speaks the same protocol, so the same cases run against it too.
local redis_servers = {
  redis = vim.env.SQMEOW_TEST_REDIS_URL,
  dragonfly = vim.env.SQMEOW_TEST_DRAGONFLY_URL,
}

--- One level of the drawer, as the engine reports it.
local function introspect(path)
  local drawer = require('sqmeow.ui.drawer')
  local original = drawer.on_nodes
  local reply
  drawer.on_nodes = function(payload)
    reply = payload
  end
  rpc.request('introspect', { conn_id = state.current_connection().id, path = path })
  local settled = vim.wait(TIMEOUT, function()
    return reply ~= nil
  end, 20)
  drawer.on_nodes = original

  assert(settled, 'the drawer level should arrive')
  eq(reply.error, nil)
  return reply.nodes
end

local function named(nodes, name)
  for _, node in ipairs(nodes) do
    if (node.key or node.name) == name then
      return node
    end
  end
end

for server, url in pairs(redis_servers) do
  T[server] = MiniTest.new_set({
    hooks = {
      pre_case = function()
        if not url then
          MiniTest.skip(('set SQMEOW_TEST_%s_URL, or run `just db-up`'):format(server:upper()))
        end
        connect(url)
      end,
      post_case = function()
        api.disconnect()
      end,
    },
  })

  T[server]['connects and reports its dialect'] = function()
    eq(state.current_connection().dialect, 'redis')
  end

  T[server]['runs a script one command per line'] = function()
    -- Read as one statement, these would be a `SET` with three words too many and fail.
    local summary = run('SET test:lua:visits 41\nINCR test:lua:visits')
    eq(summary.state, 'done')
    eq(vim.trim(lines()[1]), '42')
  end

  T[server]['lists keys under the group for their type'] = function()
    run('DEL test:lua:hash')
    run('HSET test:lua:hash field value')

    local db = introspect({})[1].name
    local hashes = named(introspect({ db }), 'hashes')
    eq(hashes.kind, 'keys')
    eq(hashes.count >= 1, true)

    local key = named(introspect({ db, 'hashes' }), 'test:lua:hash')
    eq(key.kind, 'key')
    eq(key.expandable, false)
  end

  T[server]['previews a key with the read for its type'] = function()
    run('DEL test:lua:preview')
    run('HSET test:lua:preview colour teal')

    local summary = run(require('sqmeow.sql').read_key('hashes', 'test:lua:preview', 10))
    eq(summary.state, 'done')
    eq(summary.rows, 1)
    eq(lines()[1]:find('colour', 1, true) ~= nil and lines()[1]:find('teal', 1, true) ~= nil, true)
  end

  T[server]['lists and previews a JSON document'] = function()
    run('DEL test:lua:doc')
    run([[JSON.SET test:lua:doc $ '{"colour":"teal"}']])

    -- Both servers answer `ReJSON-RL` for a document, which once kept it out of the drawer.
    local db = introspect({})[1].name
    eq(named(introspect({ db }), 'json').count >= 1, true)
    eq(named(introspect({ db, 'json' }), 'test:lua:doc').kind, 'key')

    local summary = run(require('sqmeow.sql').read_key('json', 'test:lua:doc', 10))
    eq(summary.state, 'done')
    eq(lines()[1]:find('teal', 1, true) ~= nil, true)
  end
end

-- A PostgreSQL URL naming no database reaches every database on the server.
T['postgres cluster'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not servers.postgres then
        MiniTest.skip('set SQMEOW_TEST_POSTGRES_URL, or run `just db-up`')
      end
    end,
    post_case = function()
      api.disconnect()
      require('sqmeow.ui.drawer').close()
    end,
  },
})

T['postgres cluster']['opens a database from the drawer as its own connection'] = function()
  local drawer = require('sqmeow.ui.drawer')
  local cluster_url, database = servers.postgres:match('^(.*/)([^/?]+)$')
  local cluster = connect(cluster_url, { name = 'cluster' })
  eq(cluster.state, 'connected')
  drawer.open()

  local function drawn()
    return vim.api.nvim_buf_get_lines(drawer.buffer(), 0, -1, false)
  end
  local function toggle(pattern)
    local found
    local arrived = vim.wait(TIMEOUT, function()
      for number, line in ipairs(drawn()) do
        if line:find(pattern) then
          found = number
          return true
        end
      end
      return false
    end, 20)
    assert(
      arrived,
      ('no line matching %q; drawer holds:\n%s'):format(pattern, table.concat(drawn(), '\n'))
    )
    vim.api.nvim_win_set_cursor(drawer.open(), { found, 0 })
    drawer.actions.toggle()
  end

  toggle(' cluster')
  toggle(' ' .. database .. '$')
  -- The schemas are the child connection's, read once it has connected.
  toggle(' public$')

  local child = state.child_connection(cluster.id, database)
  eq(child.name, 'cluster/' .. database)
  eq(child.state, 'connected')
  for _, line in ipairs(drawn()) do
    eq(line:find('cluster/', 1, true), nil)
  end

  api.disconnect(cluster.id)
  eq(state.child_connection(cluster.id, database), nil)
end

-- MongoDB speaks no SQL either: a statement is a command document in Extended JSON.
T['mongodb'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not vim.env.SQMEOW_TEST_MONGODB_URL then
        MiniTest.skip('set SQMEOW_TEST_MONGODB_URL, or run `just db-up`')
      end
      connect(vim.env.SQMEOW_TEST_MONGODB_URL)
    end,
    post_case = function()
      api.disconnect()
    end,
  },
})

T['mongodb']['connects and reports its dialect'] = function()
  eq(state.current_connection().dialect, 'mongodb')
end

T['mongodb']['runs a script of documents spanning lines'] = function()
  local summary = run(table.concat({
    '{"delete": "lua_script", "deletes": [{"q": {}, "limit": 0}]}',
    '{"insert": "lua_script",',
    '  "documents": [{"_id": 1, "colour": "teal"}]}',
    '{"find": "lua_script"}',
  }, '\n'))
  eq(summary.state, 'done')
  eq(lines()[1]:find('teal', 1, true) ~= nil, true)
end

T['mongodb']['lists collections and previews one'] = function()
  run('{"delete": "lua_preview", "deletes": [{"q": {}, "limit": 0}]}')
  run('{"insert": "lua_preview", "documents": [{"colour": "plum"}]}')

  eq(named(introspect({}), 'sqmeow') ~= nil, true)
  local collections = named(introspect({ 'sqmeow' }), 'tables')
  eq(collections.name, 'Collections')
  eq(collections.count >= 1, true)

  local summary = run(require('sqmeow.sql').select_from('mongodb', { 'sqmeow', 'lua_preview' }, 10))
  eq(summary.state, 'done')
  eq(summary.rows, 1)
  eq(lines()[1]:find('plum', 1, true) ~= nil, true)
end

T['mongodb']['lists every database when the url names none'] = function()
  api.disconnect()
  connect((vim.env.SQMEOW_TEST_MONGODB_URL:gsub('/[^/]*$', '/')))
  -- Rows the drawer opens as connections of their own, which is what `u` chooses between.
  eq(named(introspect({}), 'sqmeow').kind, 'database')
end

T['mongodb']['refreshing the server reloads the databases opened under it'] = function()
  local drawer = require('sqmeow.ui.drawer')
  api.disconnect()
  connect((vim.env.SQMEOW_TEST_MONGODB_URL:gsub('/[^/]*$', '/')))
  run('{"dropDatabase": 1, "$db": "sqmeow_refresh"}')
  run('{"insert": "first", "documents": [{"x": 1}], "$db": "sqmeow_refresh"}')
  MiniTest.finally(function()
    run('{"dropDatabase": 1, "$db": "sqmeow_refresh"}')
  end)

  local function drawn()
    return vim.api.nvim_buf_get_lines(drawer.buffer(), 0, -1, false)
  end
  --- The number of the last line matching `pattern`, once one is drawn.
  local function line(pattern, timeout)
    local found
    vim.wait(timeout or TIMEOUT, function()
      for number, text in ipairs(drawn()) do
        if text:find(pattern) then
          found = number
        end
      end
      return found ~= nil
    end, 20)
    return found
  end
  local function press(pattern, action)
    local number = line(pattern)
    assert(number, ('no line matching %q:\n%s'):format(pattern, table.concat(drawn(), '\n')))
    vim.api.nvim_win_set_cursor(drawer.open(), { number, 0 })
    drawer.actions[action]()
  end

  drawer.render()
  press('mongodb://', 'toggle')
  -- A database opened from the server is a connection of its own, with its tree cached under it.
  press('sqmeow_refresh', 'toggle')
  press('Collections', 'toggle')
  assert(line('first'), 'the collection should be listed')
  -- Named once: its groups sit straight under the database, with no schema row repeating it.
  local repeated = vim.tbl_filter(function(text)
    return text:find('sqmeow_refresh', 1, true) ~= nil
  end, drawn())
  eq(#repeated, 1)

  run('{"insert": "second", "documents": [{"x": 1}], "$db": "sqmeow_refresh"}')
  press('mongodb://', 'refresh')
  assert(
    line('second'),
    'refreshing the server should list the new collection:\n' .. table.concat(drawn(), '\n')
  )
end

T['mongodb']['a find that matches nothing says so'] = function()
  run('{"delete": "lua_empty", "deletes": [{"q": {}, "limit": 0}]}')
  local summary = run('{"find": "lua_empty"}')
  eq(summary.state, 'done')
  -- Neither rows nor a count. The count is left out rather than sent as a nil the winbar would
  -- try to print as a number.
  eq(summary.affected, nil)
  eq(result.describe(summary):find('no rows', 1, true) ~= nil, true)
end

T['mongodb']['names the database it runs on, following use'] = function()
  local connection = state.current_connection()
  eq(connection.current_database, 'sqmeow')

  run('use sqmeow_other')
  eq(connection.current_database, 'sqmeow_other')
  -- The winbar is what tells someone which database their next query reaches.
  eq(state.label(connection):find('› sqmeow_other (mongodb)', 1, true) ~= nil, true)
end

return T
