local MiniTest = require('mini.test')
-- The plugin against PostgreSQL, MySQL and Redis, not just SQLite.

local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')
local result = require('sqmeow.ui.result')
local drawer = require('sqmeow.ui.drawer')
local sql = require('sqmeow.sql')

local TIMEOUT = 15000

--- Skip the case unless `url` is set, saying which variable would set it.
---@param url string|nil
---@param name string The environment variable, such as `'SQMEOW_TEST_POSTGRES_URL'`.
local function skip_unless(url, name)
  if not url then
    MiniTest.skip(('set %s, or run `just db-up`'):format(name))
  end
end

local servers = {
  postgres = vim.env.SQMEOW_TEST_POSTGRES_URL,
  mysql = vim.env.SQMEOW_TEST_MYSQL_URL,
}

local function run(query)
  return helpers.run(query, nil, TIMEOUT)
end

local grid = helpers.result_lines
local header = helpers.result_header
local lines = helpers.result_rows

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      -- ASCII icons, so an expectation on a grid line can be read.
      require('sqmeow').setup({ icons = { types = helpers.ascii_icons() } })
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

for _, dialect in ipairs({ 'postgres', 'mysql' }) do
  local url = servers[dialect]
  T[dialect] = MiniTest.new_set({
    hooks = {
      pre_case = function()
        skip_unless(url, ('SQMEOW_TEST_%s_URL'):format(dialect:upper()))
        helpers.connect(url, nil, TIMEOUT)
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
    -- Both columns are expressions.
    eq(header()[1], ' n id │ t name')
    -- The `id` column is four wide rather than two.
    eq(lines()[1], '    1 │ alice')
  end

  T[dialect]['marks a real primary key as a key'] = function()
    run('drop table if exists keyed')
    run('create table keyed (id int primary key, label varchar(10))')
    MiniTest.finally(function()
      run('drop table if exists keyed')
    end)

    run('select id, label from keyed')
    -- Unlike the expression above, this `id` comes from a table and is its primary key.
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
    helpers.absent(state.current_connection().name, 'sqmeow:sqmeow')
  end

  T[dialect]['shows an EXPLAIN as its plan rather than a grid'] = function()
    run('drop table if exists explained')
    run('create table explained (id int primary key, label varchar(10))')
    MiniTest.finally(function()
      run('drop table if exists explained')
    end)

    -- PostgreSQL writes a row a line; MySQL's tree is one value holding every line.
    local statement = dialect == 'mysql'
        and "explain format=tree select * from explained where label = 'a'"
      or "explain select * from explained where label = 'a'"
    eq(run(statement).state, 'done')

    local drawn = grid()
    local text = table.concat(drawn, '\n')
    eq(#drawn >= 2, true)
    helpers.contains(drawn[1], dialect == 'mysql' and '-> ' or 'Scan')
    -- The filter is there in full: nothing is cut to a column's width or drawn between columns.
    helpers.contains(text, 'label')
    helpers.absent(text, '…')
    helpers.absent(text, '│')
  end
end

-- Redis speaks no SQL.
local redis_servers = {
  redis = vim.env.SQMEOW_TEST_REDIS_URL,
  dragonfly = vim.env.SQMEOW_TEST_DRAGONFLY_URL,
}

--- One level of the drawer, as the engine reports it.
local function introspect(path, pattern)
  local reply
  -- Put back as soon as the level arrives rather than when the case ends.
  local original = helpers.swap(drawer, 'on_nodes', function(payload)
    reply = payload
  end)
  rpc.request(
    'introspect',
    { conn_id = state.current_connection().id, path = path, pattern = pattern }
  )
  helpers.wait_for('the drawer level should arrive', function()
    return reply ~= nil
  end, TIMEOUT)
  helpers.swap(drawer, 'on_nodes', original)

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

for _, server in ipairs({ 'redis', 'dragonfly' }) do
  local url = redis_servers[server]
  T[server] = MiniTest.new_set({
    hooks = {
      pre_case = function()
        skip_unless(url, ('SQMEOW_TEST_%s_URL'):format(server:upper()))
        helpers.connect(url, nil, TIMEOUT)
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

  T[server]['lists only the keys matching a pattern'] = function()
    run('SET test:lua:match:a 1')
    run('SET test:lua:unmatched 1')

    local db = introspect({})[1].name
    eq(named(introspect({ db }, 'test:lua:match:*'), 'strings').count, 1)
    local keys = introspect({ db, 'strings' }, 'test:lua:match:*')
    eq(named(keys, 'test:lua:match:a').kind, 'key')
    eq(named(keys, 'test:lua:unmatched'), nil)
  end

  T[server]['previews a key with the read for its type'] = function()
    run('DEL test:lua:preview')
    run('HSET test:lua:preview colour teal')

    local summary = run(sql.read_key('hashes', 'test:lua:preview', 10))
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

    local summary = run(sql.read_key('json', 'test:lua:doc', 10))
    eq(summary.state, 'done')
    helpers.contains(lines()[1], 'teal')
  end
end

-- A PostgreSQL URL naming no database reaches every database on the server.
T['mysql']['keeps a plain EXPLAIN, which is a table, as a grid'] = function()
  run('explain select 1')
  helpers.contains(header()[1], 'select_type')
  helpers.contains(header()[1], '│')
end

T['mysql']['shows catalog names as text rather than bytes'] = function()
  run('drop table if exists catalogued')
  run('create table catalogued (id int primary key)')
  MiniTest.finally(function()
    run('drop table if exists catalogued')
  end)

  -- MySQL answers these in columns it marks binary, though what they hold is names.
  eq(run("show tables like 'catalogued'").state, 'done')
  eq(vim.trim(lines()[1]), 'catalogued')
  run('describe catalogued')
  eq(lines()[1]:find('int', 1, true) ~= nil and lines()[1]:find('PRI', 1, true) ~= nil, true)
end

T['postgres cluster'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      skip_unless(servers.postgres, 'SQMEOW_TEST_POSTGRES_URL')
    end,
    post_case = function()
      api.disconnect()
      drawer.close()
    end,
  },
})

T['postgres cluster']['opens a database from the drawer as its own connection'] = function()
  local cluster_url, database = servers.postgres:match('^(.*/)([^/?]+)$')
  local cluster = state.connections[helpers.connect(cluster_url, { name = 'cluster' }, TIMEOUT)]
  eq(cluster.state, 'connected')
  drawer.open()

  local function toggle(pattern)
    vim.api.nvim_win_set_cursor(drawer.open(), { helpers.drawer_line(pattern, TIMEOUT), 0 })
    drawer.actions.toggle()
  end

  toggle(' cluster')
  toggle(' ' .. database .. '$')
  -- The schemas are the child connection's, read once it has connected.
  toggle(' public$')

  local child = assert(state.child_connection(cluster.id, database))
  eq(child.name, 'cluster/' .. database)
  eq(child.state, 'connected')
  for _, line in ipairs(helpers.drawer_lines()) do
    helpers.absent(line, 'cluster/')
  end

  api.disconnect(cluster.id)
  eq(state.child_connection(cluster.id, database), nil)
end

-- MongoDB speaks no SQL either: a statement is a command document in Extended JSON.
T['mongodb'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      skip_unless(vim.env.SQMEOW_TEST_MONGODB_URL, 'SQMEOW_TEST_MONGODB_URL')
      helpers.connect(vim.env.SQMEOW_TEST_MONGODB_URL, nil, TIMEOUT)
    end,
    post_case = function()
      api.disconnect()
    end,
  },
})

T['mongodb']['filters and sorts a find in the server'] = function()
  run('{"delete": "lua_filtered", "deletes": [{"q": {}, "limit": 0}]}')
  run(
    '{"insert": "lua_filtered", "documents": [{"_id": 1, "n": 1}, {"_id": 2, "n": 5}, {"_id": 3, "n": 9}]}'
  )
  run('{"find": "lua_filtered", "filter": {"n": {"$gt": 0}}}')
  result.open()

  local before = state.call.call_id
  eq(result.filter('{"n": {"$gte": 5}}', '{"n": -1}'), true)
  helpers.wait_for('the filtered find should arrive', function()
    return state.call.call_id ~= before and state.call.state ~= 'executing'
  end, TIMEOUT)
  eq(state.call.state, 'done')
  eq(state.call.rows, 2)
  helpers.contains(lines()[1], '9')
end

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
  helpers.contains(lines()[1], 'teal')
end

T['mongodb']['lists collections and previews one'] = function()
  run('{"delete": "lua_preview", "deletes": [{"q": {}, "limit": 0}]}')
  run('{"insert": "lua_preview", "documents": [{"colour": "plum"}]}')

  eq(named(introspect({}), 'sqmeow') ~= nil, true)
  local collections = named(introspect({ 'sqmeow' }), 'tables')
  eq(collections.name, 'Collections')
  eq(collections.count >= 1, true)

  local summary = run(sql.select_from('mongodb', { 'sqmeow', 'lua_preview' }, 10))
  eq(summary.state, 'done')
  eq(summary.rows, 1)
  helpers.contains(lines()[1], 'plum')
end

T['mongodb']['lists every database when the url names none'] = function()
  api.disconnect()
  helpers.connect((vim.env.SQMEOW_TEST_MONGODB_URL:gsub('/[^/]*$', '/')), nil, TIMEOUT)
  -- Rows the drawer opens as connections of their own, which is what `u` chooses between.
  eq(named(introspect({}), 'sqmeow').kind, 'database')
end

T['mongodb']['refreshing the server reloads the databases opened under it'] = function()
  api.disconnect()
  helpers.connect((vim.env.SQMEOW_TEST_MONGODB_URL:gsub('/[^/]*$', '/')), nil, TIMEOUT)
  run('{"dropDatabase": 1, "$db": "sqmeow_refresh"}')
  run('{"insert": "first", "documents": [{"x": 1}], "$db": "sqmeow_refresh"}')
  MiniTest.finally(function()
    run('{"dropDatabase": 1, "$db": "sqmeow_refresh"}')
  end)

  local function press(pattern, action)
    vim.api.nvim_win_set_cursor(drawer.open(), { helpers.drawer_line(pattern, TIMEOUT), 0 })
    drawer.actions[action]()
  end

  drawer.render()
  press('mongodb://', 'toggle')
  -- A database opened from the server is a connection of its own, with its tree cached under it.
  press('sqmeow_refresh', 'toggle')
  press('Collections', 'toggle')
  helpers.drawer_line('first', TIMEOUT)
  -- Named once: its groups sit straight under the database, with no schema row repeating it.
  local repeated = vim.tbl_filter(function(text)
    return text:find('sqmeow_refresh', 1, true) ~= nil
  end, helpers.drawer_lines())
  eq(#repeated, 1)

  run('{"insert": "second", "documents": [{"x": 1}], "$db": "sqmeow_refresh"}')
  press('mongodb://', 'refresh')
  -- Refreshing the server lists the collection added since.
  helpers.drawer_line('second', TIMEOUT)
end

T['mongodb']['a find that matches nothing says so'] = function()
  run('{"delete": "lua_empty", "deletes": [{"q": {}, "limit": 0}]}')
  local summary = run('{"find": "lua_empty"}')
  eq(summary.state, 'done')
  -- Neither rows nor a count.
  eq(summary.affected, nil)
  helpers.contains(result.describe(summary), 'no rows')
end

T['mongodb']['names the database it runs on, following use'] = function()
  local connection = assert(state.current_connection())
  eq(connection.current_database, 'sqmeow')

  run('use sqmeow_other')
  eq(connection.current_database, 'sqmeow_other')
  -- The winbar is what tells someone which database their next query reaches.
  helpers.contains(state.label(connection), '› sqmeow_other (mongodb)')
end

-- ScyllaDB and Cassandra speak CQL, and each case runs against both.
for _, server in ipairs({ 'scylla', 'cassandra' }) do
  local variable = ('SQMEOW_TEST_%s_URL'):format(server:upper())
  T[server] = MiniTest.new_set({
    hooks = {
      pre_case = function()
        skip_unless(vim.env[variable], variable)
        helpers.connect(vim.env[variable], nil, TIMEOUT)
        run(
          "create keyspace if not exists sqmeow with replication = {'class': 'SimpleStrategy', 'replication_factor': 1}"
        )
      end,
      post_case = function()
        api.disconnect()
      end,
    },
  })

  T[server]['connects and reports its dialect'] = function()
    eq(state.current_connection().dialect, 'scylla')
  end

  T[server]['lists keyspaces and previews a table with its key'] = function()
    run('drop table if exists sqmeow.lua_preview')
    run('create table sqmeow.lua_preview (id int primary key, colour text)')
    run("insert into sqmeow.lua_preview (id, colour) values (1, 'plum')")

    eq(named(introspect({}), 'sqmeow') ~= nil, true)
    local groups = introspect({ 'sqmeow' })
    eq(named(groups, 'tables').count >= 1, true)
    eq(named(groups, 'procedures'), nil)

    local summary = run(sql.select_from('scylla', { 'sqmeow', 'lua_preview' }, 10))
    eq(summary.state, 'done')
    eq(summary.rows, 1)
    eq(header()[1], ' K id │ t colour')
    helpers.contains(lines()[1], 'plum')
  end
end

return T
