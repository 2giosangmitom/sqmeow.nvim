--- Browse declared foreign keys one table at a time; never query selected row values.
--- No cardinality or many-to-many inference.

local M = {}

local popup, wanted, current
local entries = {}
local sequence = 0
local notify = require('sqmeow.core.utils').notify

--- A result cell whose foreign key the user wants to follow.
---@class sqmeow.FollowSpec
---@field conn_id integer
---@field schema string
---@field relation string
---@field direction 'outgoing'|'incoming'
---@field column string The table column under the cursor, not the result header.
---@field dialect string|nil
---@field call_id integer
---@field row integer Zero-based retained row.
---@field columns { index: integer, name: string }[] Result columns bound to the table.
---@field staged table<integer, boolean>|nil Result columns with staged changes.

local function qualified(schema, relation)
  return schema == '' and relation or (schema .. '.' .. relation)
end

--- Render both directions, keeping each constraint and its ordered column mapping.
---@param payload table
---@return string[] lines
---@return table<integer, table> targets Table to browse for each selectable line.
function M.lines(payload)
  local lines, targets = {}, {}
  -- The request identity stays unqualified; metadata names use the resolved schema.
  local resolved_schema = payload.resolved_schema or payload.schema
  local resolved_relation = payload.resolved_relation or payload.relation
  for _, direction in ipairs({ 'Belongs to', 'Referenced by' }) do
    if #lines > 0 then
      table.insert(lines, '')
    end
    table.insert(lines, direction)
    local count = 0
    for _, key in ipairs(payload.relationships or {}) do
      local outgoing = direction == 'Belongs to'
      local schema = outgoing and key.source_schema or key.target_schema
      local relation = outgoing and key.source_relation or key.target_relation
      if schema == resolved_schema and relation == resolved_relation then
        count = count + 1
        local other_schema = outgoing and key.target_schema or key.source_schema
        local other_relation = outgoing and key.target_relation or key.source_relation
        local target = { schema = other_schema, relation = other_relation }
        local name = key.name ~= '' and key.name or '(unnamed)'
        local self = key.source_schema == key.target_schema
          and key.source_relation == key.target_relation
        table.insert(
          lines,
          ('  %s: %s%s'):format(
            name,
            qualified(other_schema, other_relation),
            self and ' (self)' or ''
          )
        )
        targets[#lines] = target
        for index, column in ipairs(key.columns) do
          table.insert(
            lines,
            ('    %s.%s → %s.%s'):format(
              qualified(key.source_schema, key.source_relation),
              column,
              qualified(key.target_schema, key.target_relation),
              key.referenced[index]
            )
          )
          targets[#lines] = target
        end
      end
    end
    if count == 0 then
      table.insert(lines, '  None')
    end
  end
  return lines, targets
end

--- Close and invalidate any outstanding request, including while loading.
function M.close()
  wanted, current = nil, nil
  entries = {}
  local closing = popup
  popup = nil
  if closing then
    closing:unmount()
  end
end

--- Forget metadata when its connection is removed.
---@param conn_id integer
function M.invalidate(conn_id)
  if current and current.conn_id == conn_id then
    M.close()
  end
end

M.actions = {}

local function selected()
  if not (popup and current) then
    return
  end
  local target = entries[vim.api.nvim_win_get_cursor(popup.winid)[1]]
  if target then
    return current.conn_id, target.schema, target.relation
  end
end

--- Request only the selected endpoint, so cycles and self-references are safe.
function M.actions.browse()
  local conn_id, schema, relation = selected()
  if conn_id and schema and relation then
    M.open(conn_id, schema, relation)
  end
end

function M.actions.structure()
  local conn_id, schema, relation = selected()
  if conn_id and schema and relation then
    M.close()
    require('sqmeow.ui.structure').open(conn_id, schema, relation)
  end
end

M.actions.close = M.close
function M.actions.help()
  require('sqmeow.ui.help').open('relationships')
end

local function show(lines, targets)
  local closing = popup
  popup = nil
  if closing then
    closing:unmount()
  end
  entries = targets or {}
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line) + 2)
  end
  local opened, err
  opened, err = require('sqmeow.ui.popup').open({
    title = (' Relationships: %s '):format(qualified(current.schema, current.relation)),
    lines = lines,
    width = math.min(width, math.floor(vim.o.columns * 0.9)),
    height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.8))),
    filetype = 'sqmeow-relationships',
    close_maps = false,
    on_close = function()
      if popup == opened then
        M.close()
      end
    end,
  })
  if not opened then
    M.close()
    return notify(err or 'could not open the popup', vim.log.levels.ERROR)
  end
  popup = opened
  require('sqmeow.keymap').apply('relationships', popup.bufnr, M.actions)
