local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local sql = require('sqmeow.sql')

local T = MiniTest.new_set()

T['qualify'] = MiniTest.new_set()

T['qualify']['quotes each part for the dialect'] = function()
  eq(sql.qualify('postgres', { 'public', 'users' }), '"public"."users"')
  eq(sql.qualify('mysql', { 'shop', 'orders' }), '`shop`.`orders`')
end

T['qualify']['names a redis key by itself'] = function()
  eq(sql.qualify('redis', { 'db0', 'user:1' }), 'user:1')
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

T['read_key']['escapes a key so it stays one word'] = function()
  eq(sql.read_key('strings', 'a "b"\\\nc', 1), [[GET "a \"b\"\\\nc"]])
end

T['read_key']['has nothing for a group that is not a type'] = function()
  eq(sql.read_key('tables', 'users', 1), nil)
end

return T
