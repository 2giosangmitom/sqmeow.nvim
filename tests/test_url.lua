local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local url = require('sqmeow.url')
local config = require('sqmeow.config')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
    end,
  },
})

T['redact'] = MiniTest.new_set()

T['redact']['hides a password'] = function()
  eq(url.redact('postgres://app:hunter2@db.internal/app'), 'postgres://app:***@db.internal/app')
end

T['redact']['keeps everything that identifies the database'] = function()
  local masked = url.redact('postgres://app:hunter2@db.internal:5432/app?sslmode=require')
  eq(masked, 'postgres://app:***@db.internal:5432/app?sslmode=require')
end

T['redact']['leaves a url with no password alone'] = function()
  eq(url.redact('postgres://app@db.internal/app'), 'postgres://app@db.internal/app')
  eq(url.redact('sqlite://./app.db'), 'sqlite://./app.db')
  eq(url.redact('sqlite::memory:'), 'sqlite::memory:')
end

T['redact']['leaves an empty password alone'] = function()
  eq(url.redact('postgres://app:@db.internal/app'), 'postgres://app:@db.internal/app')
end

T['redact']['masks a password holding an at sign'] = function()
  -- The credentials end at the last `@` in the authority, not the first.
  eq(url.redact('mysql://root:p@ss:word@localhost/db'), 'mysql://root:***@localhost/db')
end

T['redact']['is not confused by an at sign in the query string'] = function()
  eq(
    url.redact('postgres://app:secret@host/db?user=a@b.com'),
    'postgres://app:***@host/db?user=a@b.com'
  )
end

T['redact']['leaves a url with no authority alone'] = function()
  eq(url.redact('not a url'), 'not a url')
  eq(url.redact(''), '')
end

T['display'] = MiniTest.new_set()

T['display']['redacts by default'] = function()
  eq(url.display('postgres://app:secret@host/db'), 'postgres://app:***@host/db')
end

T['display']['shows the password when the user turns redaction off'] = function()
  config.apply({ redact_urls = false })
  eq(url.display('postgres://app:secret@host/db'), 'postgres://app:secret@host/db')
end

T['label'] = MiniTest.new_set()

T['label']['names a sqlite file by its basename'] = function()
  eq(url.label('sqlite://./data/app.db'), 'app.db')
  eq(url.label('sqlite:///var/lib/app.sqlite3'), 'app.sqlite3')
end

T['label']['names an in-memory database'] = function()
  eq(url.label('sqlite::memory:'), 'memory')
end

T['label']['ignores sqlite query parameters'] = function()
  eq(url.label('sqlite://./app.db?mode=rwc'), 'app.db')
end

T['label']['names a server database by database and host'] = function()
  eq(url.label('postgres://app:secret@db.internal:5432/orders'), 'orders@db.internal')
  eq(url.label('mysql://root@localhost/shop'), 'shop@localhost')
end

T['label']['falls back to the database name with no credentials'] = function()
  eq(url.label('postgres://localhost/orders'), 'orders')
end

T['parse'] = MiniTest.new_set()

T['parse']['takes a server url apart'] = function()
  eq(url.parse('postgres://app:hunter2@db.internal:5432/shop?sslmode=require'), {
    dialect = 'postgres',
    host = 'db.internal',
    port = '5432',
    user = 'app',
    password = 'hunter2',
    database = 'shop',
    options = 'sslmode=require',
  })
end

T['parse']['leaves out what the url does not say'] = function()
  eq(url.parse('mysql://root@127.0.0.1/sqmeow'), {
    dialect = 'mysql',
    host = '127.0.0.1',
    port = '',
    user = 'root',
    password = '',
    database = 'sqmeow',
    options = '',
  })
end

T['parse']['decodes an escaped password'] = function()
  eq(url.parse('postgres://me:se%23cret@host/db').password, 'se#cret')
end

T['parse']['finds the port past an ipv6 host'] = function()
  local fields = assert(url.parse('postgres://[::1]:5433/app'))
  eq(fields.host, '[::1]')
  eq(fields.port, '5433')
end

