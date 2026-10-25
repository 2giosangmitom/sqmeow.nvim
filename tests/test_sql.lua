local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local sql = require('sqmeow.core.sql')
local helpers = require('tests.helpers')

local T = MiniTest.new_set()

T['qualify'] = MiniTest.new_set()

T['qualify']['quotes each part for the dialect'] = function()
  eq(sql.qualify('postgres', { 'public', 'users' }), '"public"."users"')
  eq(sql.qualify('mysql', { 'shop', 'orders' }), '`shop`.`orders`')
end

T['qualify']['names a redis key by itself'] = function()
  eq(sql.qualify('redis', { 'db0', 'user:1' }), 'user:1')
end

T['qualify']['names a surrealdb table by itself, in backticks'] = function()
  eq(sql.qualify('surrealdb', { 'main', 'we`ird' }), '`we\\`ird`')
  eq(sql.select_from('surrealdb', { 'main', 'person' }, 5), 'select * from `person` limit 5')
end

T['qualify']['names a mongodb collection by itself'] = function()
  eq(sql.qualify('mongodb', { 'shop', 'orders' }), 'orders')
end

T['read_key'] = MiniTest.new_set()

T['read_key']['reads each type with its own command'] = function()
  eq(sql.read_key('strings', 'visits', 100), 'GET "visits"')
  eq(sql.read_key('hashes', 'user:1', 100), 'HGETALL "user:1"')
  eq(sql.read_key('lists', 'queue', 100), 'LRANGE "queue" 0 99')
  eq(sql.read_key('sets', 'tags', 100), 'SMEMBERS "tags"')
  eq(sql.read_key('sorted_sets', 'board', 100), 'ZRANGE "board" 0 99 WITHSCORES')
  eq(sql.read_key('streams', 'events', 100), 'XRANGE "events" - + COUNT 100')
  eq(sql.read_key('json', 'profile', 100), 'JSON.GET "profile"')
end

T['read_key']['reads everything without a limit'] = function()
  eq(sql.select_from('postgres', { 'public', 'users' }), 'select * from "public"."users"')
  eq(sql.select_from('mongodb', { 'shop', 'orders' }), '{"find": "orders", "$db": "shop"}')
  eq(sql.read_key('lists', 'queue'), 'LRANGE "queue" 0 -1')
  eq(sql.read_key('streams', 'events'), 'XRANGE "events" - +')
end

T['read_key']['escapes a key so it stays one word'] = function()
  eq(sql.read_key('strings', 'a "b"\\\nc', 1), [[GET "a \"b\"\\\nc"]])
end

T['read_key']['has nothing for a group that is not a type'] = function()
  eq(sql.read_key('tables', 'users', 1), nil)
end

T['select_from'] = MiniTest.new_set()

T['select_from']['uses T-SQL brackets and TOP'] = function()
  eq(sql.quote('mssql', 'odd]name'), '[odd]]name]')
  eq(sql.select_from('mssql', { 'dbo', 'users' }, 10), 'select top (10) * from [dbo].[users]')
  eq(sql.select_from('mssql', { 'dbo', 'users' }, 0), 'select top (0) * from [dbo].[users]')
  eq(sql.select_from('mssql', { 'dbo', 'users' }), 'select * from [dbo].[users]')
end

T['select_from']['finds in a mongodb collection on its own database'] = function()
  -- The command name has to be the first key, and `$db` keeps the scratchpad's database as it is.
  eq(
    sql.select_from('mongodb', { 'shop', 'orders' }, 50),
    '{"find": "orders", "limit": 50, "$db": "shop"}'
  )
end

T['select_from']['reads the first rows of an oracle table with fetch first'] = function()
  eq(
    sql.select_from('oracle', { 'SQMEOW', 'PEOPLE' }, 10),
    'select * from "SQMEOW"."PEOPLE" fetch first 10 rows only'
  )
  eq(sql.select_from('oracle', { 'SQMEOW', 'PEOPLE' }), 'select * from "SQMEOW"."PEOPLE"')
end

T['alter_table'] = MiniTest.new_set()

T['alter_table']['uses separate editable statements, not column comments'] = function()
  local cols = {
    { name = 'id', type_name = 'integer', primary_key = true },
    { name = 'email', type_name = 'text', nullable = false },
  }
  local res = assert(sql.alter_table('postgres', { 'public', 'users' }, cols))
  eq(
    res:sub((assert(res:find('ALTER TABLE', 1, true)))),
    [[ALTER TABLE "public"."users"
  ALTER COLUMN "id" TYPE integer;

ALTER TABLE "public"."users"
  ALTER COLUMN "email" TYPE text;]]
  )
  helpers.absent(res, '-- Current columns:')
end

local alterations = {
  postgres = 'ALTER COLUMN "email" TYPE varchar(255)',
  cockroachdb = 'ALTER COLUMN "email" TYPE varchar(255)',
  duckdb = 'ALTER COLUMN "email" TYPE varchar(255)',
  mysql = 'MODIFY COLUMN `email` varchar(255) NOT NULL',
  mariadb = 'MODIFY COLUMN `email` varchar(255) NOT NULL',
  mssql = 'ALTER COLUMN [email] varchar(255) NOT NULL',
  oracle = 'MODIFY ("email" varchar(255))',
  clickhouse = 'MODIFY COLUMN "email" varchar(255)',
}
for dialect, alteration in pairs(alterations) do
  T['alter_table']['uses ' .. dialect .. ' syntax'] = function()
    local res = sql.alter_table(dialect, { 'shop', 'users' }, {
      { name = 'email', type_name = 'varchar(255)', nullable = false },
    })
    helpers.contains(
      res,
      'ALTER TABLE ' .. sql.qualify(dialect, { 'shop', 'users' }) .. '\n  ' .. alteration .. ';'
    )
  end
