--- The public interface.
---
--- Everything a user or another plugin should call lives here. The modules underneath are free to
--- change shape; this is the surface that is documented and kept stable.
---
---@tag sqmeow-api

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

--- Make a connection the one queries run against.
---
---@param id integer
---@return boolean changed
function M.use(id)
  local state = require('sqmeow.state')
  if not state.connections[id] then
    notify(('there is no connection %d'):format(id), vim.log.levels.ERROR)
    return false
  end

  state.current = id
  require('sqmeow.ui.result').update_winbar(state.call)
  return true
end

--- Run SQL on the current connection.
---
--- Returns as soon as the engine has accepted the query, with the id that identifies it. Rows
--- arrive in the result buffer later, written by the engine itself.
---
---@param sql string One or more statements. Only the last one's rows are shown.
---@return integer|nil call_id
---@return string|nil error
function M.execute(sql)
  local state = require('sqmeow.state')
  local connection = state.current_connection()

  if not connection then
    local message = 'connect to a database first'
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end
  if sql:match('^%s*$') then
    return nil, 'there is nothing to run'
  end

  local result = require('sqmeow.ui.result')
  result.open()

  local call_id, err = engine().request('execute', {
    conn_id = connection.id,
    sql = sql,
    buf = result.buffer(),
  })
  if not call_id then
    notify(err or 'the query was refused', vim.log.levels.ERROR)
    return nil, err
  end

  state.call = { call_id = call_id, conn_id = connection.id, state = 'executing' }
  result.update_winbar(state.call)
  return call_id
end

--- Run the whole current buffer.
---@return integer|nil call_id
function M.execute_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'))
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
  return M.execute(table.concat(lines, '\n'))
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

local function turn_page(opts)
  local state = require('sqmeow.state')
  if not state.call or not state.call.call_id then
    return
  end

  local request = { call_id = state.call.call_id, buf = require('sqmeow.ui.result').buffer() }
  request.offset = opts.offset
  request.delta = opts.delta

  local _, err = engine().request('page', request)
  if err then
    notify(err, vim.log.levels.WARN)
  end
end

--- Show the next page of the current result.
function M.next_page()
  turn_page({ delta = 1 })
end

--- Show the previous page of the current result.
function M.prev_page()
  turn_page({ delta = -1 })
end

--- Show the first page of the current result.
function M.first_page()
  turn_page({ offset = 0 })
end

--- Show the last page of the current result.
---
--- The offset comes from the row count the engine reported. The engine clamps anything past the
--- end anyway, so the fallback below is safe even when no summary has arrived yet.
function M.last_page()
  local call = require('sqmeow.state').call
  local pages = call and call.pages or 0
  local page_size = call and call.page_size or 0

  turn_page({ offset = math.max(pages - 1, 0) * page_size })
end

--- Open the result window.
function M.open()
  require('sqmeow.ui.result').open()
end

--- Close the result window.
function M.close()
  require('sqmeow.ui.result').close()
end

--- Every open connection.
---@return sqmeow.Connection[]
function M.connections()
  return require('sqmeow.state').connection_list()
end

--- What the engine is doing, for a statusline.
---
---@return table status Fields: `connection`, `dialect`, `state`, `rows`, `page`, `pages`,
--- `elapsed_ms`. Absent fields mean there is nothing to report yet.
function M.status()
  local state = require('sqmeow.state')
  local connection = state.current_connection()
  local call = state.call or {}

  return {
    connection = connection and connection.name or nil,
    dialect = connection and connection.dialect or nil,
    state = call.state,
    rows = call.rows,
    page = call.page,
    pages = call.pages,
    elapsed_ms = call.elapsed_ms,
  }
end

return M