end

--- Browse a table's declared outgoing and incoming foreign keys.
--- `<CR>` on a constraint browses the other table; `K` shows its structure.
--- `gR` in the drawer or result opens this browser. Empty sections say `None`;
--- unsupported adapters and metadata failures show an explicit error.
---@param conn_id integer Connected database id.
---@param schema string Exact schema (empty for schema-less adapters).
---@param relation string Table name.
function M.open(conn_id, schema, relation)
  M.close()
  local connection = require('sqmeow.core.state').connections[conn_id]
  if not connection or connection.state ~= 'connected' then
    return notify('relationship browsing needs an open connection', vim.log.levels.WARN)
  end
  require('sqmeow.rpc.events').ensure()
  sequence = sequence + 1
  wanted = { conn_id = conn_id, schema = schema, relation = relation, request_id = sequence }
  current = wanted
  show({ 'Loading relationships…' })
  if not wanted then
    return
  end
  local _, err = require('sqmeow.rpc.client').request('relationships', wanted)
  if err and wanted then
    M.on_done(vim.tbl_extend('force', wanted, { error = err }))
  end
end

--- Compare two SQL identifiers case-insensitively.
---@param a string|nil
---@param b string|nil
---@return boolean
local function same_ident(a, b)
  return a == b or (type(a) == 'string' and type(b) == 'string' and a:lower() == b:lower())
end

--- Check whether a list of identifier names contains `name` (case-insensitive).
---@param list string[]|nil
---@param name string
---@return boolean
local function list_contains(list, name)
  for _, item in ipairs(list or {}) do
    if same_ident(item, name) then
      return true
    end
  end
  return false
end

--- The zero-based result column showing `name` on the table, matched case-insensitively.
---@param columns { index: integer, name: string }[]|nil
---@param name string
---@return integer|nil
local function column_index(columns, name)
  for _, entry in ipairs(columns or {}) do
    if same_ident(entry.name, name) then
      return entry.index
    end
  end
end

--- Run the drilldown for a chosen foreign key.
---@param drilldown sqmeow.FollowSpec
---@param choice { parts: string[], columns: { index: integer, column: string, source: string }[] }
local function execute_drilldown(drilldown, choice)
  -- The engine reads the retained cells, so types, exact digits, aliases, and dialect
  -- quoting stay right even when the grid shows escaped text.
  local conditions, err = require('sqmeow.rpc.client').request('key_conditions', {
    call_id = drilldown.call_id,
    row = drilldown.row,
    columns = choice.columns,
  })
  if not conditions then
    return notify(err or 'the row could not be matched', vim.log.levels.WARN)
  end
  local sql = require('sqmeow.core.sql').select_where(drilldown.dialect, choice.parts, conditions)
  require('sqmeow.api.query').execute(sql, { conn_id = drilldown.conn_id })
end

