--- The public interface.
---@tag sqmeow-api
---@toc_entry Public interface

local M = {}

local notify = require('sqmeow.utils').notify

local function engine()
  require('sqmeow.events').ensure()
  return require('sqmeow.rpc')
end

--- Open a connection. Returns once the engine accepts the request; success arrives as an event.
---@param url string A database URL, such as `sqlite://app.db` or `postgres://localhost/app`.
---@param opts table|nil `name` labels it; `database` and `parent` open one database of cluster `parent`; `read_only` runs only statements that read.
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
  })
  require('sqmeow.ui.drawer').render()

  local accepted, err = engine().request('connect', {
    id = id,
    url = url,
    name = name,
    database = opts.database,
    read_only = opts.read_only,
  })
  if not accepted then
    state.remove_connection(id)
    require('sqmeow.ui.drawer').render()
    notify(err or 'the engine refused the connection', vim.log.levels.ERROR)
    return nil, err
  end
  return id
end

--- Connect to a connection declared by a source.
---@param name string The name the source gave it.
---@return integer|nil id
---@return string|nil error
function M.connect_named(name)
  local spec = require('sqmeow.sources').find(name)
  if not spec then
    local message = ('there is no configured connection named `%s`'):format(name)
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end

  return M.connect(spec.url, { name = spec.name, read_only = spec.read_only })
end

--- Every connection the configured sources declare.
---@return sqmeow.ConnectionSpec[] connections
---@return string[] problems
function M.available()
  return require('sqmeow.sources').load()
end

--- Save a connection to the file source.
---@param name string
---@param url string
---@param opts table|nil `read_only` saves it as a connection that runs only statements that read.
---@return boolean written
function M.save(name, url, opts)
  local written, err = require('sqmeow.sources').save({
    name = name,
    url = url,
    read_only = (opts or {}).read_only,
  })
  if not written then
    notify(err or 'the connection could not be saved', vim.log.levels.ERROR)
  end
  return written
end

--- Change a saved connection's name, URL or read-only flag, and rename its open connection to match.
---@param name string The name it is saved under now.
---@param changes table `name`, `url` and `read_only`; any may be left out to keep what is there.
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
  if url_changed or flag_changed then
    notify(('`%s` will use its new settings the next time you connect'):format(wanted.name))
  end
  return true
end

--- Change what an open connection is called.
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

--- Make a connection the active one.
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

--- Which connection a query from this buffer belongs to.
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

--- Run SQL on the current connection.
---@param sql string One or more statements.
---@param opts table|nil `line` runs only the statement at that zero-based line; `where` and
--- `order_by` run a single query as a subquery filtered and ordered by them; `confirmed` skips
--- asking before a destructive statement.
---@return integer|nil call_id
---@return string|nil error
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
function M.execute_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'), { source_buf = vim.api.nvim_get_current_buf() })
end

--- Run the statement the cursor is in.
---@return integer|nil call_id
function M.execute_statement()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'), {
    line = vim.api.nvim_win_get_cursor(0)[1] - 1,
    source_buf = vim.api.nvim_get_current_buf(),
  })
end

