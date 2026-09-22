--- Resolves icons for labelled interface elements.

local M = {}

local function configured()
  return require('sqmeow.config').get().icons
end

--- Highlight group for each icon kind.
---
--- Override the group to recolour one: >lua
---   vim.api.nvim_set_hl(0, 'SqmeowIconTable', { fg = '#7aa2f7' })
--- <
M.highlights = {
  connection = 'SqmeowIconConnection',
  database = 'SqmeowIconSchema',
  schema = 'SqmeowIconSchema',
  table = 'SqmeowIconTable',
  view = 'SqmeowIconView',
  ['materialized view'] = 'SqmeowIconView',
  relation = 'SqmeowIconTable',
  column = 'SqmeowIconColumn',
  scratchpads = 'SqmeowIconScratchpad',
  scratchpad = 'SqmeowIconScratchpad',
  query = 'SqmeowIconQuery',
  history = 'SqmeowIconHistory',
  elapsed = 'SqmeowIconElapsed',
  connected = 'SqmeowConnected',
  connecting = 'SqmeowConnecting',
  error = 'SqmeowConnectionError',
  disconnected = 'SqmeowDisconnected',
  ['function'] = 'SqmeowIconFunction',
  procedure = 'SqmeowIconProcedure',
  tables = 'SqmeowIconTable',
  views = 'SqmeowIconView',
  functions = 'SqmeowIconFunction',
  procedures = 'SqmeowIconProcedure',
  keys = 'SqmeowIconKey',
  key = 'SqmeowIconKey',
  sequences = 'SqmeowIconTable',
  sequence = 'SqmeowIconTable',
  roles = 'SqmeowIconSchema',
  role = 'SqmeowIconSchema',
  postgres = 'SqmeowIconPostgres',
  mysql = 'SqmeowIconMysql',
  sqlite = 'SqmeowIconSqlite',
  duckdb = 'SqmeowIconDuckdb',
  redis = 'SqmeowIconRedis',
  mongodb = 'SqmeowIconMongodb',
  scylla = 'SqmeowIconScylla',
  surrealdb = 'SqmeowIconSurrealdb',
  clickhouse = 'SqmeowIconClickhouse',
  oracle = 'SqmeowIconOracle',

  -- What a column holds, or the key it is.
  text = 'SqmeowIconTypeText',
  number = 'SqmeowIconTypeNumber',
  boolean = 'SqmeowIconTypeBoolean',
  temporal = 'SqmeowIconTypeTemporal',
  json = 'SqmeowIconTypeJson',
  uuid = 'SqmeowIconTypeUuid',
  binary = 'SqmeowIconTypeBinary',
  unknown = 'SqmeowIconTypeUnknown',
  primary_key = 'SqmeowIconKeyPrimary',
  foreign_key = 'SqmeowIconKeyForeign',
}

--- Returns the icon and highlight group for a kind.
---@param kind string A key of `M.highlights`, or anything else for a blank.
---@return string icon
---@return string highlight
function M.get(kind)
  local icon = configured()[kind]
  -- The type classes and the two key kinds live in their own table.
  if icon == nil then
    icon = (configured().types or {})[kind]
  end
  -- `icons` also holds the marker and grid tables, and a caller asking for one of those by mistake
  -- should get a space rather than a table where a line is being built.
  if type(icon) ~= 'string' then
    icon = ' '
  end
  return icon, M.highlights[kind] or 'SqmeowText'
end

--- Returns the markers drawn before a drawer row.
---@return { open: string, closed: string, leaf: string }
function M.markers()
  return configured().markers
end

--- Returns which icon a drawer column is drawn with.
---@param node table A drawer column node, carrying `class` and possibly `references`.
---@return string kind A key of `M.highlights`.
function M.column_kind(node)
  if node.primary_key then
    return 'primary_key'
  end
  if node.references then
    return 'foreign_key'
  end
  return node.class or 'unknown'
end

--- Returns which icon a connection shows.
---@param dialect string|nil
---@return string kind A key of `M.highlights`.
function M.connection_kind(dialect)
  return (dialect and M.highlights[dialect]) and dialect or 'connection'
end

return M
