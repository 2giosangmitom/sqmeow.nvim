--- Turning engine events into interface updates.

local M = {}

local wired = false

local notify = require('sqmeow.utils').notify

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
  connection.current_database = payload.current_database or connection.current_database
  connection.error = payload.error

  -- Forgotten before the drawer is drawn.
  if payload.state == 'error' or payload.state == 'closed' then
    state.remove_connection(payload.id)
  end
  state.failures[connection.name] = payload.state == 'error' and payload.error or nil

  if payload.state == 'connected' then
    require('sqmeow.session').connected(connection)
  end

  -- A database opened from a cluster is drawn already open.
  if payload.state == 'connected' and connection.parent then
    vim.schedule(function()
      local drawer = require('sqmeow.ui.drawer')
      drawer.load(payload.id, {})
      -- A MongoDB database is drawn with its groups where its only schema row would be.
      if connection.dialect == 'mongodb' and connection.database then
        drawer.load(payload.id, { connection.database })
      end
    end)
  end

  require('sqmeow.ui.drawer').render()
  require('sqmeow.ui.editor').update_winbar()

  -- Connecting says nothing.
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

  -- Merge rather than replace: the SQL text is the plugin's own record of this call, and the engine has no reason to send them back.
  local previous = state.call or {}
  if previous.call_id == payload.call_id then
    state.call = vim.tbl_extend('force', previous, payload)
  else
    state.call = payload
  end

  -- An error gets no message of its own: the result buffer shows it.
  if payload.state == 'cancelled' then
    notify('query cancelled', vim.log.levels.WARN)
  end
  if payload.appended then
    notify(
      ('%d added row%s the query leaves out shown at the end'):format(
        payload.appended,
        payload.appended == 1 and '' or 's'
      )
    )
  end

  -- A MongoDB `use` changes the database both winbars show.
  local connection = state.connections[payload.conn_id]
  if connection and payload.current_database then
    connection.current_database = payload.current_database
    require('sqmeow.ui.editor').update_winbar()
  end

  -- Drawing comes after the state above is settled.
  result.render(state.call)

  if payload.state ~= 'executing' then
    state.record_call(state.call)
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

  if payload.text then
    vim.fn.setreg('"', payload.text)
    pcall(vim.fn.setreg, '+', payload.text)
    return notify(
      ('copied %d row%s (%d bytes)'):format(
        payload.rows,
        payload.rows == 1 and '' or 's',
        payload.bytes
      )
    )
  end

  notify(('wrote %s (%d bytes)'):format(payload.path, payload.bytes))
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
  rpc.on('schema:nodes', M.on_nodes)
  rpc.on('export:done', M.on_export)
  rpc.on('structure:done', function(payload)
    vim.schedule(function()
      require('sqmeow.ui.structure').on_done(payload)
    end)
  end)
  -- Both of these ask the engine for more, and the engine can send them before Neovim has read its
  -- answer to the request that started them.
  rpc.on('call:view', function(payload)
    vim.schedule(function()
      require('sqmeow.ui.result').on_view(payload)
    end)
  end)
  rpc.on('apply:done', function(payload)
    vim.schedule(function()
      require('sqmeow.ui.edit').on_applied(payload)
    end)
  end)
end

return M
