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

  -- Forgotten before the drawer is drawn. Drawn first, a failed connection stays on screen with
  -- an id nothing answers to, and choosing it again does nothing instead of trying again.
  if payload.state == 'error' or payload.state == 'closed' then
    state.remove_connection(payload.id)
  end
  state.failures[connection.name] = payload.state == 'error' and payload.error or nil

  -- A database opened from a cluster is drawn already open, so what it holds is read straight
  -- away. Scheduled, so the request is not made from inside the engine's own event.
  if payload.state == 'connected' and connection.parent then
    vim.schedule(function()
      require('sqmeow.ui.drawer').load(payload.id, {})
    end)
  end

  require('sqmeow.ui.drawer').render()
  require('sqmeow.ui.editor').update_winbar()

  -- Connecting says nothing: the drawer already shows the dot beside the connection, and a line
  -- in the message area for something visible on screen is noise.
  if payload.state == 'error' then
    notify(
      ('could not connect to %s: %s'):format(connection.name, payload.error),
      vim.log.levels.ERROR
    )
  end
end

--- Handle a query changing state.
---@param payload table
function M.on_call(payload)
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')
  local diagnostics = require('sqmeow.diagnostics')

  -- Merge rather than replace: the SQL text and the buffer it came from are the plugin's own
  -- record of this call, and the engine has no reason to send them back.
  local previous = state.call or {}
  if previous.call_id == payload.call_id then
    state.call = vim.tbl_extend('force', previous, payload)
  else
    state.call = payload
  end

  if payload.state == 'error' then
    diagnostics.set(state.call.source_buf, payload)
    notify(payload.error or 'the query failed', vim.log.levels.ERROR)
  elseif payload.state == 'done' then
    diagnostics.clear(state.call.source_buf)
  elseif payload.state == 'cancelled' then
    notify('query cancelled', vim.log.levels.WARN)
  end

  -- Drawing comes after the state above is settled, because the grid reads it: the rows it asks
  -- for and the label it writes both come from the summary that just arrived.
  result.render(state.call)

  if payload.state ~= 'executing' then
    state.record_call(state.call)
    -- Separate from the registry above: that one mirrors what the engine still holds, and this one
    -- outlives both the engine and the editor.
    require('sqmeow.history').append(state.call)
    -- The drawer lists the log, so a finished query shows up there without anyone asking.
    require('sqmeow.ui.drawer').render()
  end
end

--- Handle an export finishing.
---@param payload table
function M.on_export(payload)
  if payload.error then
    return notify(payload.error, vim.log.levels.ERROR)
  end

  if payload.target == 'file' then
    return notify(('wrote %s (%d bytes)'):format(payload.path, payload.bytes))
  end
  notify(('yanked %d bytes into register %s'):format(payload.bytes, payload.register))
end

--- Handle one level of the schema tree arriving.
---@param payload table
function M.on_nodes(payload)
  require('sqmeow.ui.drawer').on_nodes(payload)
end

--- Handle a connection's catalog arriving.
---@param payload table
function M.on_catalog(payload)
  require('sqmeow.state').set_catalog(payload.conn_id, payload.relations or {}, payload.error)
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
  rpc.on('schema:nodes', M.on_nodes)
  rpc.on('schema:catalog', M.on_catalog)
  rpc.on('export:done', M.on_export)
end

return M
