-- Standalone API group; require it directly.
-- No re-export through sqmeow.api.

local M = {}

local notify = require('sqmeow.core.utils').notify

local function engine()
  require('sqmeow.rpc.events').ensure()
  return require('sqmeow.rpc.client')
end

local function turn_page(to)
  local state = require('sqmeow.core.state')
  local result = require('sqmeow.ui.result')

  local call = state.call
  if not (call and call.call_id) then
    return notify('there is no result to page', vim.log.levels.WARN)
  end

  local size = math.max(require('sqmeow.config').get().ui.result.page_size, 1)
  result.show_page(to(result.offset(), size, call.view_rows or call.rows or 0))
end

--- Submit statements and open the result window. Completion arrives via events.
--- Uses `opts.conn_id` when supplied; otherwise resolves `opts.source_buf` (or
--- the current buffer) with |sqmeow.api.connection.target()|. Pending edits or destructive
--- statements can defer submission while a confirmation prompt is shown.
---@param sql string One or more statements in the connection's dialect.
---@param opts table|nil `conn_id` selects a connection; `source_buf` selects the
--- buffer used for binding lookup; `line` selects a statement by zero-based line.
--- `where` and `order_by` wrap a single query; `history = false` skips logging
--- and archiving; `confirmed = true` bypasses the destructive-statement prompt.
--- `parameters` maps names to raw input strings, bypassing parameter prompts.
---@return integer|nil call_id Accepted run id; nil if rejected or awaiting input.
---@return string|nil error Failure reason, or an explanation of deferred work.
function M.execute(sql, opts)
  opts = opts or {}
  local state = require('sqmeow.core.state')
  local connection, reason
  if opts.conn_id then
    connection = state.connections[opts.conn_id]
    reason = 'the connection this result came from is not open'
  else
    connection, reason = require('sqmeow.api.connection').target(opts.source_buf)
  end

  if not connection then
    reason = reason or 'connect to a database first'
    notify(reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if sql:match('^%s*$') then
    return nil, 'there is nothing to run'
  end
  -- Selections still use parameter declarations from their scratchpad header.
  local parameter_source = opts.parameter_source
  if not parameter_source and opts.source_buf and vim.api.nvim_buf_is_valid(opts.source_buf) then
    parameter_source = table.concat(vim.api.nvim_buf_get_lines(opts.source_buf, 0, -1, false), '\n')
  end
  -- The engine understands dialect tokens; this only avoids an extra RPC for
  -- the usual unparameterized query. Never rewrite the SQL with input values.
  -- `::` casts and `://` URLs carry no parameter.
  local probe = sql:gsub('::', ''):gsub('://', '')
  if opts.parameters == nil and (probe:find(':', 1, true) or sql:find('@param', 1, true)) then
    local definitions, err = engine().request('query_parameters', {
      conn_id = connection.id,
      sql = sql,
      line = opts.line,
      parameter_source = parameter_source,
    })
    if not definitions then
      notify(err or 'could not discover query parameters', vim.log.levels.ERROR)
      return nil, err
    end
    if #definitions > 0 then
      local pending = vim.tbl_extend('force', opts, {
        conn_id = connection.id,
        parameter_source = parameter_source,
      })
      local parameters = {}
      local function prompt(index)
        local definition = definitions[index]
        if not definition then
          pending.parameters = parameters
          M.execute(sql, pending)
          return
        end
        if parameters[definition.name] ~= nil then
          prompt(index + 1)
          return
        end
        vim.ui.input({
          prompt = definition.kind == 'auto' and (definition.name .. ': ')
            or ('%s (%s): '):format(definition.name, definition.kind),
          default = definition.default or '',
        }, function(value)
          if value == nil then
            return
          end
          parameters[definition.name] = value
          prompt(index + 1)
        end)
      end
      prompt(1)
      return nil, 'waiting for parameter values'
    end
  end
  -- Settle staged edits before replacing the result.
  if require('sqmeow.ui.edit').settle(function()
    M.execute(sql, opts)
  end) then
    return nil, 'waiting for a decision about the staged changes'
  end

  if not opts.confirmed and require('sqmeow.config').get().query.confirm_destructive then
    local dangers, inspect_err = engine().request('inspect', {
      conn_id = connection.id,
      sql = sql,
      line = opts.line,
    })
    if dangers == nil and inspect_err ~= nil then
      notify(inspect_err, vim.log.levels.ERROR)
      return nil, inspect_err
    end
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
      and require('sqmeow.server.history').result_path()
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
    parameters = opts.parameters,
    parameter_source = parameter_source,
  })
  if not call_id then
    notify(err or 'the query was refused', vim.log.levels.ERROR)
    return nil, err
  end

  -- Keep the original SQL for result display and history.
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
---@return string|nil error See |sqmeow.api.query.execute()|, including deferred prompts.
function M.execute_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return M.execute(table.concat(lines, '\n'), { source_buf = vim.api.nvim_get_current_buf() })
end

--- Run the statement the cursor is in.
---@return integer|nil call_id
---@return string|nil error See |sqmeow.api.query.execute()|, including deferred prompts.
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
  local state = require('sqmeow.core.state')
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

return M
