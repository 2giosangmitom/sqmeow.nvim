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
  local fields = url.parse('postgres://[::1]:5433/app')
  eq(fields.host, '[::1]')
  eq(fields.port, '5433')
end

T['parse']['reads a sqlite path in each of its spellings'] = function()
  eq(url.parse('sqlite:app.db').path, 'app.db')
  eq(url.parse('sqlite://app.db').path, 'app.db')
  eq(url.parse('sqlite:///var/app.db').path, '/var/app.db')
end

T['parse']['recognises the alternative scheme names'] = function()
  eq(url.parse('postgresql://host/db').dialect, 'postgres')
  eq(url.parse('mariadb://host/db').dialect, 'mysql')
  eq(url.parse('sqlite3:app.db').dialect, 'sqlite')
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
    url.build('postgres', { host = 'h', user = 'me', password = 'se#cret', database = 'd' })
  eq(built, 'postgres://me:se%23cret@h/d')
  eq(url.parse(built).password, 'se#cret')
end

T['build']['assumes localhost when the host is left empty'] = function()
  eq(url.build('mysql', { database = 'shop' }), 'mysql://localhost/shop')
end

T['build']['leaves out a port, a user and options that were not given'] = function()
  eq(url.build('postgres', { host = 'h', database = 'd' }), 'postgres://h/d')
end

T['build']['writes a sqlite path with no authority'] = function()
  eq(url.build('sqlite', { path = '/var/app.db' }), 'sqlite:/var/app.db')
end

T['build']['says what is missing rather than writing a url that cannot work'] = function()
  local built, err = url.build('sqlite', { path = '' })
  eq(built, nil)
  eq(err, 'a SQLite connection needs a file')
end

T['build']['refuses a database it does not know'] = function()
  local built, err = url.build('oracle', {})
  eq(built, nil)
  eq(err, 'there is no `oracle` database')
end

T['build']['round trips everything parse produces'] = function()
  for _, original in ipairs({
    'postgres://app:hunter2@db.internal:5432/shop?sslmode=require',
    'mysql://root@127.0.0.1/sqmeow',
    'postgres://[::1]:5433/app',
    'sqlite:app.db',
  }) do
    local fields = url.parse(original)
    eq(url.build(fields.dialect, fields), original)
  end
end

return T
