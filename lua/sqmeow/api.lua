--- Lua API for connections, queries, and plugin windows.
---
--- Import with `local db = require('sqmeow.api')`. Connection definitions from
--- |sqmeow.api.available()| are distinct from live connections returned by
--- |sqmeow.api.connections()|. Connection ids and query call ids belong to the
--- current engine session; do not persist them across engine restarts.
---
--- Connection and query methods return when the engine accepts work, not when
--- it finishes. State and result windows update from engine events. Methods
--- may start the engine and open/redraw UI; this is not a headless driver API.
--- Rejected requests generally return nil/false and display a notification.
---@tag sqmeow-api
---@toc_entry Public interface

local M = {}

local notify = require('sqmeow.utils').notify

local function engine()
  require('sqmeow.rpc.events').ensure()
  return require('sqmeow.rpc.client')
end

--- Open a connection. Returns once the engine accepts the request; success arrives as an event.
---@param url string A database URL, such as `sqlite://app.db` or `postgres://localhost/app`.
---@param opts table|nil `name` labels it; `database` and `parent` identify a child
--- database; `read_only` rejects writes; `ssh` selects an SSH host or alias.
---@return integer|nil id The connection id, or nil if the engine refused the request.
---@return string|nil error
---@usage >lua
---   require('sqmeow.api').connect('sqlite://./app.db', { name = 'app' })
--- <
function M.connect(url, opts)
  opts = opts or {}
  local state = require('sqmeow.state')

  local id = state.next_connection_id()
  local name = opts.name or require('sqmeow.url').label(url)

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
  })
  require('sqmeow.ui.drawer').render()

  local accepted, err = engine().request('connect', {
    id = id,
    url = url,
    name = name,
    database = opts.database,
    read_only = opts.read_only,
    ssh = opts.ssh,
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
  local state = require('sqmeow.state')
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

  return M.connect(spec.url, { name = spec.name, read_only = spec.read_only, ssh = spec.ssh })
end

--- Read configured sources without connecting to their databases.
--- Entries are returned in source order, with duplicate names removed. The
--- problems list includes source failures and conflicts; usable entries remain.
--- Project parsing can start the engine; command sources may still be loading.
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
---   require('sqmeow.api').edit('app', { name = 'production' })
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
  local state = require('sqmeow.state')
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
  local state = require('sqmeow.state')
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
  local state = require('sqmeow.state')
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
  local state = require('sqmeow.state')
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
  local state = require('sqmeow.state')
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

--- Submit statements and open the result window. Completion arrives via events.
--- Uses `opts.conn_id` when supplied; otherwise resolves `opts.source_buf` (or
--- the current buffer) with |sqmeow.api.target()|. Pending edits or destructive
--- statements can defer submission while a confirmation prompt is shown.
---@param sql string One or more statements in the connection's dialect.
---@param opts table|nil `conn_id` selects a connection; `source_buf` selects the
--- buffer used for binding lookup; `line` selects a statement by zero-based line.
--- `where` and `order_by` wrap a single query; `history = false` skips logging
--- and archiving; `confirmed = true` bypasses the destructive-statement prompt.
---@return integer|nil call_id Accepted run id; nil if rejected or awaiting input.
---@return string|nil error Failure reason, or an explanation of deferred work.
function M.execute(sql, opts)
  opts = opts or {}
  local state = require('sqmeow.state')
  local connection, reason
  if opts.conn_id then
    connection = state.connections[opts.conn_id]
    reason = 'the connection this result came from is not open'
  else
    connection, reason = M.target(opts.source_buf)
  end

  if not connection then
    reason = reason or 'connect to a database first'
    notify(reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if sql:match('^%s*$') then
    return nil, 'there is nothing to run'
  end
  -- A new result would drop them.
  if require('sqmeow.ui.edit').settle(function()
    M.execute(sql, opts)
  end) then
    return nil, 'waiting for a decision about the staged changes'
  end

  if not opts.confirmed and require('sqmeow.config').get().query.confirm_destructive then
    local dangers = engine().request('inspect', {
      conn_id = connection.id,
      sql = sql,
      line = opts.line,
    })
    if type(dangers) == 'table' and #dangers > 0 then
      vim.ui.select({ 'Run it', 'Cancel' }, {
        prompt = ('%s, on %s. Run it?'):format(table.concat(dangers, '; '), connection.name),
      }, function(choice)
        if choice == 'Run it' then
          local confirmed = { conn_id = connection.id, confirmed = true }
          M.execute(sql, vim.tbl_extend('force', opts, confirmed))
        end
      end)
      return nil, 'waiting for confirmation'
    end
  end

  local result = require('sqmeow.ui.result')
  result.open()

  -- Rows are saved only for logged queries, and only when the log is saved.
  local recorded = opts.history ~= false
  local archive = recorded
      and require('sqmeow.config').get().query.persist_history
      and require('sqmeow.history').result_path()
    or nil

  local call_id, err = engine().request('execute', {
    conn_id = connection.id,
    sql = sql,
    line = opts.line,
    archive = archive,
    where = opts.where,
    order_by = opts.order_by,
    columns = opts.columns,
    inserted = opts.inserted,
  })
  if not call_id then
    notify(err or 'the query was refused', vim.log.levels.ERROR)
    return nil, err
  end

  -- The SQL is the plugin's to remember.
  state.call = {
    call_id = call_id,
    conn_id = connection.id,
    state = 'executing',
    statement = sql,
    history = recorded,
    archive = archive,
  }
  result.update_winbar(state.call)
  return call_id
end

--- Run the whole current buffer.
---@return integer|nil call_id
---@return string|nil error See |sqmeow.api.execute()|, including deferred prompts.
function M.execute_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'), { source_buf = vim.api.nvim_get_current_buf() })
end

--- Run the statement the cursor is in.
---@return integer|nil call_id
---@return string|nil error See |sqmeow.api.execute()|, including deferred prompts.
function M.execute_statement()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'), {
    line = vim.api.nvim_win_get_cursor(0)[1] - 1,
    source_buf = vim.api.nvim_get_current_buf(),
  })
end

--- Run the most recent visual selection.
---@return integer|nil call_id
---@return string|nil error
function M.execute_selection()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local active = mode == 'v' or mode == 'V' or mode == '\22'
  local first = vim.fn.getpos(active and 'v' or "'<")
  local last = vim.fn.getpos(active and '.' or "'>")
  if first[2] == 0 or last[2] == 0 then
    return nil, 'there is no visual selection to run'
  end
  -- Let Neovim handle rectangles, reversed selections, exclusive endpoints,
  -- tabs and multibyte characters rather than treating every region as bytes.
  local lines = vim.fn.getregion(first, last, {
    type = active and mode or vim.fn.visualmode(),
    exclusive = vim.o.selection == 'exclusive',
  })
  if active then
    vim.cmd('normal! \27')
  end
  return M.execute(table.concat(lines, '\n'), { source_buf = buf })
end

--- Run an explicit one-based, inclusive line range from the current buffer.
---@param first integer First line, counted from one.
---@param last integer Last line, inclusive.
---@return integer|nil call_id
---@return string|nil error
function M.execute_range(first, last)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, true)
  return M.execute(table.concat(lines, '\n'), { source_buf = buf })
