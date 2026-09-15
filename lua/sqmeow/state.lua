--- What the plugin knows about the engine's session.

local M = {}

---@class sqmeow.Connection
---@field id integer
---@field name string
---@field url string
---@field dialect string|nil Known once the engine reports a successful connection.
---@field state 'connecting'|'connected'|'error'|'closed'
---@field error string|nil
---@field parent integer|nil For one database of a cluster, the connection that listed it.
---@field database string|nil For one database of a cluster, which one.
---@field current_database string|nil For MongoDB, the database commands run on.
---@field read_only boolean|nil Runs only statements that read.

---@class sqmeow.CallSummary
---@field call_id integer|nil Absent for an entry from the log that has no rows to read.
---@field conn_id integer|nil Absent when the database it ran on is not open.
---@field state 'executing'|'done'|'error'|'cancelled'
---@field rows integer|nil How many rows the engine is holding.
---@field view_rows integer|nil How many rows the current view holds.
---@field columns sqmeow.ResultColumn[]|nil One per column, in order.
---@field affected integer|nil
---@field truncated boolean|nil
---@field elapsed_ms integer|nil
---@field error string|nil
---@field statement string|nil The SQL as submitted.
---@field sql string|nil The statement the rows came from, as the engine reports it.
---@field source sqmeow.ResultSource|nil Where the rows are stored, when they trace back to tables or a key.
---@field history boolean|nil False for a call that stays out of the query log.
---@field archive string|nil Where the engine was asked to save the rows for the log.
---@field connection string|nil For a result shown from the log, the database it ran on.
---@field dialect string|nil For a result shown from the log, what that database speaks.
---@field ran_at integer|nil For a result shown from the log, when it ran, in seconds since the epoch.
---@field results table[]|nil Each statement's result, when several statements returned rows.
---@field appended integer|nil How many rows applied inserts returned that the query left out.

--- One column of a result, as the engine describes it.
---@class sqmeow.ResultSource Where a result's rows are stored.
---@field kind string What the relation is, as the engine names it.
---@field name string
---@field insertable boolean|nil Present when rows can be added, which a join does not allow.
---@field tables { schema: string|nil, name: string, columns: integer[] }[]|nil The tables of a SQL result, each with its zero-based columns.

---@class sqmeow.ResultColumn
---@field name string
---@field type_name string
---@field class string One of the type classes the icons are keyed by.
---@field key string|nil `primary_key` or `foreign_key`, absent when the column is neither.
---@field editable boolean|nil Present when the column can be written back to where it is stored.
---@field widest integer Display columns taken by the widest value, `NULL`s excluded.
---@field nulls boolean Whether any value in the column is `NULL`.
---@field numeric boolean Whether every value is a number.

---@type table<integer, sqmeow.Connection>
M.connections = {}

--- Why each connection last failed to open, by name, until it is tried again.
---@type table<string, string>
M.failures = {}

--- The connection queries run against.
---@type integer|nil
M.current = nil

--- The most recent result.
---@type sqmeow.CallSummary|nil
M.call = nil

--- Finished queries, newest first.
---@type sqmeow.CallSummary[]
M.calls = {}

local next_id = 0

--- Reserve a connection id.
---@return integer
function M.next_connection_id()
  next_id = next_id + 1
  return next_id
end

--- Record a connection the plugin has asked the engine to open.
---@param connection sqmeow.Connection
---@return sqmeow.Connection
function M.add_connection(connection)
  M.connections[connection.id] = connection
  if not M.current then
    M.current = connection.id
  end
  return connection
end

--- Forget a connection, and pick another as current if it was the current one.
---@param id integer
function M.remove_connection(id)
  M.connections[id] = nil
  if M.current ~= id then
    return
  end

  M.current = nil
  for other in pairs(M.connections) do
    M.current = other
    break
  end
end

--- The active connection.
---@return sqmeow.Connection|nil
function M.current_connection()
  return M.current and M.connections[M.current] or nil
end

--- An open connection by the name the interface calls it.
---@param name string
---@return sqmeow.Connection|nil
function M.connection_by_name(name)
  for _, connection in pairs(M.connections) do
    if connection.name == name then
      return connection
    end
  end
  return nil
end

--- The connection opened for one database of a cluster, if it is open.
---@param parent integer
---@param database string
---@return sqmeow.Connection|nil
function M.child_connection(parent, database)
  for _, connection in pairs(M.connections) do
    if connection.parent == parent and connection.database == database then
      return connection
    end
  end
  return nil
end

--- Every connection, ordered by id so the interface does not reshuffle between draws.
---@return sqmeow.Connection[]
function M.connection_list()
  local list = vim.tbl_values(M.connections)
  table.sort(list, function(left, right)
    return left.id < right.id
  end)
  return list
end

--- Record a finished query.
---@param summary sqmeow.CallSummary
function M.record_call(summary)
  table.insert(M.calls, 1, vim.deepcopy(summary))

  local limit = require('sqmeow.config').get().query.history_size
  while #M.calls > limit do
    table.remove(M.calls)
  end
end

--- Forget everything. Used when the engine restarts, since its session went with it.
function M.reset()
  M.connections = {}
  M.failures = {}
  M.current = nil
  M.call = nil
  M.calls = {}
  next_id = 0
end

--- How a winbar names a connection.
---@param connection { name: string, dialect?: string, database?: string, current_database?: string, read_only?: boolean }
---@return string
function M.label(connection)
  local name = connection.name
  if connection.current_database and connection.current_database ~= connection.database then
    name = ('%s › %s'):format(name, connection.current_database)
  end
  local kind = connection.dialect or '?'
  if connection.read_only then
    kind = kind .. ', read-only'
  end
  return ('%s (%s)'):format(name, kind)
end

return M
