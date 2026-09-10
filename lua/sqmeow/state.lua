--- What the plugin knows about the engine's session.
---
--- The engine owns the real state: the pools, the result sets, the layouts. This mirrors only
--- what the interface needs to draw itself, and is rebuilt from events rather than assumed.

local M = {}

---@class sqmeow.Connection
---@field id integer
---@field name string
---@field url string
---@field dialect string|nil Known once the engine reports a successful connection.
---@field state 'connecting'|'connected'|'error'|'closed'
---@field error string|nil

---@class sqmeow.CallSummary
---@field call_id integer
---@field conn_id integer
---@field state 'executing'|'done'|'error'|'cancelled'
---@field rows integer|nil
---@field columns integer|nil
---@field affected integer|nil
---@field truncated boolean|nil
---@field page integer|nil
---@field pages integer|nil
---@field offset integer|nil
---@field elapsed_ms integer|nil
---@field error string|nil

---@type table<integer, sqmeow.Connection>
M.connections = {}

--- The connection queries run against.
---@type integer|nil
M.current = nil

--- The most recent result, which is what paging acts on.
---@type sqmeow.CallSummary|nil
M.call = nil

--- Finished queries, newest first.
---
--- Mirrors the engine's own history, which is what makes reopening one of them possible: the
--- engine still holds the rows, so the log only has to remember which call to ask for.
---@type sqmeow.CallSummary[]
M.calls = {}

local next_id = 0

--- Reserve a connection id.
---
--- Ids are the plugin's to hand out, not the engine's, so a connection can be named and shown in
--- the interface before the engine has finished opening it.
---@return integer
function M.next_connection_id()
  next_id = next_id + 1
  return next_id
end

--- Record a connection the plugin has asked the engine to open.
---
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
---
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

--- The connection queries run against.
---@return sqmeow.Connection|nil
function M.current_connection()
  return M.current and M.connections[M.current] or nil
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
---
--- Capped at the engine's own history size: remembering a call whose rows the engine has already
--- evicted would offer the user something that cannot be reopened.
---
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
  M.current = nil
  M.call = nil
  M.calls = {}
  next_id = 0
end

return M
