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

local db_filetypes = {
  sql = true,
  mysql = true,
  plsql = true,
  surql = true,
  cql = true,
  redis = true,
  ['sqmeow-result'] = true,
  ['sqmeow-drawer'] = true,
}

---@param bufnr integer|nil
---@return integer
local function resolve_buf(bufnr)
  if bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return vim.api.nvim_get_current_buf()
end

---@param buf integer
---@return 'result'|'drawer'|'preview'|'alter'|'routine'|'query'|nil
local function detect_role(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ft = vim.bo[buf].filetype
  local name = vim.api.nvim_buf_get_name(buf)
  if ft == 'sqmeow-result' or name:find('sqmeow://result', 1, true) then
    return 'result'
  end
  if ft == 'sqmeow-drawer' or name:find('sqmeow://drawer', 1, true) then
    return 'drawer'
  end
  if name:match('%[Preview: ') then
    return 'preview'
  end
  if name:match('%[Alter: ') then
    return 'alter'
  end
  if name:match('%[Routine: ') then
    return 'routine'
  end
  if
    db_filetypes[ft]
    or vim.b[buf].sqmeow_editor
    or vim.b[buf].sqmeow_connection
    or name:find('sqmeow://', 1, true)
  then
    return 'query'
  end
  return nil
end

---@param spec table|nil
---@param call table|nil
---@return boolean
local function is_filtered(spec, call)
  if call and call.aggregated then
    return true
  end
  if not spec then
    return false
  end
  return (spec.where or '') ~= ''
    or (spec.order_by or '') ~= ''
    or (spec.group_by or '') ~= ''
    or (spec.aggregates or '') ~= ''
    or (spec.having or '') ~= ''
    or (spec.filters and #spec.filters > 0)
    or (spec.sort and #spec.sort > 0)
    or (spec.hidden and not vim.tbl_isempty(spec.hidden))
    or false
end

--- Current connection, buffer role, and query telemetry for `bufnr`.
--- Returns nil outside database buffers. `state` and the row counts describe
--- the call whose connection matches the buffer, except in the result grid.
--- `staged_changes` counts staged edits across all open results. A column is
--- present only in the result grid.
---@param bufnr integer|nil Buffer handle; defaults to the current buffer.
---@return sqmeow.Status|nil status
---@usage >lua
---   local info = require('sqmeow.api.view').status()
---   if info then
---     print(('%s · %s'):format(info.connection or info.role, info.state or 'idle'))
---   end
--- <
function M.status(bufnr)
  local buf = resolve_buf(bufnr)
  local role = detect_role(buf)
  if not role then
    return nil
  end

  local state = require('sqmeow.core.state')
  local result = require('sqmeow.ui.result')
  local edit = require('sqmeow.ui.edit')
  local call = state.call

  local conn = nil
  if role == 'result' and call then
    if call.conn_id and state.connections[call.conn_id] then
      conn = state.connections[call.conn_id]
    elseif call.connection and call.connection ~= '' then
      conn = state.connection_by_name(call.connection)
        or { name = call.connection, dialect = call.dialect }
    end
  end
  if not conn then
    conn = require('sqmeow.api.connection').target(buf)
  end
  if not conn and vim.b[buf].sqmeow_connection then
    local pinned = vim.b[buf].sqmeow_connection
    conn = state.connection_by_name(pinned) or { name = pinned }
  end
  if not conn then
    conn = state.current_connection()
  end

  local info = {
    connection = conn and conn.name or nil,
    dialect = conn and conn.dialect or nil,
    database = conn and (conn.current_database or conn.database) or nil,
    read_only = (conn and conn.read_only == true) or false,
    role = role,
    staged_changes = edit.count(),
    filtered = false,
  }

  if role == 'result' then
    info.column = result.current_column(call)
  end

  if call then
    local call_conn = call.conn_id and state.connections[call.conn_id]
    local call_name = (call_conn and call_conn.name) or call.connection
    local matches_conn = role == 'result'
      or not info.connection
      or not call_name
      or call_name == info.connection

    if matches_conn then
      info.state = call.state
      info.rows = call.rows
      info.view_rows = call.view_rows
      info.affected = call.affected
      info.truncated = call.truncated == true
      info.elapsed_ms = call.elapsed_ms
      if call.state == 'error' then
        info.error = call.error
      end
      if call.elapsed_ms ~= nil then
        info.elapsed = result.format_duration(call.elapsed_ms)
      end
      if call.columns and #call.columns > 0 then
        local page, total = result.pages(call)
        info.page = page
        info.total_pages = total
      end
      info.filtered = is_filtered(result.spec(), call)
    end
  end

  return info
end

--- Formatted active column and SQL type when the current buffer is the result
--- grid (e.g. `󰠵 user_id (int4)`), or `''` elsewhere.
---@return string
function M.column()
  local buf = vim.api.nvim_get_current_buf()
  if detect_role(buf) ~= 'result' then
    return ''
  end
  local col = require('sqmeow.ui.result').current_column()
  if not (col and col.name and col.name ~= '') then
    return ''
  end
  local icon = require('sqmeow.core.icons').get('column')
  local prefix = (icon and icon ~= '') and (icon .. ' ') or '󰠵 '
  if col.type_name and col.type_name ~= '' then
    return ('%s%s (%s)'):format(prefix, col.name, col.type_name:lower())
  end
  return prefix .. col.name
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
--- On Neovim 0.11+, drawer and result windows use 'winfixbuf': `:edit` and jumps
--- that would replace their buffer fail with E1513. Switch to an editing window
--- first. Neovim 0.10 keeps the previous, unlocked behavior.
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
--- On a supported table, `e` opens an unexecuted in-memory scratch buffer bound
--- to that connection. Column names and current types prefill separate ALTER
--- statements; missing structure is fetched first. Edit the placeholders before
--- running them. SQLite uses rename placeholders because it cannot alter types.
--- MySQL/MariaDB MODIFY and SurrealDB OVERWRITE replace definitions: review
--- attributes not represented by the column metadata before execution.
--- On functions and procedures, `e` fetches the complete stored definition into
--- a bound scratch buffer without executing it. Overloads are shown together.
--- Source retrieval supports PostgreSQL, MySQL/MariaDB, SQL Server, Oracle,
--- ClickHouse SQL functions and SurrealDB functions. Missing, encrypted or
--- unsupported definitions report an error. Source keeps the database's DDL;
--- review CREATE/ALTER syntax and schema qualification before running edits.
--- `K` on a function or procedure shows its full definition (signature and body)
--- in a read-only popup instead, using the same supported source retrieval.
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
