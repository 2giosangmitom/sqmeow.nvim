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

--- Review the statements for staged edits. Apply them with `<C-s>` in the review.
function M.review()
  require('sqmeow.ui.edit').review()
end

--- Filter kept rows with Polars SQL WHERE + ORDER BY. Same syntax everywhere,
--- incl. disconnected and restored history. No rerun. Empty clears; kept rows only.
---@param view { where: string|nil, order_by: string|nil }
---@return boolean started
---@usage >lua
---   require('sqmeow.api.view').filter({ where = "name like 'a%'", order_by = 'age desc' })
--- <
function M.filter(view)
  return require('sqmeow.ui.result').filter(view.where or '', view.order_by or '')
end

--- Group the snapshot locally with Polars aggregates. Output is read-only,
--- exportable. Empty group_by/aggregates/having clears, source stays.
---@param view { group_by: string|nil, aggregates: string|nil, having: string|nil, where: string|nil, order_by: string|nil }
---@return boolean started
---@usage >lua
---   require('sqmeow.api.view').aggregate({
---     group_by = 'country', aggregates = 'COUNT(*) AS users, SUM(amount) AS total',
---     having = 'users >= 10', order_by = 'total DESC',
---   })
--- <
function M.aggregate(view)
  return require('sqmeow.ui.result').aggregate(view)
end

--- Filter/sort current rows in engine memory, no requery.
--- Columns are zero-based; filter without column searches all.
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

--- Browse a table's foreign keys. `gR` on a drawer table or result column.
--- Popup shows Belongs to / Referenced by, columns in order, incl. composite
--- and self-references. <CR> follows, `K` shows structure, `?` maps.
--- Remap under `keymaps.relationships`.
---
--- Empty sections show `None`; unsupported adapters and metadata failures
--- error. Needs an open connection. Close/disconnect/restart voids pending
--- replies. Never fetches rows or infers cardinality.
---@tag sqmeow-relationships
---@toc_entry Relationships
---@param conn_id integer
---@param schema string
---@param relation string
---@usage >lua
---   require('sqmeow.api.view').relationships(1, 'public', 'orders')
--- <
function M.relationships(conn_id, schema, relation)
  require('sqmeow.ui.relationships').open(conn_id, schema, relation)
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

  -- Fetch the rows without rerunning the query.
  result.render(state.call)
end

--- Show an archived result the engine dropped, from the copy next to the log.
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
    -- Restoring an archived result does not create another history entry.
    history = false,
    connection = entry.connection,
    dialect = entry.dialect,
    ran_at = entry.at,
  }
  result.update_winbar(state.call)
  return call_id
end

--- Create a scratchpad. `/` in the name makes folders.
---@param name string|nil Name with extension (`report.sql`, `reports/monthly.sql`). Given: created directly; missing: prompts.
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

--- Show everything, or hide all when anything shows.
function M.toggle()
  local layout = require('sqmeow.ui.layout')
  if layout.anything_open() then
    require('sqmeow.ui.relationships').close()
    require('sqmeow.ui.drawer').close()
    require('sqmeow.ui.result').close()
    return
  end
  M.open_all()
end

return M
