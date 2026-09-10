--- Connections already declared for vim-dadbod.
---
--- Reads `g:dbs`, which dadbod users already have, so moving to this plugin needs no new
--- configuration. Both shapes dadbod accepts are handled: a table of names to URLs, and a list of
--- name and URL pairs.

local M = {}

--- Read connections from `g:dbs`.
---
---@return sqmeow.ConnectionSpec[]
---@return string|nil error
function M.load()
  local dbs = vim.g.dbs
  if not dbs then
    return {}
  end
  if type(dbs) ~= 'table' then
    return {}, 'g:dbs must be a table'
  end

  local connections = {}

  if vim.islist(dbs) then
    for _, entry in ipairs(dbs) do
      if type(entry) == 'table' and entry.name and entry.url then
        table.insert(connections, { name = entry.name, url = entry.url })
      end
    end
    return connections
  end

  for name, url in pairs(dbs) do
    if type(url) == 'string' then
      table.insert(connections, { name = name, url = url })
    end
  end

  -- A table has no order of its own, so sort it into one rather than let the list reshuffle
  -- between draws.
  table.sort(connections, function(left, right)
    return left.name < right.name
  end)
  return connections
end

return M
