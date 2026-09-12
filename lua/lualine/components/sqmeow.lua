--- The lualine component, under the name lualine loads components by.
---
--- `lualine_x = { 'sqmeow' }` is a string, so a lazy.nvim spec can name it without calling
--- `require` while the spec is still being read, which is before any plugin is on the runtime
--- path. That is the whole reason this file exists next to |sqmeow.lualine|: both draw the same
--- thing, and only this one can be named from a plugin spec.
---
--- Everything it shows comes from |sqmeow.status|.

local M = require('lualine.component'):extend()

function M:init(options)
  -- A default rather than a fixture. Someone who sets their own `cond` has decided when they want
  -- to see this, and hiding it on top of that would just be confusing.
  options.cond = options.cond or require('sqmeow.status').active
  M.super.init(self, options)
end

function M:update_status()
  return require('sqmeow.status').render()
end

return M
