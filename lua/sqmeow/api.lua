--- The public interface.
---
--- Everything a user or another plugin should call lives here. The modules underneath are free to
--- change shape; this is the surface that is documented and kept stable.
---
---@tag sqmeow-api
---@toc_entry Public interface

local M = {}

local function notify(message, level)
  vim.notify('sqmeow: ' .. message, level or vim.log.levels.INFO)
end

local function engine()
  require('sqmeow.events').ensure()
  return require('sqmeow.rpc')
end

--- Open a connection.
---
--- Returns as soon as the engine has accepted the request. The connection is not usable until it
--- reports success, which arrives as an event and is announced to the user.
---
---@param url string A database URL, such as `sqlite://app.db` or `postgres://localhost/app`.
---@param opts table|nil Options: `name` for the label shown in the interface.
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

  local accepted, err = engine().request('connect', { id = id, url = url, name = name })
  if not accepted then
    notify(err or 'the engine refused the connection', vim.log.levels.ERROR)
    return nil, err
  end

  state.add_connection({ id = id, name = name, url = url, state = 'connecting' })
  return id
end

--- Connect to a connection declared by a source.
---
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

  return M.connect(spec.url, { name = spec.name })
end

--- Every connection the configured sources declare.
---
--- Reading a source is cheap, and re-reading it means a file edited outside the editor is picked
--- up without a restart.
---
---@return sqmeow.ConnectionSpec[] connections
---@return string[] problems
function M.available()
  return require('sqmeow.sources').load()
end

--- Save a connection to the file source.
---
---@param name string
---@param url string
---@return boolean written
function M.save(name, url)
  local written, err = require('sqmeow.sources').save({ name = name, url = url })
  if not written then
    notify(err, vim.log.levels.ERROR)
  end
  return written
end

--- Change what a saved connection is called, or where it points.
---
--- The saved entry and any open connection under that name are changed together, since a user who
--- renames one of them meant both: they are one connection as far as anyone but this plugin is
--- concerned.
---
---@param name string The name it is saved under now.
---@param changes table `name` and `url`; either may be left out to keep what is there.
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
  local written, err = require('sqmeow.sources').update(name, wanted)
  if not written then
    notify(err, vim.log.levels.ERROR)
    return false
  end

  for _, connection in ipairs(M.connections()) do
    if connection.name == name then
      M.rename(connection.id, wanted.name)
    end
  end

  -- A URL that changed reaches an open connection only on the next connect, and saying so beats
  -- leaving the user to wonder why their query still goes to the old server.
  if changes.url and changes.url ~= spec.url then
    notify(('`%s` will use its new url the next time you connect'):format(wanted.name))
  end
  return true
end

--- Change what an open connection is called.
---
--- The name is the plugin's own: the engine keeps one for its log, and everything the user sees is
--- drawn from here. So this is a local change, and nothing has to be reconnected for it.
---
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
---
---@param id integer|nil Defaults to the current connection.
function M.disconnect(id)
  local state = require('sqmeow.state')
  id = id or state.current
  if not id then
    return
  end

  engine().request('disconnect', { id = id })
  state.remove_connection(id)
end

--- Make a connection the active one.
---
--- The active connection is what a query runs on when the buffer it came from does not name one of
--- its own. Changing it redraws everything that says which database is in play, because a switch
--- nobody can see is the same as no switch at all.
---
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
  require('sqmeow.ui.drawer').render()
  return connection
end

