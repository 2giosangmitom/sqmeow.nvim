-- Standalone API group; require it directly.
-- No re-export through sqmeow.api.

local M = {}

local notify = require('sqmeow.core.utils').notify

local function engine()
  require('sqmeow.rpc.events').ensure()
  return require('sqmeow.rpc.client')
end

--- Open a connection. Returns once the engine accepts the request; success arrives as an event.
---@param url string A database URL, such as `sqlite://app.db` or `postgres://localhost/app`.
---@param opts table|nil `name` labels it; `database` and `parent` identify a child
--- database; `read_only` rejects writes; `ssh` selects an SSH host or alias.
--- Project sources carry an `env_file` path for project-local credential templates.
---@return integer|nil id The connection id, or nil if the engine refused the request.
---@return string|nil error
---@usage >lua
---   require('sqmeow.api.connection').connect('sqlite://./app.db', { name = 'app' })
--- <
function M.connect(url, opts)
  opts = opts or {}
  local state = require('sqmeow.core.state')

  local id = state.next_connection_id()
  local name = opts.name or require('sqmeow.core.url').label(url)

  -- Recorded and drawn before the engine is asked.
  state.failures[name] = nil
  state.add_connection({
    id = id,
    name = name,
    url = url,
    state = 'connecting',
    parent = opts.parent,
    database = opts.database,
    read_only = opts.read_only,
    ssh = opts.ssh,
    env_file = opts.env_file,
  })
  require('sqmeow.ui.drawer').render()

  local accepted, err = engine().request('connect', {
    id = id,
    url = url,
    name = name,
    database = opts.database,
    read_only = opts.read_only,
    ssh = opts.ssh,
    env_file = opts.env_file,
  })
  if not accepted then
    state.remove_connection(id)
    require('sqmeow.ui.drawer').render()
    notify(err or 'the engine refused the connection', vim.log.levels.ERROR)
    return nil, err
  end
  return id
end

--- Open a named source entry, carrying over its read-only and SSH settings.
--- Reuses an existing non-closed connection only when its current definition matches.
--- Changed definitions must be disconnected before reconnecting.
--- A returned id may still be connecting; it does not prove login succeeded.
---@param name string The name the source gave it.
---@return integer|nil id
---@return string|nil error
function M.connect_named(name)
  local state = require('sqmeow.core.state')
  local spec = require('sqmeow.sources').find(name)
  if not spec then
    local message = ('there is no configured connection named `%s`'):format(name)
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end

  local existing = state.connection_by_name(name)
  if existing and existing.state ~= 'closed' then
    if
      existing.url ~= spec.url
      or (existing.read_only == true) ~= (spec.read_only == true)
      or (existing.ssh or '') ~= (spec.ssh or '')
      or existing.env_file ~= spec.env_file
    then
      local message = ('connection `%s` has different settings; close it before reconnecting'):format(
        name
      )
      notify(message, vim.log.levels.ERROR)
      return nil, message
    end
    M.use(existing.id)
    return existing.id
  end

  return M.connect(
    spec.url,
    { name = spec.name, read_only = spec.read_only, ssh = spec.ssh, env_file = spec.env_file }
  )
end

--- Read configured sources without connecting to their databases.
--- Entries are returned in source order, with duplicate names removed. The
--- problems list includes source failures and conflicts; usable entries remain.
--- Project parsing can start the engine. Credential templates resolve only when connecting.
---@return sqmeow.ConnectionSpec[] connections
---@return string[] problems
function M.available()
  return require('sqmeow.sources').load()
end

--- Persist a connection to the first configured file source (or its default).
--- Replaces the same-named file entry. Does not open a connection or write back
--- to project, environment, or command sources. Templates remain unexpanded.
---@param name string
---@param url string
---@param opts table|nil `read_only` saves it as a connection that runs only statements that read,
---  and `ssh` as one reached through an SSH tunnel to that `user@host`.
---@return boolean written
function M.save(name, url, opts)
  opts = opts or {}
  local written, err = require('sqmeow.sources').save({
    name = name,
    url = url,
    read_only = opts.read_only,
    ssh = opts.ssh,
  })
  if not written then
    notify(err or 'the connection could not be saved', vim.log.levels.ERROR)
  end
  return written