--- Run the most recent visual selection.
---@return integer|nil call_id
function M.execute_selection()
  local start_pos = vim.api.nvim_buf_get_mark(0, '<')
  local end_pos = vim.api.nvim_buf_get_mark(0, '>')

  local lines = vim.api.nvim_buf_get_text(
    0,
    start_pos[1] - 1,
    start_pos[2],
    end_pos[1] - 1,
    -- The end mark's column is inclusive, and can sit past the line end for a linewise selection.
    math.min(end_pos[2] + 1, #vim.fn.getline(end_pos[1])),
    {}
  )
  return M.execute(table.concat(lines, '\n'), { source_buf = vim.api.nvim_get_current_buf() })
end

--- Stop the running query.
---@return boolean stopped Whether there was a query to stop.
function M.cancel()
  local state = require('sqmeow.state')
  if not state.call or state.call.state ~= 'executing' then
    return false
  end

  local stopped = engine().request('cancel', { call_id = state.call.call_id })
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

--- Filter and order the current result by running its query again with a WHERE condition and an
--- ORDER BY list. Needs an open SQL connection; empty strings clear them.
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
  local call_id, err = engine().request('restore', { path = entry.result, conn_id = conn_id })
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

--- Write the current result to a file.
---@param opts table|nil `path` skips the dialog.
function M.export(opts)
  opts = opts or {}
  local state = require('sqmeow.state')
  local call = state.call
  if not (call and call.call_id) then
    notify('there is no result to export', vim.log.levels.WARN)
    return
  end

  -- SQL is written for the database the rows came from.
  local dialect = call.dialect or (state.connections[call.conn_id] or {}).dialect

  --- Without a path the engine sends the text back, and `export:done` puts it on the clipboard.
  local function write(format, path, headers, target)
    local _, err = engine().request('export', {
      call_id = call.call_id,
      format = format,
      headers = headers,
      table = target,
      dialect = dialect,
      offset = opts.offset,
      limit = opts.limit,
      columns = require('sqmeow.ui.result').visible_columns(),
      path = path and vim.fn.fnamemodify(vim.fs.normalize(path), ':p') or nil,
    })
    if err then
      notify(err, vim.log.levels.ERROR)
    end
  end

  if opts.path or opts.clipboard then
    return write(opts.format or 'csv', opts.path, opts.headers ~= false, opts.table)
  end

  -- Named after the table the query reads from, else the connection.
  local relation = (call.statement or ''):match('[Ff][Rr][Oo][Mm]%s+([%w_%.`"%[%]]+)')
  relation = relation and relation:gsub('[`"%[%]]', ''):match('([^.]+)$')
  local connection = call.connection or (state.connections[call.conn_id] or {}).name or 'result'
  local stem = (relation or connection):gsub('[^%w_-]', '_') .. os.date('_%Y%m%d_%H%M%S')

  local result = require('sqmeow.ui.result')
  local count = opts.limit or call.view_rows or call.rows or 0
  local plural = count == 1 and '' or 's'
  -- The engine renders at most this many rows for the preview.
  local shown = math.min(count, 100)
  local title = opts.limit and ('Preview of %d selected row%s'):format(count, plural)
    or ('Preview of all %d row%s'):format(count, plural)
  if shown < count then
    title = ('%s, first %d'):format(title, shown)
  end

  local format = (opts.format or 'csv'):upper()
  local function to_file(values)
    return values.destination ~= 'Clipboard'
  end
  -- The file the last refused save would have replaced.
  local confirmed

  local ok, err = require('sqmeow.ui.form').open({
    title = 'Export',
    fields = {
      { key = 'format', label = 'Format', options = { 'CSV', 'JSON', 'SQL' } },
      { key = 'filename', label = 'Filename', enabled = to_file },
      { key = 'path', label = 'Path', enabled = to_file },
      {
        key = 'headers',
        label = 'Include headers',
        checkbox = true,
        -- JSON names every value by its column, so there is no header to leave out.
        enabled = function(values)
          return values.format == 'CSV'
        end,
      },
      {
        key = 'table',
        label = 'Table',
        -- Left empty, the rows go into the table they came from.
        hint = call.source and call.source.kind == 'table' and call.source.name or 'result',
        enabled = function(values)
          return values.format == 'SQL'
        end,
      },
      { key = 'destination', label = 'Destination', options = { 'File', 'Clipboard' } },
    },
    values = {
      format = format,
      destination = 'File',
      filename = stem .. '.' .. format:lower(),
      path = vim.fn.fnamemodify(vim.uv.cwd() or '.', ':~'),
      headers = 'yes',
      table = '',
    },
    -- What will be written, in the format chosen.
    preview = {
      title = title,
      filetype = function(values)
        return values.format:lower()
      end,
      lines = function(values)
        local text, problem = engine().request('export_preview', {
          call_id = call.call_id,
          format = values.format:lower(),
          headers = values.headers == 'yes',
          table = values.table,
          dialect = dialect,
          offset = opts.offset,
          limit = opts.limit,
          columns = result.visible_columns(),
        })
        if not text then
          return { problem or 'there is nothing to preview' }
        end
        return vim.split((text:gsub('\n$', '')), '\n', { plain = true })
      end,
    },
    on_change = function(values, key)
      -- The extension follows the format, unless the user named the file something else.
      if key == 'format' then
        local bare = values.filename:match('^(.*)%.csv$')
          or values.filename:match('^(.*)%.json$')
          or values.filename:match('^(.*)%.sql$')
        if bare then
          values.filename = bare .. '.' .. values.format:lower()
        end
      end
    end,
    validate = function(values)
      if not to_file(values) then
        return
      end
      if vim.trim(values.filename) == '' then
        return 'a file name is needed'
      end
      if vim.trim(values.path) == '' then
        return 'a path is needed'
      end
      local directory = vim.fs.normalize(values.path)
      if vim.fn.isdirectory(directory) == 0 then
        return values.path .. ' is not a directory'
      end

      local target = vim.fs.joinpath(directory, values.filename)
      if vim.uv.fs_stat(target) and confirmed ~= target then
        confirmed = target
        return values.filename .. ' exists: <C-s> again to overwrite it'
      end
    end,
    on_submit = function(values)
      write(
        values.format:lower(),
        to_file(values) and vim.fs.joinpath(values.path, values.filename) or nil,
        values.headers == 'yes',
        values.table
      )
    end,
  })
  if not ok then
    notify(err or 'the export dialog could not open', vim.log.levels.ERROR)
  end
end

--- Create a scratchpad for a connection, asking what to call it.
---@param connection string|nil Connection name.
function M.scratchpad(connection)
  require('sqmeow.events').ensure()
  local state = require('sqmeow.state')

  if not connection then
    local current = state.current_connection()
    if not current then
      return notify('connect to a database first, or name one', vim.log.levels.WARN)
    end
    connection = current.name
  end
  -- A folder for a name nobody has saved would hold scratchpads tied to nothing.
  if
    not state.connection_by_name(connection) and not require('sqmeow.sources').find(connection)
  then
    return notify(('there is no connection named `%s`'):format(connection), vim.log.levels.ERROR)
  end

  vim.ui.input({ prompt = ('New scratchpad for %s: '):format(connection) }, function(name)
    if not name or vim.trim(name) == '' then
      return
    end
    local _, err = require('sqmeow.ui.editor').create(connection, name)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    require('sqmeow.ui.drawer').render()
  end)
end

--- Show the schema drawer.
function M.open_drawer()
  require('sqmeow.events').ensure()
  require('sqmeow.ui.drawer').open()
end

--- Hide the schema drawer.
function M.close_drawer()
  require('sqmeow.ui.drawer').close()
end

--- Open the drawer and the result window.
function M.open_all()
  require('sqmeow.events').ensure()

  require('sqmeow.ui.drawer').open()
  require('sqmeow.ui.result').open()
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

return M