end

--- Request cancellation of an edit apply, or otherwise the current query.
--- Completion is asynchronous; true means cancellation was requested, not that
--- the database has already stopped or that arbitrary SQL was rolled back.
---@return boolean stopped Whether the engine accepted cancellation.
function M.cancel()
  local state = require('sqmeow.state')
  -- Changes being applied are stopped by their result's call id.
  local call_id = require('sqmeow.ui.edit').applying()
  if not call_id then
    if not state.call or state.call.state ~= 'executing' then
      return false
    end
    call_id = state.call.call_id
  end

  local stopped = engine().request('cancel', { call_id = call_id })
  return stopped == true
end

--- Move the result window to another page.
---@param to fun(offset: integer, size: integer, rows: integer): integer
local function turn_page(to)
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')

  local call = state.call
  if not (call and call.call_id) then
    return notify('there is no result to page', vim.log.levels.WARN)
  end

  local size = math.max(require('sqmeow.config').get().ui.result.page_size, 1)
  result.show_page(to(result.offset(), size, call.view_rows or call.rows or 0))
end

--- Show the next page of the current result.
function M.next_page()
  turn_page(function(offset, size)
    return offset + size
  end)
end

--- Show the previous page of the current result.
function M.prev_page()
  turn_page(function(offset, size)
    return offset - size
  end)
end

--- Show the first page of the current result.
function M.first_page()
  turn_page(function()
    return 0
  end)
end

--- Show the last page of the current result.
function M.last_page()
  turn_page(function(_, size, rows)
    return math.max(math.ceil(rows / size) - 1, 0) * size
  end)
end

--- Show the result in a float, or put it back in its split.
function M.toggle_float()
  require('sqmeow.ui.result').toggle_float()
end

--- Show the statements the changes staged in the result plan into, to apply with `<C-s>`.
function M.review()
  require('sqmeow.ui.edit').review()
end

--- Filter and order the current result with a WHERE condition and an ORDER BY list, which an open
--- SQL or MongoDB connection runs in the query and Redis, ScyllaDB, SurrealDB or a closed connection
--- runs on the rows held. Empty strings clear them.
---@param view { where: string|nil, order_by: string|nil }
---@return boolean started
---@usage >lua
---   require('sqmeow.api').filter({ where = "name like 'a%'", order_by = 'age desc' })
--- <
function M.filter(view)
  return require('sqmeow.ui.result').filter(view.where or '', view.order_by or '')