T['parse']['reads a sqlite path in each of its spellings'] = function()
  eq(url.parse('sqlite:app.db').path, 'app.db')
  eq(url.parse('sqlite://app.db').path, 'app.db')
  eq(url.parse('sqlite:///var/app.db').path, '/var/app.db')
  eq(url.parse('duckdb:///var/app.duckdb').path, '/var/app.duckdb')
  eq(url.parse('duckdb:app.duckdb').dialect, 'duckdb')
end

T['parse']['recognises the alternative scheme names'] = function()
  eq(url.parse('postgresql://host/db').dialect, 'postgres')
  eq(url.parse('mariadb://host/db').dialect, 'mysql')
  eq(url.parse('sqlite3:app.db').dialect, 'sqlite')
end

T['parse']['reads tls off a redis scheme'] = function()
  eq(url.parse('rediss://cache.internal/0').tls, 'yes')
  eq(url.parse('redis://cache.internal/0').tls, 'no')
  eq(url.parse('valkeys://cache.internal').dialect, 'redis')
  -- Only Redis has the field, so the other dialects' fields stay what they were.
  eq(url.parse('postgres://host/db').tls, nil)
end

T['parse']['refuses a scheme that is not a database'] = function()
  eq(url.parse('https://example.com/db'), nil)
  eq(url.parse('not a url'), nil)
end

T['build'] = MiniTest.new_set()

T['build']['writes the fields back as a url'] = function()
  eq(
    url.build('postgres', {
      host = 'db.internal',
      port = '5432',
      user = 'app',
      password = 'hunter2',
      database = 'shop',
      options = 'sslmode=require',
    }),
    'postgres://app:hunter2@db.internal:5432/shop?sslmode=require'
  )
end

T['build']['escapes a password so the url still parses'] = function()
  local built =
    assert(url.build('postgres', { host = 'h', user = 'me', password = 'se#cret', database = 'd' }))
  eq(built, 'postgres://me:se%23cret@h/d')
  eq(url.parse(built).password, 'se#cret')
end

T['build']['assumes localhost when the host is left empty'] = function()
  eq(url.build('mysql', { database = 'shop' }), 'mysql://localhost/shop')
end

T['build']['leaves out a port, a user and options that were not given'] = function()
  eq(url.build('postgres', { host = 'h', database = 'd' }), 'postgres://h/d')
end

T['build']['leaves the database out when it was not given'] = function()
  -- Which is how a connection to every database on the server is asked for.
  eq(url.build('postgres', { host = 'h', user = 'me' }), 'postgres://me@h/')
  eq(url.parse('postgres://me@h/').database, '')
end

T['build']['writes redis tls as the rediss scheme'] = function()
  eq(url.build('redis', { host = 'h', database = '0', tls = 'yes' }), 'rediss://h/0')
  eq(url.build('redis', { host = 'h', database = '0', tls = 'no' }), 'redis://h/0')
end

T['build']['keeps a password that has no user'] = function()
  eq(url.build('redis', { host = 'h', password = 's#cret' }), 'redis://:s%23cret@h/')
end

T['build']['writes a sqlite path with no authority'] = function()
  eq(url.build('sqlite', { path = '/var/app.db' }), 'sqlite:/var/app.db')
  eq(url.build('duckdb', { path = 'app.duckdb' }), 'duckdb:app.duckdb')
end

T['build']['says what is missing rather than writing a url that cannot work'] = function()
  local built, err = url.build('sqlite', { path = '' })
  eq(built, nil)
  eq(err, 'a SQLite connection needs a file')
end

T['build']['refuses a database it does not know'] = function()
  local built, err = url.build('mssql', {})
  eq(built, nil)
  eq(err, 'there is no `mssql` database')
end

T['build']['round trips everything parse produces'] = function()
  for _, original in ipairs({
    'postgres://app:hunter2@db.internal:5432/shop?sslmode=require',
    'mysql://root@127.0.0.1/sqmeow',
    'postgres://[::1]:5433/app',
    'sqlite:app.db',
    'rediss://:secret@cache.internal:6380/2',
  }) do
    local fields = assert(url.parse(original))
    eq(url.build(fields.dialect, fields), original)
  end
end

T['parse']['reads srv off a mongodb scheme'] = function()
  eq(url.parse('mongodb+srv://cluster.example.net/app').srv, 'yes')
  eq(url.parse('mongodb+srv://cluster.example.net/app').dialect, 'mongodb')
  eq(url.parse('mongodb://h:27017/app').srv, 'no')