--- Which connection a query from this buffer belongs to.
---
--- A scratchpad is opened for one database and named after it, so it runs there whatever else is
--- active. Anything else runs on the active connection.
---
--- A buffer bound to a database that is not open is an error rather than a reason to fall back:
--- running `staging.sql` against production because staging happens to be closed is the mistake
--- this whole idea exists to prevent.
---
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
---
--- Returns as soon as the engine has accepted the query, with the id that identifies it. Rows
--- arrive in the result buffer later, written by the engine itself.
---
---@param sql string One or more statements. Only the last one's rows are shown.
---@param opts table|nil `line` runs only the statement at that zero-based line; `source_buf` is
--- the buffer an error should be reported in; `history = false` keeps the query out of the log,
--- for SQL the plugin wrote rather than the user.
---@return integer|nil call_id
---@return string|nil error
function M.execute(sql, opts)
  opts = opts or {}
  local state = require('sqmeow.state')
  local connection, reason = M.target(opts.source_buf)

  if not connection then
    notify(reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if sql:match('^%s*$') then
    return nil, 'there is nothing to run'
  end

  local result = require('sqmeow.ui.result')
  result.open()

  -- The rows are saved only for a query that goes in the log, and only when the log itself is
  -- saved: a result on disk that no entry points at is a copy of someone's data for nothing.
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
  })
  if not call_id then
    notify(err or 'the query was refused', vim.log.levels.ERROR)
    return nil, err
  end

  -- The SQL and the buffer it came from are the plugin's to remember: the engine has no reason to
  -- send back text the editor already has, and an error needs somewhere to be shown.
  state.call = {
    call_id = call_id,
    conn_id = connection.id,
    state = 'executing',
    statement = sql,
    source_buf = opts.source_buf,
    history = recorded,
    archive = archive,
  }
  require('sqmeow.diagnostics').clear(opts.source_buf)
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
---
--- The whole buffer is sent along with the cursor line, and the engine picks the statement, using
--- the same splitter that would have split the buffer. Doing it that way means there is one answer
--- to what counts as a statement, rather than one here and a different one there.
---
---@return integer|nil call_id
function M.execute_statement()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'), {
    line = vim.api.nvim_win_get_cursor(0)[1] - 1,
    source_buf = vim.api.nvim_get_current_buf(),
  })
end

--- Run the most recent visual selection.
---
--- Reads the `<` and `>` marks, so it works both from a `:` command on a selection and from a
--- mapping that leaves visual mode first.
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
---
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
---
--- Nothing is asked of the engine beyond the rows themselves: how many fit on a page and where the
--- view has got to are this side's to know, so the arithmetic is here.
---
---@param to fun(offset: integer, size: integer, rows: integer): integer
local function turn_page(to)
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')

  local call = state.call
  if not (call and call.call_id) then
    return notify('there is no result to page', vim.log.levels.WARN)
  end

  local size = math.max(require('sqmeow.config').get().ui.result.page_size, 1)
  result.show_page(to(result.offset(), size, call.rows or 0))
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

--- Open the result window.
function M.open()
  require('sqmeow.ui.result').open()
end

--- Close the result window.
function M.close()
  require('sqmeow.ui.result').close()
end

--- Put a past result back in the result window.
---
--- Nothing is run again: the engine still holds the rows, so this only asks it to repaint them.
---
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

  -- Nothing is asked of the engine but the rows: it still holds them, and the summary the log kept
  -- carries everything needed to lay the columns out again.
  result.render(state.call)
end

--- Show a logged result the engine no longer holds, from the copy saved beside the log.
---
--- Nothing is run. The engine reads the file and reports it as `call:state`, the way it reports a
--- query, so the grid, paging, the row detail and exports all work on it as they did when it ran.
---
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
---
---@param opts table|nil `path` skips the prompt; `format` is 'csv' or 'json'.
function M.export(opts)
  opts = opts or {}
  local state = require('sqmeow.state')
  if not (state.call and state.call.call_id) then
    notify('there is no result to export', vim.log.levels.WARN)
    return
  end

  local format = opts.format or 'csv'
  local function write(path)
    if not path or path == '' then
      return
    end
    local _, err = engine().request('export', {
      call_id = state.call.call_id,
      format = format,
      scope = 'all',
      path = vim.fn.fnamemodify(path, ':p'),
    })
    if err then
      notify(err, vim.log.levels.ERROR)
    end
  end

  if opts.path then
    return write(opts.path)
  end

  vim.ui.input({
    prompt = 'Write ' .. format .. ' to: ',
    default = vim.fs.joinpath(vim.uv.cwd() or '.', 'result.' .. format),
    completion = 'file',
  }, write)
end

--- Open the scratchpad for a connection.
---
---@param name string|nil Defaults to the current connection.
---@return integer buf
function M.scratchpad(name)
  require('sqmeow.events').ensure()
  return require('sqmeow.ui.editor').open(name)
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

--- Open every surface at once: the drawer, a scratchpad, and the result window.
---
--- What `:Sqmeow` on its own does. A database client is three panes, and opening them one command
--- at a time is work the user should not have to do to get started.
---
--- The order is the layout: the drawer takes the left, the scratchpad the window beside it, and
--- the result the strip along the bottom.
function M.open_all()
  require('sqmeow.events').ensure()

  require('sqmeow.ui.drawer').open()
  local buf = require('sqmeow.ui.editor').open()
  require('sqmeow.ui.result').open()

  -- Back to the scratchpad, since that is where the next thing a person does is typing.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
  return buf
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
