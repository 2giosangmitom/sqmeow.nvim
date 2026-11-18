--- Collect table structures for a whole schema or for a table's foreign-key neighborhood.
--- Only gathers metadata; renderers such as `sqmeow.core.mermaid` turn it into text.

local M = {}

--- Requests waiting for their completion event, by the request id the engine echoes.
---@type { conn_id: integer, request_id: integer, done: fun(payload: table) }[]
local waiting = {}

--- Run a waiter's continuation; a failing one must not strand the others.
---@param waiter { done: fun(payload: table) }
---@param payload table
local function settle(waiter, payload)
  local ok, err = xpcall(waiter.done, debug.traceback, payload)
  if not ok then
    require('sqmeow.core.utils').notify(
      ('a schema read callback failed: %s'):format(err),
      vim.log.levels.ERROR
    )
  end
end

--- Complete the waiter `payload` answers.
---@param payload table
local function deliver(payload)
  if not payload or payload.request_id == nil then
    return
  end
  for index, waiter in ipairs(waiting) do
    if waiter.request_id == payload.request_id and waiter.conn_id == payload.conn_id then
      table.remove(waiting, index)
      return settle(waiter, payload)
    end
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
    settle(waiter, { error = message })
  end
end

---@param payload table `structure:done`
function M.on_structure(payload)
  deliver(payload)
end

---@param payload table `relationships:done`
function M.on_relationships(payload)
  deliver(payload)
end

---@param payload table `schema:nodes`
function M.on_nodes(payload)
  deliver(payload)
end

--- Fail pending requests of a closed or lost connection.
---@param conn_id integer
function M.invalidate(conn_id)
  fail(conn_id, 'connection closed')
end

--- Fail every pending request; the engine that would answer them is gone.
---@param message string|nil
function M.reset(message)
  fail(nil, message or 'engine restarted')
end

--- Send `method` with a fresh request id and call `done` with the event that echoes it.
---@param method 'structure'|'relationships'|'introspect'
---@param args table
---@param done fun(payload: table)
local function request(method, args, done)
  local rpc = require('sqmeow.rpc.client')
  local waiter = { conn_id = args.conn_id, request_id = rpc.next_request_id(), done = done }
  args.request_id = waiter.request_id
  table.insert(waiting, waiter)
  local _, err = rpc.request(method, args)
  if err then
    for index, other in ipairs(waiting) do
      if other == waiter then
        table.remove(waiting, index)
        return settle(waiter, { error = err })
      end
    end
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
    if finished then
      return
    end
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

--- A key that keeps `a.b`.`c` and `a`.`b.c` apart.
---@param schema string
---@param relation string
---@return string
local function key(schema, relation)
  return schema .. '\0' .. relation
end

---@param conn_id integer
---@param path string[]
---@param done fun(nodes: table[]|nil, err: string|nil)
local function children(conn_id, path, done)
  request('introspect', { conn_id = conn_id, path = path }, function(payload)
    if payload.error then
      return done(nil, payload.error)
    end
    done(payload.nodes or {})
  end)
end

--- `schema`, or the connection's default schema when nil.
---@param conn_id integer
---@param schema string|nil
---@param done fun(schema: string|nil, err: string|nil)
local function resolve_schema(conn_id, schema, done)
  if schema then
    return done(schema)
  end
  children(conn_id, {}, function(nodes, err)
    if not nodes then
      return done(nil, err)
    end
    local server = false
    for _, node in ipairs(nodes) do
      if node.kind == 'schema' and node.is_default then
        return done(node.name)
      end
      server = server or node.kind == 'database'
    end
    -- A server connection lists databases, each opened as a connection of its own.
    done(
      nil,
      server and 'this connection is a server; read the schema from one of its databases'
        or 'no schema is the default; pass `schema`'
    )
  end)
end

--- The tables of `schema`, in the catalog's spelling.
---@param conn_id integer
---@param schema string
---@param done fun(tables: { schema: string, relation: string }[]|nil, err: string|nil)
local function schema_tables(conn_id, schema, done)
  children(conn_id, { schema, 'tables' }, function(nodes, err)
    if not nodes then
      return done(nil, err)
    end
    local tables = {}
    for _, node in ipairs(nodes) do
      if node.kind == 'table' then
        table.insert(tables, { schema = schema, relation = node.name })
      end
    end
    done(tables)
  end)
end

--- The table `relation` names in `tables`: an exact match, else the only case-insensitive one.
---@param tables { schema: string, relation: string }[]
---@param relation string
---@return { schema: string, relation: string }|nil
local function find_table(tables, relation)
  local folded = {}
  for _, tbl in ipairs(tables) do
    if tbl.relation == relation then
      return tbl
    end
    if tbl.relation:lower() == relation:lower() then
      table.insert(folded, tbl)
    end
  end
  return #folded == 1 and folded[1] or nil
end

--- `focal` and the tables within `hops` foreign keys of it, in either direction.
---@param conn_id integer
---@param focal { schema: string, relation: string }
---@param hops integer
---@param done fun(tables: { schema: string, relation: string }[]|nil, err: string|nil)
local function neighborhood(conn_id, focal, hops, done)
  local tables, seen = {}, {}
  local function add(schema, relation)
    if relation and not seen[key(schema, relation)] then
      seen[key(schema, relation)] = true
      table.insert(tables, { schema = schema, relation = relation })
    end
  end
  add(focal.schema, focal.relation)

  local expanded = 0
  local function hop(left)
    local frontier = vim.list_slice(tables, expanded + 1)
    expanded = #tables
    if left <= 0 or #frontier == 0 then
      return done(tables)
    end
    each(frontier, function(item, settled)
      local args = { conn_id = conn_id, schema = item.schema, relation = item.relation }
      request('relationships', args, function(payload)
        if payload.error then
          return settled(payload.error)
        end
        for _, rel in ipairs(payload.relationships or {}) do
          add(rel.source_schema or item.schema, rel.source_relation)
          add(rel.target_schema or item.schema, rel.target_relation)
        end
        settled(nil)
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
  each(tables, function(item, settled)
    local args = { conn_id = conn_id, schema = item.schema, relation = item.relation }
    request('structure', args, function(payload)
      if payload.error then
        return settled(payload.error)
      end
      item.columns = payload.columns or {}
      item.indexes = payload.indexes or {}
      item.foreign_keys = payload.foreign_keys or {}
      settled(nil)
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
  local hops = relation and math.max(0, math.floor(opts.hops or 1)) or nil

  local function finish(tables, list_err)
    if not tables then
      return callback(nil, list_err)
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

  resolve_schema(conn.id, opts.schema, function(schema, schema_err)
    if not schema then
      return callback(nil, schema_err)
    end
    schema_tables(conn.id, schema, function(tables, list_err)
      if not tables then
        return callback(nil, list_err)
      end
      if not relation then
        if #tables == 0 then
          return callback(nil, ('no tables found in %s'):format(schema))
        end
        return finish(tables)
      end
      -- The catalog decides whether the table exists and how it is spelled.
      local focal = find_table(tables, relation)
      if not focal then
        return callback(nil, ('table %s not found in %s'):format(relation, schema))
      end
      neighborhood(conn.id, focal, hops or 1, finish)
    end)
  end)
  return true
end

return M
