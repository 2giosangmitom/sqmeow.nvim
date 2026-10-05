-- Standalone API group; require it directly.
-- No re-export through sqmeow.api.

local M = {}

local notify = require('sqmeow.core.utils').notify

local function engine()
  require('sqmeow.rpc.events').ensure()
  return require('sqmeow.rpc.client')
end

local function resume()
  if require('sqmeow.config').get().ui.persist_session then
    require('sqmeow.server.session').restore()
  end
end

--- Show the result in a float, or put it back in its split.
function M.toggle_float()
  require('sqmeow.ui.result').toggle_float()
end

--- Show the statements the changes staged in the result plan into, to apply with `<C-s>`.
function M.review()
  require('sqmeow.ui.edit').review()
end

--- Filter and order retained rows with a Polars SQL WHERE condition and ORDER BY list.
--- Every adapter uses the same syntax, including disconnected and restored historical results.
--- No query is rerun. Empty strings clear the clauses; only retained rows can be matched.
---@param view { where: string|nil, order_by: string|nil }
---@return boolean started
---@usage >lua
---   require('sqmeow.api.view').filter({ where = "name like 'a%'", order_by = 'age desc' })
--- <
function M.filter(view)
  return require('sqmeow.ui.result').filter(view.where or '', view.order_by or '')
end

--- Filter and sort the current result's rows in the engine's memory, without querying again.
--- Columns are zero-based; a filter without one searches every column.
---@param view { filters: { column: integer|nil, op: string, value: string|nil }[]|nil, sort: { column: integer, descending: boolean|nil }[]|nil }
--- `op`: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `contains`, `starts_with`, `is_null`, `not_null`.
---@usage >lua
---   require('sqmeow.api.view').view({ filters = { { column = 1, op = 'contains', value = 'al' } } })
--- <
function M.view(view)
  local result = require('sqmeow.ui.result')
  local spec = result.spec()
  spec.filters = view.filters or spec.filters
  spec.sort = view.sort or spec.sort
  if view.sort then
    -- An explicit structured sort replaces the bar's ordering, not its predicate.
    spec.order_by = ''
  end
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
  local state = require('sqmeow.core.state')
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
  local state = require('sqmeow.core.state')
  local result = require('sqmeow.ui.result')
  local connection = entry.connection and state.connection_by_name(entry.connection)
  local conn_id = connection and connection.id or 0

  result.open()
  local call_id, err = engine().request('restore', {
    path = entry.result,
    others = entry.results,
    conn_id = conn_id,
    dialect = entry.dialect,
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
---@param store table|nil Internal file operations for the selected drawer section.
function M.scratchpad(name, default, store)
  require('sqmeow.rpc.events').ensure()
  store = store or require('sqmeow.ui.editor')

  -- ` :Sqmeow scratch <name>` passes the desired name directly.
  if name and vim.trim(name) ~= '' then
    local _, err = store.create(name)
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
    local _, err = store.create(input)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    require('sqmeow.ui.drawer').render()
  end)
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

return M
