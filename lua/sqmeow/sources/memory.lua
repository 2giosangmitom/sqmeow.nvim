--- Connections declared inline in `setup()`.
---
--- The simplest source, and the right one for a single database that does not deserve a file.

local M = {}

--- Read connections from the configuration.
---
---@return sqmeow.ConnectionSpec[]
---@return string|nil error
function M.load()
  return require('sqmeow.config').get().connections
end

return M
