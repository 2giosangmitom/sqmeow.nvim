--- Turning engine events into interface updates.
---
--- Subscriptions are made once and never torn down, because the engine restarting does not change
--- what the plugin wants to hear about. Each handler updates the mirrored state first and touches
--- the interface second, so state stays correct even when no window is open.

local M = {}

local wired = false

local function notify(message, level)
  vim.notify('sqmeow: ' .. message, level or vim.log.levels.INFO)
end

--- Handle a connection changing state.
---@param payload table
function M.on_connection(payload)
  local state = require('sqmeow.state')
  local connection = state.connections[payload.id]
  if not connection then
    return
  end

  connection.state = payload.state
  connection.dialect = payload.dialect or connection.dialect
  connection.error = payload.error

  require('sqmeow.ui.drawer').render()

  if payload.state == 'connected' then
    notify(('connected to %s (%s)'):format(connection.name, connection.dialect))
  elseif payload.state == 'error' then
    notify(
      ('could not connect to %s: %s'):format(connection.name, payload.error),
      vim.log.levels.ERROR
    )
    state.remove_connection(payload.id)
  elseif payload.state == 'closed' then
    state.remove_connection(payload.id)
  end
end

--- Handle a query changing state.
---@param payload table
function M.on_call(payload)
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')

  state.call = payload
  result.update_winbar(payload)

  if payload.state == 'error' then
    notify(payload.error or 'the query failed', vim.log.levels.ERROR)
  elseif payload.state == 'cancelled' then
    notify('query cancelled', vim.log.levels.WARN)
  end
end

--- Handle a page being painted.
---@param payload table
function M.on_page(payload)
  local state = require('sqmeow.state')
  if state.call and state.call.call_id == payload.call_id then
    -- A page changes position and nothing else, so the rest of the summary is preserved.
    state.call = vim.tbl_extend('force', state.call, payload)
    require('sqmeow.ui.result').update_winbar(state.call)
  end
end

--- Handle one level of the schema tree arriving.
---@param payload table
function M.on_nodes(payload)
  require('sqmeow.ui.drawer').on_nodes(payload)
end

--- Subscribe to engine events. Safe to call repeatedly.
function M.ensure()
  if wired then
    return
  end
  wired = true

  local rpc = require('sqmeow.rpc')
  rpc.on('conn:state', M.on_connection)
  rpc.on('call:state', M.on_call)
  rpc.on('page:painted', M.on_page)
  rpc.on('schema:nodes', M.on_nodes)
end

return M
