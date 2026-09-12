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
  disconnected = 'SqmeowDisconnected',
  ['function'] = 'SqmeowIconFunction',
  procedure = 'SqmeowIconProcedure',
  tables = 'SqmeowIconTable',
  views = 'SqmeowIconView',
  functions = 'SqmeowIconFunction',
  procedures = 'SqmeowIconProcedure',
  postgres = 'SqmeowIconPostgres',
  mysql = 'SqmeowIconMysql',
  sqlite = 'SqmeowIconSqlite',
}

--- The icon for a kind, and the group it is drawn in.
---
---@param kind string A key of `M.highlights`, or anything else for a blank.
---@return string icon
---@return string highlight
function M.get(kind)
  local icon = configured()[kind]
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
