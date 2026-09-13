--- Icons for the things the interface names.
---
--- Every glyph the plugin draws is a Nerd Font one and every one of them lives in the `icons`
--- table of the configuration, so a terminal without a patched font is dressed by setting them
--- rather than by the plugin guessing. Nothing is detected and no icon plugin is consulted:
--- mini.icons and nvim-web-devicons map file types, and none of these is a file.
---
--- Icons are the user's to change; highlight groups are not. A group is how a colourscheme reaches
--- the icon, so it stays fixed and the colour is changed by redefining the group.

local M = {}

local function configured()
  return require('sqmeow.config').get().icons
end

--- Every kind the interface draws an icon for, and the group that colours it.
---
--- Not settable through `setup()`. Override the group itself instead, which is the ordinary way to
--- recolour anything in Neovim and works for every colourscheme at once: >lua
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
  postgres = 'SqmeowIconPostgres',
  mysql = 'SqmeowIconMysql',
  sqlite = 'SqmeowIconSqlite',
  redis = 'SqmeowIconRedis',

  -- What a column holds, or the key it is. The engine puts these in the grid header itself; the
  -- drawer draws them from here, so a column reads the same in both places.
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

--- The icon for a kind, and the group it is drawn in.
---
---@param kind string A key of `M.highlights`, or anything else for a blank.
---@return string icon
---@return string highlight
function M.get(kind)
  local icon = configured()[kind]
  -- The type classes and the two key kinds live in their own table, since `icons` already has a
  -- `column` of its own for the drawer's column rows.
  if icon == nil then
    icon = (configured().types or {})[kind]
  end
  -- `icons` also holds the marker and grid tables, and a caller asking for one of those
  -- by mistake should get a space rather than a table where a line is being built.
  if type(icon) ~= 'string' then
    icon = ' '
  end
  return icon, M.highlights[kind] or 'SqmeowText'
end

--- What sits before a drawer row, by whether it is open, closed, or has no children.
---@return { open: string, closed: string, leaf: string }
function M.markers()
  return configured().markers
end

--- Which icon a drawer column is drawn with.
---
--- A key wins over a type, the same way round as in the grid header: that a column is what rows
--- are found by is more useful than what it is stored as. A column the engine could not classify
--- falls back to `unknown`, whose glyph says only that.
---
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

--- Which icon a connection shows.
---
--- Its dialect's own where the plugin has one, and a plain database otherwise, so a drawer holding
--- three dialects tells them apart without reading a word.
---
---@param dialect string|nil
---@return string kind A key of `M.highlights`.
function M.connection_kind(dialect)
  return (dialect and M.highlights[dialect]) and dialect or 'connection'
end

return M