end

T['alter_table']['preserves mysql nullability and defaults'] = function()
  local res = sql.alter_table('mariadb', { 'shop', 'users' }, {
    { name = 'email', type_name = 'varchar(255)', nullable = false, default = "'unknown'" },
    { name = 'age', type_name = 'int', nullable = true },
  })
  helpers.contains(res, "MODIFY COLUMN `email` varchar(255) NOT NULL DEFAULT 'unknown';")
  helpers.contains(res, 'MODIFY COLUMN `age` int NULL;')
  helpers.contains(res, 'ALTER TABLE `shop`.`users`')
end

T['alter_table']['uses rename placeholders for sqlite'] = function()
  local res = sql.alter_table('sqlite', { 'main', 'users' }, {
    { name = 'email', type_name = 'text' },
  })
  helpers.contains(res, 'ALTER TABLE "main"."users" RENAME COLUMN "email" TO "email_renamed";')
  helpers.absent(res, 'ALTER COLUMN')
end

T['alter_table']['overwrites surrealdb fields, excluding implicit id'] = function()
  local res = sql.alter_table('surrealdb', { 'main', 'person' }, {
    { name = 'id', type_name = 'record', primary_key = true },
    { name = 'email', type_name = 'option<string>' },
  })
  helpers.contains(res, 'DEFINE FIELD OVERWRITE `email` ON TABLE `person` TYPE option<string>;')
  helpers.absent(res, 'OVERWRITE `id`')
end

T['alter_table']['quotes multiline column names as identifiers, never comments'] = function()
  local name = 'notes"\nDROP TABLE users;\n--'
  local res = sql.alter_table('postgres', { 'public', 'users' }, {
    { name = name, type_name = 'text' },
  })
  helpers.contains(res, 'ALTER COLUMN ' .. sql.quote('postgres', name) .. ' TYPE text;')
  helpers.absent(res, '--   notes')
  eq(sql.quote('mariadb', 'we`ird'), '`we``ird`')
end

T['alter_table']['uses a placeholder for multiline type metadata'] = function()
  local res = sql.alter_table('postgres', { 'public', 'users' }, {
    { name = 'email', type_name = 'text\nDROP TABLE users;\n--' },
  })
  helpers.contains(res, 'ALTER COLUMN "email" TYPE new_type;')
  helpers.absent(res, 'DROP TABLE')
end

T['alter_table']['leaves explicit placeholders for missing types or columns'] = function()
  helpers.contains(
    sql.alter_table('postgres', { 'public', 'users' }, {}),
    'ALTER COLUMN "column_name" TYPE new_type;'
  )
  helpers.contains(
    sql.alter_table('postgres', { 'public', 'users' }, { { name = 'email' } }),
    'ALTER COLUMN "email" TYPE new_type;'
  )
end

T['alter_table']['rejects unsupported dialects'] = function()
  for _, dialect in ipairs({ 'mongodb', 'redis', 'cassandra', 'unknown' }) do
    eq(sql.alter_table(dialect, { 'shop', 'users' }), nil)
  end
  eq(sql.alter_table(nil, { 'users' }), nil)
end

T['alter_table']['executes separate duckdb alterations'] = function()
  if vim.fn.executable('duckdb') == 0 then
    MiniTest.skip('DuckDB CLI is not available')
  end
  local template = assert(sql.alter_table('duckdb', { 'main', 'users' }, {
    { name = 'id', type_name = 'bigint' },
    { name = 'email', type_name = 'varchar' },
  }))
  local output = vim.fn.system({
    'duckdb',
    '-no-init',
    '-bail',
    '-csv',
    '-noheader',
    ':memory:',
    '-c',
    "CREATE TABLE users (id integer, email varchar); INSERT INTO users VALUES (1, 'kept');\n"
      .. template
      .. '\nSELECT id, email FROM users;',
  })
  eq(vim.v.shell_error, 0)
  eq(vim.trim(output), '1,kept')
end

T['alter_table']['keeps multiline sqlite identifiers from executing as SQL'] = function()
  if vim.fn.executable('sqlite3') == 0 then
    MiniTest.skip('SQLite CLI is not available')
  end
  local name = 'notes"\nDROP TABLE users;\n--'
  local template = assert(sql.alter_table('sqlite', { 'main', 'users' }, {
    { name = name, type_name = 'text' },
  }))
  local quoted = sql.quote('sqlite', name)
  local output = vim.fn.system({
    'sqlite3',
    '-bail',
    ':memory:',
    'CREATE TABLE users ('
      .. quoted
      .. " text); INSERT INTO users VALUES ('kept');\n"
      .. template
      .. '\nSELECT '
      .. sql.quote('sqlite', name .. '_renamed')
      .. ' FROM users;',
  })
  eq(vim.v.shell_error, 0)
  eq(vim.trim(output), 'kept')
end

T['select_where'] = MiniTest.new_set()

T['select_where']['quotes identifiers, literals, and dialect row limits'] = function()
  eq(
    sql.select_where('postgres', { 'public', 'users' }, {
      { column = 'id', value = 42, numeric = true },
    }, 100),
    'select * from "public"."users" where "id" = 42 limit 100'
  )
  eq(
    sql.select_where('mssql', { 'dbo', 'orders' }, {
      { column = 'note', value = "O'Reilly", numeric = false },
    }, 50),
    "select top (50) * from [dbo].[orders] where [note] = N'O''Reilly'"
  )
  eq(
    sql.select_where('oracle', { 'HR', 'EMPLOYEES' }, {
      { column = 'DEPT_ID', value = 10, numeric = true },
    }, 25),
    'select * from "HR"."EMPLOYEES" where "DEPT_ID" = 10 fetch first 25 rows only'
  )
end

return T