end

--- Filter and sort the current result's rows in the engine's memory, without querying again.
--- Columns are zero-based; a filter without one searches every column.
---@param view { filters: { column: integer|nil, op: string, value: string|nil }[]|nil, sort: { column: integer, descending: boolean|nil }[]|nil }
--- `op`: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `contains`, `starts_with`, `is_null`, `not_null`.
---@usage >lua
---   require('sqmeow.api').view({ filters = { { column = 1, op = 'contains', value = 'al' } } })
--- <
function M.view(view)
  local result = require('sqmeow.ui.result')
  local spec = result.spec()
  spec.filters = view.filters or spec.filters
  spec.sort = view.sort or spec.sort
  result.send_view()
end

--- Open the result window.
function M.open()
  require('sqmeow.ui.result').open()
end

--- Close the result window.
function M.close()
  require('sqmeow.ui.result').close()
end

--- Put a past result back in the result window.
---@param call_id integer From the query log.
function M.reopen(call_id)
  if require('sqmeow.ui.edit').settle(function()
    M.reopen(call_id)
  end) then
    return
  end
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')
  result.open()

  for _, summary in ipairs(state.calls) do
    if summary.call_id == call_id then
      state.call = vim.deepcopy(summary)
      break
    end
  end

  -- Nothing is asked of the engine but the rows.
  result.render(state.call)
end

--- Show a logged result the engine no longer holds, from the copy saved beside the log.
---@param entry table From the query log, with a saved result.
---@return integer|nil call_id
---@return string|nil error
function M.restore(entry)
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')
  local connection = entry.connection and state.connection_by_name(entry.connection)
  local conn_id = connection and connection.id or 0

  result.open()
  local call_id, err = engine().request('restore', {
    path = entry.result,
    others = entry.results,
    conn_id = conn_id,
  })
  if not call_id then
    notify(err or 'the saved result could not be read', vim.log.levels.ERROR)
    return nil, err
  end

  state.call = {
    call_id = call_id,
    conn_id = conn_id,
    state = 'executing',
    statement = entry.statement,
    -- Already in the log. Showing it again is not running it again.
    history = false,
    connection = entry.connection,
    dialect = entry.dialect,
    ran_at = entry.at,
  }
  result.update_winbar(state.call)
  return call_id
end

--- Create a scratchpad, asking what to call it. `/` in the name makes folders.
---@param name string|nil Raw name with extension (e.g. `report.sql`, `cache.redis`, `reports/monthly.sql`). If given, it is created directly; otherwise the user is prompted.
---@param default string|nil Prefilled prompt when asking, such as a folder followed by `/`.
function M.scratchpad(name, default)
  require('sqmeow.rpc.events').ensure()

  -- ` :Sqmeow scratch <name>` passes the desired name directly.
  if name and vim.trim(name) ~= '' then
    local _, err = require('sqmeow.ui.editor').create(name)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    require('sqmeow.ui.drawer').render()
    return
  end

  vim.ui.input({ prompt = 'New scratchpad: ', default = default }, function(input)
    if not input or vim.trim(input) == '' then
      return
    end
    local _, err = require('sqmeow.ui.editor').create(input)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    require('sqmeow.ui.drawer').render()
  end)
end

--- Reopen the last session's connections, once, when `ui.persist_session` is on.
local function resume()
  if require('sqmeow.config').get().ui.persist_session then
    require('sqmeow.session').restore()
  end
end

--- Show the schema drawer.
---@return integer win
function M.open_drawer()
  require('sqmeow.rpc.events').ensure()
  local win = require('sqmeow.ui.drawer').open()
  resume()
  return win
end

--- Hide the schema drawer.
function M.close_drawer()
  require('sqmeow.ui.drawer').close()
end

--- Open the drawer and the result window.
function M.open_all()
  require('sqmeow.rpc.events').ensure()

  require('sqmeow.ui.drawer').open()
  require('sqmeow.ui.result').open()
  resume()
end

--- Show everything, or hide it all if any of it is showing.
function M.toggle()
  local layout = require('sqmeow.ui.layout')
  if layout.anything_open() then
    require('sqmeow.ui.drawer').close()
    require('sqmeow.ui.result').close()
    return
  end
  M.open_all()
end

--- Every open connection.
---@return sqmeow.Connection[]
function M.connections()
  return require('sqmeow.state').connection_list()
end

--- Discovered databases of a connection, if it is a cluster. Uses cached schema nodes
--- if already introspected, or queries the engine otherwise.
---@param conn_id integer
---@param callback fun(databases: string[]|nil, error: string|nil)
function M.databases(conn_id, callback)
  local state = require('sqmeow.state')
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
