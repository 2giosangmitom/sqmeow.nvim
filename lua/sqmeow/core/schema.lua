--- Collect table structures for a whole schema or for a table's foreign-key neighborhood.
--- Only gathers metadata; renderers such as `sqmeow.core.mermaid` turn it into text.

local M = {}

--- Requests waiting for their completion event.
---@type { kind: string, conn_id: integer|nil, match: fun(payload: table): boolean, done: fun(payload: table) }[]
local waiting = {}

--- Complete the waiters `payload` answers.
---@param kind string
---@param payload table
local function deliver(kind, payload)
  local ready = {}
  for index = #waiting, 1, -1 do
    local waiter = waiting[index]
    if waiter.kind == kind and waiter.match(payload) then
      table.remove(waiting, index)
      table.insert(ready, 1, waiter)
    end
  end
  for _, waiter in ipairs(ready) do
    waiter.done(payload)
  end
end

--- Fail the waiters of one connection, or every waiter when `conn_id` is nil.
---@param conn_id integer|nil
---@param message string
local function fail(conn_id, message)
  local kept, failed = {}, {}
  for _, waiter in ipairs(waiting) do
    table.insert((conn_id == nil or waiter.conn_id == conn_id) and failed or kept, waiter)
  end
  waiting = kept
  for _, waiter in ipairs(failed) do
    waiter.done({ error = message })
  end
end

---@param payload table `structure:done`
function M.on_structure(payload)
  deliver('structure', payload)
end

---@param payload table `relationships:done`
function M.on_relationships(payload)
  deliver('relationships', payload)
end

---@param payload table `schema:nodes`
function M.on_nodes(payload)
  deliver('introspect', payload)
end

--- Fail pending requests of a closed or lost connection.
---@param conn_id integer
function M.invalidate(conn_id)
  fail(conn_id, 'connection closed')
end

--- Fail every pending request; the engine restarted.
function M.reset()
  fail(nil, 'engine restarted')
end

--- Send `method` and call `done` with the event that completes it.
---@param method 'structure'|'relationships'|'introspect'
---@param args table
---@param match fun(payload: table): boolean
---@param done fun(payload: table)
local function request(method, args, match, done)
  local waiter = { kind = method, conn_id = args.conn_id, match = match, done = done }
  table.insert(waiting, waiter)
  local _, err = require('sqmeow.rpc.client').request(method, args)
  if err then
    for index, other in ipairs(waiting) do
      if other == waiter then
        table.remove(waiting, index)
        break
      end
    end
    done({ error = err })
  end
end

--- Run `start(item, settle)` for every item; `done` gets the first error or nil once all settle.
---@param items table[]
---@param start fun(item: table, settle: fun(err: string|nil))
---@param done fun(err: string|nil)
local function each(items, start, done)
  local remaining, finished = #items, false
  if remaining == 0 then
    return done(nil)
  end
  for _, item in ipairs(items) do
    start(item, function(err)
      if finished then
        return
      end
      remaining = remaining - 1
      if err or remaining == 0 then
        finished = true
        done(err)
      end
    end)
  end
end

---@param conn_id integer
---@param path string[]
---@param done fun(nodes: table[]|nil, err: string|nil)
local function children(conn_id, path, done)
  request('introspect', { conn_id = conn_id, path = path }, function(payload)
    return payload.conn_id == conn_id and vim.deep_equal(payload.path or {}, path)
  end, function(payload)
    if payload.error then
      return done(nil, payload.error)
    end
    done(payload.nodes or {})
  end)
end

--- Every table of `schema`, or of the default schema when `schema` is nil.
---@param conn_id integer
---@param schema string|nil
---@param done fun(tables: { schema: string, relation: string }[]|nil, err: string|nil)
local function schema_tables(conn_id, schema, done)
  local function list(name)
    children(conn_id, { name, 'tables' }, function(nodes, err)
      if not nodes then
        return done(nil, err)
      end
      local tables = {}
      for _, node in ipairs(nodes) do
        if node.kind == 'table' then
          table.insert(tables, { schema = name, relation = node.name })
        end
      end
      done(tables)
    end)
  end

  if schema then
    return list(schema)
  end
  children(conn_id, {}, function(nodes, err)
    if not nodes then
      return done(nil, err)
    end
    for _, node in ipairs(nodes) do
      if node.kind == 'schema' and node.is_default then
        return list(node.name)
      end
    end
    done(nil, 'no schema is the default; pass `schema`')
  end)
end

