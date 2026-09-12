--- Icons for the things the interface names.
---
--- mini.icons first, then nvim-web-devicons, then a plain ASCII set that needs no patched font.
--- Neither provider is asked what a materialised view looks like, because neither knows: they map
--- file types, and these are database objects. What the provider decides is whether a patched font
--- is present at all, and therefore whether the glyph set or the ASCII set is used.
---
--- The provider is resolved once and remembered, because it cannot change without a restart and
--- resolving it per drawer line would be a `require` per row.
---
--- Icons are the user's to change; highlight groups are not. A group is how a colourscheme reaches
--- the icon, so it stays fixed and the colour is changed by redefining the group.

local M = {}

--- Every kind the interface draws an icon for, and the group that colours it.
---
--- Not overridable through `setup()`. Override the group itself instead, which is the ordinary way
--- to recolour anything in Neovim and works for every colourscheme at once: >lua
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
  postgres = 'SqmeowIconPostgres',
  mysql = 'SqmeowIconMysql',
  sqlite = 'SqmeowIconSqlite',
}

--- Nerd font glyphs, used when a font that has them is present.
M.nerd = {
  connection = '󰆼',
  schema = '󰙅',
  table = '󰓫',
  view = '󰈈',
  ['materialized view'] = '󰈈',
  relation = '󰓫',
  column = '󰠵',
  scratchpads = '󰉋',
  scratchpad = '󰈙',
  query = '󰐊',
  postgres = '',
  mysql = '',
  sqlite = '',
}

--- The same set for terminals without a patched font.
---
--- Every one of these is a single display column, so a tree drawn with them lines up exactly as
--- one drawn with glyphs does.
M.ascii = {
  connection = '#',
  schema = '@',
  table = '=',
  view = '~',
  ['materialized view'] = '~',
  relation = '=',
  column = '-',
  scratchpads = '+',
  scratchpad = '*',
  query = '>',
  postgres = 'p',
  mysql = 'm',
  sqlite = 's',
}

--- What a dialect is called where there is no room for its name and no font for its glyph.
M.abbreviations = {
  postgres = 'pg',
  mysql = 'my',
  sqlite = 'sq',
}

local resolved = nil

local function detect()
  if pcall(require, 'mini.icons') then
    return 'mini'
  end
  if pcall(require, 'nvim-web-devicons') then
    return 'devicons'
  end
  return 'ascii'
end

--- Which provider is in use.
---
--- `auto` means whichever of mini.icons and nvim-web-devicons is installed, and ASCII when
--- neither is. Naming one explicitly is honoured even if it is not installed, since a user asking
--- for ASCII has no plugin to detect.
---
---@return 'mini'|'devicons'|'ascii'
function M.provider()
  if resolved then
    return resolved
  end

  local configured = require('sqmeow.config').get().integrations.icons
  resolved = configured == 'auto' and detect() or configured
  return resolved
end

--- Whether icons are glyphs rather than plain characters.
---@return boolean
function M.glyphs_available()
  return M.provider() ~= 'ascii'
end

--- The icon for a kind, after the user's overrides.
---
--- An override applies whichever set is in use, because someone who writes one has decided what
--- they want to see and is not asking to be second-guessed about their font.
---
---@param kind string A key of `M.highlights`, or anything else for a blank.
---@return string icon
---@return string highlight
function M.get(kind)
  local overrides = require('sqmeow.config').get().integrations.icon_overrides or {}
  local set = M.glyphs_available() and M.nerd or M.ascii

  return overrides[kind] or set[kind] or ' ', M.highlights[kind] or 'SqmeowText'
end

--- The mark for a dialect.
---
--- Its glyph where there is a font for one, its two-letter abbreviation where there is not, and
--- the dialect's own name for one this plugin has never heard of.
---
---@param dialect string|nil
---@return string icon
---@return string highlight
function M.dialect(dialect)
  if not dialect then
    return '?', 'SqmeowNull'
  end

  local overrides = require('sqmeow.config').get().integrations.icon_overrides or {}
  if overrides[dialect] then
    return overrides[dialect], M.highlights[dialect] or 'SqmeowText'
  end

  if M.glyphs_available() and M.nerd[dialect] then
    return M.nerd[dialect], M.highlights[dialect]
  end
  return M.abbreviations[dialect] or dialect, M.highlights[dialect] or 'SqmeowText'
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

--- Overrides that name a kind the plugin does not draw.
---
--- Reported by `:checkhealth` rather than ignored, because a mistyped kind looks exactly like an
--- override that refuses to work.
---
---@return string[]
function M.problems()
  local problems = {}

  for kind, icon in pairs(require('sqmeow.config').get().integrations.icon_overrides or {}) do
    if M.highlights[kind] == nil then
      table.insert(problems, ('there is no `%s` icon to override'):format(kind))
    elseif type(icon) ~= 'string' then
      table.insert(problems, ('the `%s` icon must be a string, got %s'):format(kind, type(icon)))
    end
  end

  table.sort(problems)
  return problems
end

--- Re-detect the provider. Only useful after the configuration changes.
function M.reset()
  resolved = nil
end

return M
