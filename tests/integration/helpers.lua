-- Blocking helpers the Node suite calls through `nvim_exec_lua`, as `require('integration')`.
--
-- Connections and queries go through the public API (`sqmeow.api.connection`,
-- `sqmeow.api.query`), the way the editor drives them; metadata, edits and cancellation go
-- through the RPC client the plugin itself uses. Every engine event is recorded here, so a case
-- can wait for the one it caused. Everything returned is plain data, so it survives msgpack.

local rpc = require('sqmeow.rpc.client')

local M = {}

--- Events by name, oldest first.
---@type table<string, table[]>
M.events = {}
--- The latest `call:state` per call id.
---@type table<integer, table>
M.calls = {}
--- Every `conn:state` per connection id, oldest first.
---@type table<integer, table[]>
M.connections = {}
--- What the plugin told the user.
---@type { message: string, level: integer|nil }[]
M.notifications = {}

local DEFAULT_TIMEOUT = 30000
-- Rows read back per result. The cases never hold more than this.
local ROW_LIMIT = 10000
-- Rows read back cell by cell, with each cell's type.
local CELL_LIMIT = 50

for _, name in ipairs({
  'conn:state',
  'call:state',
  'call:view',
  'schema:nodes',
  'structure:done',
  'relationships:done',
  'routine:done',
  'apply:done',
  'export:done',
}) do
  M.events[name] = {}
  rpc.on(name, function(payload)
    table.insert(M.events[name], payload)
    if name == 'call:state' and payload.call_id then
      M.calls[payload.call_id] = payload
    elseif name == 'conn:state' and payload.id then
      M.connections[payload.id] = M.connections[payload.id] or {}
      table.insert(M.connections[payload.id], payload)
    end
  end)
end

-- The plugin reports through vim.notify; keep it for assertions instead of the message area.
vim.notify = function(message, level)
  table.insert(M.notifications, { message = tostring(message), level = level })
end

--- Wait for `condition`, failing with `what` after `timeout` milliseconds.
---@param what string
---@param condition fun(): any
---@param timeout integer|nil
function M.wait(what, condition, timeout)
  if not vim.wait(timeout or DEFAULT_TIMEOUT, condition, 5) then
    error('timed out waiting for ' .. what, 0)
  end
end