--- `relation` and the tables within `hops` foreign keys of it, in either direction.
---@param conn_id integer
---@param schema string
---@param relation string
---@param hops integer
---@param done fun(tables: { schema: string, relation: string }[]|nil, err: string|nil)
local function neighborhood(conn_id, schema, relation, hops, done)
  local tables, seen = {}, {}
  local function add(table_schema, name)
    local key = table_schema .. '.' .. name
    if not seen[key] then
      seen[key] = true
      table.insert(tables, { schema = table_schema, relation = name })
    end
  end
  add(schema, relation)

  local expanded = 0
  local function hop(left)
    local frontier = vim.list_slice(tables, expanded + 1)
    expanded = #tables
    if left == 0 or #frontier == 0 then
      return done(tables)
    end
    each(frontier, function(item, settle)
      local id = require('sqmeow.rpc.client').next_request_id()
      local args =
        { conn_id = conn_id, schema = item.schema, relation = item.relation, request_id = id }
      request('relationships', args, function(payload)
        return payload.request_id == id
      end, function(payload)
        if payload.error then
          return settle(payload.error)
        end
        -- An empty schema or differently cased name resolves to the catalog's spelling.
        item.schema = (payload.resolved_schema or '') ~= '' and payload.resolved_schema
          or item.schema
        item.relation = (payload.resolved_relation or '') ~= '' and payload.resolved_relation
          or item.relation
        seen[item.schema .. '.' .. item.relation] = true
        for _, rel in ipairs(payload.relationships or {}) do
          add(rel.source_schema or item.schema, rel.source_relation)
          add(rel.target_schema or item.schema, rel.target_relation)
        end
        settle(nil)
      end)
    end, function(err)
      if err then
        return done(nil, err)
      end
      hop(left - 1)
    end)
  end
  hop(hops)
end

---@param conn_id integer
---@param tables { schema: string, relation: string }[]
---@param done fun(tables: sqmeow.SchemaTable[]|nil, err: string|nil)
local function structures(conn_id, tables, done)
  each(tables, function(item, settle)
    local args = { conn_id = conn_id, schema = item.schema, relation = item.relation }
    request('structure', args, function(payload)
      return payload.conn_id == conn_id
        and payload.schema == args.schema
        and payload.relation == args.relation
    end, function(payload)
      if payload.error then
        return settle(payload.error)
      end
      item.columns = payload.columns or {}
      item.indexes = payload.indexes or {}
      item.foreign_keys = payload.foreign_keys or {}
      settle(nil)
    end)
  end, function(err)
    if err then
      return done(nil, err)
    end
    done(tables)
  end)
end

---@param opts sqmeow.SchemaOpts
---@return sqmeow.Connection|nil
---@return string|nil err
local function resolve_connection(opts)
  local state = require('sqmeow.core.state')
  local conn, err
  if opts.conn_id then
    conn = state.connections[opts.conn_id]
  elseif opts.connection and opts.connection ~= '' then
    conn = state.connection_by_name(opts.connection)
    err = ('connection %s is not open'):format(opts.connection)
  else
    conn, err = require('sqmeow.api.connection').target(0)
  end
  if not conn or conn.state ~= 'connected' then
    return nil, err or 'reading a schema needs an open connection'
  end
  if conn.dialect == 'redis' or conn.dialect == 'mongodb' then
    return nil, ('%s has no relational schema'):format(conn.dialect)
  end
  return conn
end

--- Collect table structures; see `sqmeow.api.view.schema()`.
---@param opts sqmeow.SchemaOpts|nil
---@param callback fun(schema: sqmeow.Schema|nil, err: string|nil)
---@return boolean started
---@return string|nil err
function M.collect(opts, callback)
  opts = opts or {}
  local conn, err = resolve_connection(opts)
  if not conn then
    return false, err
  end
  require('sqmeow.rpc.events').ensure()

  local relation = (opts.relation or '') ~= '' and opts.relation or nil
  local hops = relation and math.max(1, opts.hops or 1) or nil

  local function collected(tables, list_err)
    if not tables then
      return callback(nil, list_err)
    end
    if #tables == 0 then
      return callback(nil, 'no tables found')
    end
    structures(conn.id, tables, function(found, struct_err)
      if not found then
        return callback(nil, struct_err)
      end
      callback({
        conn_id = conn.id,
        connection = conn.name,
        dialect = conn.dialect,
        schema = found[1].schema,
        relation = relation and found[1].relation,
        hops = hops,
        tables = found,
      })
    end)
  end

  if relation then
    neighborhood(conn.id, opts.schema or '', relation, hops or 1, collected)
  else
    schema_tables(conn.id, opts.schema, collected)
  end
  return true
end

return M
