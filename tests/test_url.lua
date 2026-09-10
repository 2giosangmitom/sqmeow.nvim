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

return T