--- Pause for `ms` milliseconds while the event loop keeps running.
---@param ms integer
function M.sleep(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

local next_request = 0
local function request_id()
  next_request = next_request + 1
  -- Clear of the ids the plugin hands out itself.
  return 1000000 + next_request
end

--- Call an engine method and answer `{ ok, value, error }` instead of raising.
---@param method string
---@param args table|nil
---@return table
function M.request(method, args)
  local value, err = rpc.request(method, args or vim.empty_dict())
  if err ~= nil then
    return { ok = false, error = err }
  end
  return { ok = true, value = value }
end

--- Change engine settings (`max_rows`, `timeout_ms`, `history_size`), answering what applied.
---@param options table
---@return table
function M.configure(options)
  local config = require('sqmeow.config').get()
  config.query = vim.tbl_extend('force', config.query, options)
  return rpc.configure() or {}
end

--- Open a connection through `sqmeow.api.connection.connect` and wait for it to settle.
---@param url string
---@param opts table|nil `name`, `database`, `read_only`, `timeout`.
---@return table connection `id`, `state`, `dialect`, `error`, `notice`, `current_database`.
function M.connect(url, opts)
  opts = opts or {}
  local timeout = opts.timeout
  opts.timeout = nil
  local id, err = require('sqmeow.api.connection').connect(url, opts)
  if not id then
    return { state = 'refused', error = err }
  end
  M.wait('connection ' .. id .. ' to settle', function()
    local seen = M.connections[id]
    return seen and seen[#seen].state ~= 'connecting'
  end, timeout)
  local seen = M.connections[id]
  local last = seen[#seen]
  local notice
  for _, payload in ipairs(seen) do
    notice = payload.notice or notice
  end
  return {
    id = id,
    state = last.state,
    dialect = last.dialect,
    error = last.error,
    notice = notice,
    current_database = last.current_database,
  }
end

--- Close a connection.
---@param id integer|nil Every open connection when nil.
function M.disconnect(id)
  local api = require('sqmeow.api.connection')
  if id then
    return api.disconnect(id)
  end
  for _, connection in ipairs(api.connections()) do
    api.disconnect(connection.id)
  end
end

--- Submit SQL through `sqmeow.api.query.execute` without waiting.
---@param sql string
---@param opts table `conn_id`, and anything else `execute` takes.
---@return table submitted `call_id`, or `error` when it was refused before running.
function M.execute(sql, opts)
  opts = vim.tbl_extend('keep', opts or {}, { confirmed = true, history = false })
  local call_id, err = require('sqmeow.api.query').execute(sql, opts)
  if not call_id then
    return { error = err or 'refused' }
  end
  return { call_id = call_id }
end

--- Each row of a held result, as the grid pages them.
local function page(call_id)
  local reply = M.request('rows', { call_id = call_id, offset = 0, limit = ROW_LIMIT })
  return reply.ok and reply.value.rows or {}
end

--- The first rows of a held result cell by cell, each `{ type, value }`, `value` nil for NULL.
local function cells(call_id, count)
  local out = {}
  for row = 0, math.min(count, CELL_LIMIT) - 1 do
    local reply = M.request('row', { call_id = call_id, row = row })
    if not reply.ok then
      break
    end
    local line = {}
    for index, cell in ipairs(reply.value) do
      line[index] = {
        name = cell.name,
        type = cell.type_name,
        value = cell.is_null and vim.NIL or cell.value,
      }
    end
    out[#out + 1] = line
  end
  return out
end

--- A call summary with its rows read back. `count` is the row count, `rows` the values.
local function describe(summary)
  local out = vim.deepcopy(summary)
  out.count = summary.rows
  out.rows = {}
  out.cells = {}
  if summary.state == 'done' and summary.call_id then
    out.rows = page(summary.call_id)
    out.cells = cells(summary.call_id, summary.rows or 0)
  end
  if summary.results then
    out.results = {}
    for index, entry in ipairs(summary.results) do
      out.results[index] = describe(entry)
    end
  end
  return out
end

--- Wait for a submitted call to finish and answer it with its rows.
---@param call_id integer
---@param timeout integer|nil
---@return table
function M.wait_call(call_id, timeout)
  M.wait('call ' .. call_id .. ' to finish', function()
    local call = M.calls[call_id]
    return call and call.state ~= 'executing'
  end, timeout)
  return describe(M.calls[call_id])
end

--- Run SQL and wait for it. Refusals come back as `{ state = 'refused', error }`.
---@param sql string
---@param opts table `conn_id`, `timeout`, and anything else `execute` takes.
---@return table
function M.run(sql, opts)
  opts = vim.deepcopy(opts or {})
  local timeout = opts.timeout
  opts.timeout = nil
  local submitted = M.execute(sql, opts)
  if not submitted.call_id then
    return { state = 'refused', error = submitted.error }
  end
  return M.wait_call(submitted.call_id, timeout)
end

--- Whether a call is still running.
---@param call_id integer
---@return boolean
function M.running(call_id)
  local call = M.calls[call_id]
  return call == nil or call.state == 'executing'
end

--- Ask the engine to cancel a call or an apply by its call id.
---@param call_id integer
---@return table
function M.cancel(call_id)
  return M.request('cancel', { call_id = call_id })
end

--- Plan staged changes to a held result. `changes` is `{ updates, deletes, inserts }` as
--- `sqmeow.ui.edit` sends them.
---@return table `{ ok, value = statements }` or `{ ok = false, error }`.
function M.plan(call_id, changes)
  return M.request('plan', { call_id = call_id, changes = changes })
end

--- Start an apply and answer a handle to wait on, or `{ error }` when it was refused.
---@return table
function M.apply_start(conn_id, call_id, statements)
  local before = #M.events['apply:done']
  local reply =
    M.request('apply', { conn_id = conn_id, call_id = call_id, statements = statements })
  if not reply.ok then
    return { error = reply.error }
  end
  return { conn_id = conn_id, after = before }
end

--- Wait for the apply a handle names to finish, answering its `apply:done` payload.
---@return table
function M.apply_wait(handle, timeout)
  if handle.error then
    return { refused = true, error = handle.error }
  end
  local found
  M.wait('the apply to finish', function()
    local done = M.events['apply:done']
    for index = handle.after + 1, #done do
      if done[index].conn_id == handle.conn_id then
        found = done[index]
        handle.after = index
        return true
      end
    end
  end, timeout)
  return found
end

--- Apply statements to a connection and wait for the outcome.
---@return table `apply:done` payload, `error` set when it failed.
function M.apply(conn_id, call_id, statements, timeout)
  return M.apply_wait(M.apply_start(conn_id, call_id, statements), timeout)
end

--- Plan staged changes to a held result and apply them.
---@return table `{ planned, error }`
function M.edit(conn_id, call_id, changes, timeout)
  local planned = M.plan(call_id, changes)
  if not planned.ok then
    return { stage = 'plan', error = planned.error }
  end
  local done = M.apply(conn_id, call_id, planned.value, timeout)
  return { stage = 'apply', statements = planned.value, error = done.error }
end

--- Send a request that reports through `event` tagged with a request id, and wait for it.
local function tagged(method, event, args, timeout)
  args.request_id = args.request_id or request_id()
  local reply = M.request(method, args)
  if not reply.ok then
    return { refused = true, error = reply.error }
  end
  local found
  M.wait(event .. ' for request ' .. args.request_id, function()
    for _, payload in ipairs(M.events[event]) do
      if payload.request_id == args.request_id then
        found = payload
        return true
      end
    end
  end, timeout)
  return found
end

--- One level of the schema tree: `path` is `{}`, `{ schema }`, `{ schema, group }` or
--- `{ schema, group, relation }`.
function M.introspect(conn_id, path, timeout)
  return tagged('introspect', 'schema:nodes', { conn_id = conn_id, path = path or {} }, timeout)
end

--- A relation's columns, indexes and details.
function M.structure(conn_id, schema, relation, timeout)
  return tagged(
    'structure',
    'structure:done',
    { conn_id = conn_id, schema = schema or '', relation = relation },
    timeout
  )
end

--- The foreign keys into and out of a relation.
function M.relationships(conn_id, schema, relation, timeout)
  return tagged(
    'relationships',
    'relationships:done',
    { conn_id = conn_id, schema = schema or '', relation = relation },
    timeout
  )
end

--- A routine's definition.
function M.routine_source(conn_id, schema, name, kind, timeout)
  return tagged(
    'routine_source',
    'routine:done',
    { conn_id = conn_id, schema = schema, name = name, kind = kind },
    timeout
  )
end

--- The schema a connection opens on: the one introspection marks default, else the first.
function M.default_schema(conn_id, timeout)
  local top = M.introspect(conn_id, {}, timeout)
  if top.error then
    return nil
  end
  local first
  for _, node in ipairs(top.nodes or {}) do
    if node.default or node.is_default then
      return node.name
    end
    if node.kind == 'schema' or node.kind == 'database' then
      first = first or node.name
    end
  end
  return first
end

--- Notifications since `from` (1-based index into the list), as text.
function M.messages(from)
  local out = {}
  for index = from or 1, #M.notifications do
    out[#out + 1] = M.notifications[index].message
  end
  return out
end

return M