end

--- Update a file-source connection and rename its open connection to match.
--- URL, read-only, and tunnel changes take effect only after reconnecting.
--- Entries from project, environment, and command sources cannot be edited here.
---@param name string The name it is saved under now.
---@param changes table `name`, `url`, `read_only` and `ssh`, `''` for no tunnel; any may be left out
---  to keep what is there.
---@return boolean written
---@usage >lua
---   require('sqmeow.api.connection').edit('app', { name = 'production' })
--- <
function M.edit(name, changes)
  local spec = require('sqmeow.sources').find(name)
  if not spec then
    notify(('there is no configured connection named `%s`'):format(name), vim.log.levels.WARN)
    return false
  end

  local wanted = { name = changes.name or spec.name, url = changes.url or spec.url }
  if changes.read_only == nil then
    wanted.read_only = spec.read_only
  else
    wanted.read_only = changes.read_only
  end
  if changes.ssh == nil then
    wanted.ssh = spec.ssh
  elseif changes.ssh ~= '' then
    wanted.ssh = changes.ssh
  end
  local written, err = require('sqmeow.sources').update(name, wanted)
  if not written then
    notify(err or 'the connection could not be updated', vim.log.levels.ERROR)
    return false
  end

  for _, connection in ipairs(M.connections()) do
    if connection.name == name then
      M.rename(connection.id, wanted.name)
    end
  end

  -- A URL that changed reaches an open connection only on the next connect, and saying so beats
  -- leaving the user to wonder why their query still goes to the old server.
  local url_changed = changes.url and changes.url ~= spec.url
  local flag_changed = changes.read_only ~= nil and changes.read_only ~= (spec.read_only == true)
  local tunnel_changed = changes.ssh ~= nil and wanted.ssh ~= spec.ssh
  if url_changed or flag_changed or tunnel_changed then
    notify(('`%s` will use its new settings the next time you connect'):format(wanted.name))
  end
  return true
end

--- Rename an open connection in editor state and refresh its displayed label.
--- Does not update a saved definition; use |sqmeow.api.edit()| for that.
---@param id integer
---@param name string
---@return boolean renamed
function M.rename(id, name)
  local state = require('sqmeow.core.state')
  local connection = state.connections[id]
  if not connection or name == '' then
    return false
  end

  connection.name = name
  require('sqmeow.ui.drawer').render()
  require('sqmeow.ui.result').update_winbar(state.call)
  return true
end

--- Delete a connection: close it while it is open, and forget the saved entry.
--- A connection from a source other than the file is only closed, since its entry cannot be
--- removed.
---@param name string The name it is saved or open under.
---@return boolean removed Whether anything was closed or forgotten.
function M.remove(name)
  local state = require('sqmeow.core.state')
  local sources = require('sqmeow.sources')

  local open = {}
  for _, connection in ipairs(state.connection_list()) do
    if connection.name == name then
      table.insert(open, connection)
    end
  end
  local spec = sources.find(name)

  if not spec and #open == 0 then
    notify(('there is no connection called `%s`'):format(name), vim.log.levels.WARN)
    return false
  end
  if spec and spec.source ~= 'file' and #open == 0 then
    notify(
      ('`%s` comes from %s, so it cannot be deleted'):format(name, spec.source),
      vim.log.levels.WARN
    )
    return false
  end

  -- Collected before anything is forgotten, so the drawer can drop what went with it.
  local gone = {}
  for _, connection in ipairs(open) do
    table.insert(gone, connection.id)
    for _, child in ipairs(state.connection_list()) do
      if child.parent == connection.id then
        table.insert(gone, child.id)
      end
    end
  end

  if spec and spec.source == 'file' then
    local written, err = sources.remove(name)
    if not written then
      notify(err or 'the connection could not be deleted', vim.log.levels.ERROR)
      return false
    end
    state.failures[name] = nil
  end

  -- A database opened from a cluster goes with it, and one deleted on its own has no parent
  -- to take it along.
  for _, id in ipairs(gone) do
    if state.connections[id] then
      M.disconnect(id)
    end
  end

  local drawer = require('sqmeow.ui.drawer')
  for _, id in ipairs(gone) do
    drawer.forget(id)
  end
  drawer.render()
  return true
