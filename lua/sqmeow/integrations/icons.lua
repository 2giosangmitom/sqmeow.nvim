--- Icons for the things the interface names.
---
--- mini.icons first, then nvim-web-devicons, then a plain ASCII set that needs no patched font.
--- The provider is resolved once and remembered, because it cannot change without a restart and
--- resolving it per drawer line would be a `require` per row.
---
--- Every icon here is a fallback, not a lookup into a provider's own table. A provider knows about
--- file types, not about what a materialised view is, so the shapes are the plugin's own and the
--- provider only decides whether they may be glyphs at all.

local M = {}

--- Node kind to the glyph and the highlight group that goes with it.
M.glyphs = {
  connection = { icon = '󰆼', hl = 'SqmeowHeader' },
  schema = { icon = '󰙅', hl = 'SqmeowHeader' },
  table = { icon = '󰓫', hl = 'SqmeowText' },
  view = { icon = '󰈈', hl = 'SqmeowText' },
  ['materialized view'] = { icon = '󰈈', hl = 'SqmeowText' },
  relation = { icon = '󰓫', hl = 'SqmeowText' },
  column = { icon = '󰠵', hl = 'SqmeowNull' },
  query = { icon = '󰆼', hl = 'SqmeowText' },
}

--- The same set for terminals without a patched font.
M.ascii = {
  connection = { icon = '#', hl = 'SqmeowHeader' },
  schema = { icon = '@', hl = 'SqmeowHeader' },
  table = { icon = '=', hl = 'SqmeowText' },
  view = { icon = '~', hl = 'SqmeowText' },
  ['materialized view'] = { icon = '~', hl = 'SqmeowText' },
  relation = { icon = '=', hl = 'SqmeowText' },
  column = { icon = '-', hl = 'SqmeowNull' },
  query = { icon = '>', hl = 'SqmeowText' },
}

--- Dialect to its own mark, shown in the statusline and beside a connection.
M.dialects = {
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

--- The icon for a node kind.
---
---@param kind string One of the keys of `M.glyphs`, or anything else for a blank.
---@return string icon
---@return string highlight
function M.get(kind)
  local set = M.glyphs_available() and M.glyphs or M.ascii
  local entry = set[kind] or { icon = ' ', hl = 'SqmeowText' }
  return entry.icon, entry.hl
end

--- The short mark for a dialect, for places with no room for its name.
---
---@param dialect string|nil
---@return string
function M.dialect(dialect)
  return M.dialects[dialect] or (dialect or '?')
end

--- Re-detect the provider. Only useful after the configuration changes.
function M.reset()
  resolved = nil
end

return M