end

T['build']['writes mongodb srv as the mongodb+srv scheme'] = function()
  eq(
    url.build('mongodb', { host = 'cluster.example.net', database = 'app', srv = 'yes' }),
    'mongodb+srv://cluster.example.net/app'
  )
  eq(
    url.build(
      'mongodb',
      { host = 'h', port = '27017', database = 'app', srv = 'no', options = 'authSource=admin' }
    ),
    'mongodb://h:27017/app?authSource=admin'
  )
end

T['build']['refuses a port on a mongodb srv address'] = function()
  local built, err =
    url.build('mongodb', { host = 'cluster.example.net', port = '27017', srv = 'yes' })
  eq(built, nil)
  eq(err, 'a MongoDB SRV address takes no port')
end

T['build']['writes a surrealdb namespace and database as its path'] = function()
  eq(
    url.build('surrealdb', { host = 'h', namespace = 'shop', database = 'main', tls = 'yes' }),
    'surrealdbs://h/shop/main'
  )
  eq(url.build('surrealdb', { host = 'h', namespace = 'shop' }), 'surrealdb://h/shop')
  eq(url.build('surrealdb', { host = 'h', database = 'main' }), 'surrealdb://h/main/main')
  local fields = assert(url.parse('surrealdbs://root:pw@h:8000/shop/main?auth=database'))
  eq(
    { fields.dialect, fields.namespace, fields.database, fields.tls, fields.options },
    { 'surrealdb', 'shop', 'main', 'yes', 'auth=database' }
  )
  eq(url.parse('surrealdb://h/shop').database, '')
end

T['build']['writes clickhouse tls as the clickhouses scheme'] = function()
  eq(
    url.build('clickhouse', { host = 'h', database = 'logs', tls = 'yes' }),
    'clickhouses://h/logs'
  )
  eq(url.build('clickhouse', { host = 'h', tls = 'no' }), 'clickhouse://h/')
  eq(url.parse('clickhouses://u:p@h:8443/logs').tls, 'yes')
  eq(url.parse('clickhouses://u:p@h:8443/logs').dialect, 'clickhouse')
end

T['build']['writes oracle tls as the oracletcps scheme'] = function()
  eq(
    url.build('oracle', { host = 'h', database = 'XEPDB1', user = 'u', tls = 'yes' }),
    'oracletcps://u@h/XEPDB1'
  )
  eq(
    url.build('oracle', { host = 'h', user = 'scott', password = 'tiger', database = 'XE' }),
    'oracle://scott:tiger@h/XE'
  )
  local fields = assert(url.parse('oracletcps://scott:tiger@h:2484/XE'))
  eq(
    { fields.dialect, fields.database, fields.user, fields.tls },
    { 'oracle', 'XE', 'scott', 'yes' }
  )
  eq(url.parse('oracledb://scott:tiger@h/XE').dialect, 'oracle')
end

T['build']['writes a scylla keyspace where a database would be'] = function()
  eq(url.build('scylla', { host = 'h', database = 'shop' }), 'scylla://h/shop')
  eq(url.parse('cassandra://u:p@h:9042/shop').dialect, 'scylla')
end

T['parse']['keeps a template whole in the field it sits in'] = function()
  local fields =
    assert(url.parse('postgres://app:{{ exec "pass show a/b:c@d" }}@db.internal:5432/shop'))
  eq(fields.user, 'app')
  eq(fields.password, '{{ exec "pass show a/b:c@d" }}')
  eq(fields.host, 'db.internal')
  eq(fields.database, 'shop')
end

T['build']['writes a template out as it is, and the text around it encoded'] = function()
  eq(
    url.build(
      'postgres',
      { host = 'h', user = 'a b', password = 'x{{ env "P W" }}y', database = 'd' }
    ),
    'postgres://a%20b:x{{ env "P W" }}y@h/d'
  )
end

T['parse']['leaves a url naming several hosts to be edited whole'] = function()
  eq(url.parse('redis+cluster://a:7000,b:7001'), nil)
  eq(require('sqmeow.dialects').of_url('redis+sentinel://s:26379/mymaster/0'), 'redis')
end

return T