--- Match a `relationships` RPC response against a pending cell drilldown and execute or prompt.
---@param payload table
---@param drilldown sqmeow.FollowSpec
local function handle_drilldown(payload, drilldown)
  if payload.error then
    return notify(
      ('the relationships could not be read: %s'):format(payload.error),
      vim.log.levels.ERROR
    )
  end
  local resolved_schema = payload.resolved_schema or payload.schema
  local resolved_relation = payload.resolved_relation or payload.relation
  local outgoing = drilldown.direction == 'outgoing'
  local matches = {}
  local incomplete = false
  local blocked = nil

  for _, key in ipairs(payload.relationships or {}) do
    local schema = outgoing and key.source_schema or key.target_schema
    local relation = outgoing and key.source_relation or key.target_relation
    local cols = outgoing and key.columns or key.referenced
    if
      schema == resolved_schema
      and relation == resolved_relation
      and list_contains(cols, drilldown.column)
    then
      local other_schema = outgoing and key.target_schema or key.source_schema
      local other_relation = outgoing and key.target_relation or key.source_relation
      local parts = other_schema ~= '' and { other_schema, other_relation } or { other_relation }
      local columns = {}
      local complete = true
      local staged = nil
      for index, col_name in ipairs(cols) do
        local target_col = outgoing and key.referenced[index] or key.columns[index]
        local at = column_index(drilldown.columns, col_name)
        if not target_col or at == nil then
          complete = false
        elseif drilldown.staged and drilldown.staged[at] then
          staged = staged or col_name
        else
          table.insert(columns, { index = at, column = target_col, source = col_name })
        end
      end

      if staged then
        blocked = blocked or staged
      elseif complete and #columns > 0 then
        local name = key.name ~= '' and key.name or '(unnamed)'
        local label = ('%s (%s: %s.%s → %s.%s)'):format(
          qualified(other_schema, other_relation),
          name,
          qualified(key.source_schema, key.source_relation),
          table.concat(key.columns, ', '),
          qualified(key.target_schema, key.target_relation),
          table.concat(key.referenced, ', ')
        )
        table.insert(matches, {
          label = label,
          parts = parts,
          columns = columns,
        })
      else
        incomplete = true
      end
    end
  end

  if #matches == 0 then
    if blocked then
      return notify(
        ('apply the staged change to `%s` before following its foreign key'):format(blocked),
        vim.log.levels.WARN
      )
    end
    if incomplete then
      return notify(
        ('`%s` needs every column of its foreign key in this result'):format(drilldown.column),
        vim.log.levels.WARN
      )
    end
    local table_label = qualified(resolved_schema, resolved_relation)
    if outgoing then
      return notify(
        ('`%s` has no outgoing foreign key on %s'):format(drilldown.column, table_label),
        vim.log.levels.WARN
      )
    end
    return notify(
      ('no foreign keys reference `%s` on %s'):format(drilldown.column, table_label),
      vim.log.levels.WARN
    )
  end

  if #matches == 1 then
    return execute_drilldown(drilldown, matches[1])
  end

  vim.ui.select(matches, {
    prompt = outgoing and 'Follow foreign key:' or 'Referenced by:',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      execute_drilldown(drilldown, choice)
    end
  end)
end

--- Follow an outgoing (`gd`) or incoming (`gr`) foreign key from a result cell.
---@param spec sqmeow.FollowSpec
function M.follow(spec)
  M.close()
  local connection = require('sqmeow.core.state').connections[spec.conn_id]
  if not connection or connection.state ~= 'connected' then
    return notify('relationship navigation needs an open connection', vim.log.levels.WARN)
  end
  require('sqmeow.rpc.events').ensure()
  sequence = sequence + 1
  local request = {
    conn_id = spec.conn_id,
    schema = spec.schema,
    relation = spec.relation,
    request_id = sequence,
  }
  wanted = vim.tbl_extend('force', request, { drilldown = spec })
  local _, err = require('sqmeow.rpc.client').request('relationships', request)
  if err and wanted then
    M.on_done(vim.tbl_extend('force', request, { error = err }))
  end
end

--- Drop stale answers, even for a repeated request for the same table.
---@param payload table
function M.on_done(payload)
  if not wanted then
    return
  end
  for _, key in ipairs({ 'conn_id', 'schema', 'relation', 'request_id' }) do
    if payload[key] ~= wanted[key] then
      return
    end
  end
  local drilldown = wanted.drilldown
  local connection = require('sqmeow.core.state').connections[payload.conn_id]
  if not connection or connection.state ~= 'connected' then
    return M.close()
  end
  wanted = nil
  if drilldown then
    return handle_drilldown(payload, drilldown)
  end
  if payload.error then
    return show({ 'Relationships unavailable', '  ' .. payload.error })
  end
  local lines, targets = M.lines(payload)
  show(lines, targets)
end

return M
