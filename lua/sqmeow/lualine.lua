--- A lualine component.
---
--- Added by the user, never by the plugin: a statusline is theirs to arrange, and a plugin that
--- inserts itself into one is a plugin that has to be undone.
---
--- Prefer naming it as a string, `lualine_x = { 'sqmeow' }`, which reaches the same component
--- through the runtime path. A lazy.nvim spec is read before any plugin is on that path, so a
--- `require` inside an `opts` table runs too early. This module is for configuring lualine
--- somewhere a `require` is safe.
---
---@usage >lua
---   require('lualine').setup({
---     sections = { lualine_x = { require('sqmeow.lualine') } },
---   })
--- <
---
--- Everything it shows comes from |sqmeow.status|, so heirline, mini.statusline, and a plain
--- `'statusline'` expression can show the same thing without this file.

local status = require('sqmeow.status')

--- The component. lualine calls it on every redraw, so it does no work beyond reading the
--- snapshot and formatting it.
---@return string
local function component()
  return status.render()
end

return {
  component,
  -- Nothing to show until there is a connection, which keeps the statusline unchanged for anyone
  -- who has the plugin installed and is not using it.
  cond = status.active,
}
