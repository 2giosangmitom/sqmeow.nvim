--- Browse declared foreign keys one table at a time; never query selected row values.
--- No cardinality or many-to-many inference.

local M = {}

local popup, wanted, current
local entries = {}
local sequence = 0
local notify = require('sqmeow.core.utils').notify

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
  local connection = require('sqmeow.core.state').connections[payload.conn_id]
  if not connection or connection.state ~= 'connected' then
    return M.close()
  end
  wanted = nil
  if payload.error then
    return show({ 'Relationships unavailable', '  ' .. payload.error })
  end
  local lines, targets = M.lines(payload)
  show(lines, targets)
end

return M