end

--- Close a connection.
---@param id integer|nil Defaults to the current connection.
function M.disconnect(id)
  local state = require('sqmeow.core.state')
  id = id or state.current
  if not id then
    return
  end

  -- The databases opened from a cluster go with it, since the drawer draws them inside it.
  for _, child in ipairs(state.connection_list()) do
    if child.parent == id then
      M.disconnect(child.id)
    end
  end

  engine().request('disconnect', { id = id })
  state.remove_connection(id)
end

--- Select the default target for buffers without a connection binding.
--- Does not connect or wait for readiness. Bound buffers retain their own target.
---@param id integer
---@return sqmeow.Connection|nil connection The one now active, or nil if there is no such id.
function M.use(id)
  local state = require('sqmeow.core.state')
  local connection = state.connections[id]
  if not connection then
    notify(('there is no connection %d'):format(id), vim.log.levels.ERROR)
    return nil
  end

  state.current = id
  require('sqmeow.ui.result').update_winbar(state.call)
  require('sqmeow.ui.editor').update_winbar()
  return connection
end

--- Resolve a buffer's target: its named binding first, then the active connection.
--- A missing bound connection is an error, not a reason to fall back. This only
--- looks up editor state; it neither opens a connection nor waits for readiness.
---@param buf integer|nil Defaults to the current buffer.
---@return sqmeow.Connection|nil connection
---@return string|nil error Why there is none.
function M.target(buf)
  local state = require('sqmeow.core.state')
  local bound = vim.b[buf or 0].sqmeow_connection

  if bound then
    local connection = state.connection_by_name(bound)
    if connection then
      return connection
    end
    return nil, ('`%s` is not open'):format(bound)
  end

  local connection = state.current_connection()
  if connection then
    return connection
  end
  return nil, 'connect to a database first'
end

--- Every open connection.
---@return sqmeow.Connection[]
function M.connections()
  return require('sqmeow.core.state').connection_list()
end

--- Discovered databases of a connection, if it is a cluster. Uses cached schema nodes
--- if already introspected, or queries the engine otherwise.
---@param conn_id integer
---@param callback fun(databases: string[]|nil, error: string|nil)
function M.databases(conn_id, callback)
  local state = require('sqmeow.core.state')
  local connection = state.connections[conn_id]
  if not connection then
    return callback(nil, ('there is no connection %d'):format(conn_id))
  end

  if connection.database then
    return callback({ connection.database })
  end

  local drawer = require('sqmeow.ui.drawer')
  local cached = drawer.databases(conn_id)
  if cached then
    return callback(cached)
  end

  local rpc = engine()
  local done = false
  local timer
  local unsub

  local function finish(dbs, err)
    if done then
      return
    end
    done = true
    if unsub then
      unsub()
    end
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      callback(dbs, err)
    end)
  end

  unsub = rpc.on('schema:nodes', function(payload)
    if payload.conn_id == conn_id and #(payload.path or {}) == 0 then
      if payload.error then
        return finish(nil, payload.error)
      end
      local dbs = {}
      for _, node in ipairs(payload.nodes or {}) do
        if node.kind == 'database' then
          table.insert(dbs, node.name)
        end
      end
      table.sort(dbs)
      finish(dbs)
    end
  end)

  timer = vim.defer_fn(function()
    finish(nil, 'timed out waiting for database list')
  end, 5000)

  local _, err = rpc.request('introspect', { conn_id = conn_id, path = {} })
  if err then
    finish(nil, err)
  end
end

return M
