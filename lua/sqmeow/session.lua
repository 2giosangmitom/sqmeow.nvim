--- Persists open connections and drawer expansion across restarts.
---
--- When `ui.persist_session` is on, the set of open connection names, the
--- current connection, and the expanded drawer paths are saved to
--- `session.json` on `VimLeavePre` and restored once on next `open_drawer`.

local M = {}

--- Drawer nodes to open once their connection is up, by connection name.
local pending = {}
local restored = false

local function path()
  return vim.fs.joinpath(require('sqmeow.paths').root(), 'session.json')
end

--- Saves the current session to disk.
function M.save()
  local state = require('sqmeow.state')
  local sources = require('sqmeow.sources')
  local connections = {}
  for _, connection in ipairs(state.connection_list()) do
    -- Only a saved connection can be opened again by its name.
    if not connection.parent and sources.find(connection.name) then
      table.insert(connections, connection.name)
    end
  end

  local current = state.current_connection()
  local session = {
    connections = connections,
    current = current and current.name or nil,
    expanded = require('sqmeow.ui.drawer').expanded_paths(),
  }
  vim.fn.mkdir(require('sqmeow.paths').root(), 'p')
  vim.fn.writefile({ vim.json.encode(session) }, path())
end

--- Restores the last session's connections and drawer state.
---
--- Only the first call does anything; subsequent calls are no-ops.
function M.restore()
  if restored then
    return
  end
  restored = true

  local read, lines = pcall(vim.fn.readfile, path())
  if not read then
    return
  end
  local decoded, session = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not decoded or type(session) ~= 'table' then
    return
  end

  for _, entry in ipairs(session.expanded or {}) do
    pending[entry.connection] = pending[entry.connection] or {}
    table.insert(pending[entry.connection], entry.path)
  end

  local state = require('sqmeow.state')
  for _, name in ipairs(session.connections or {}) do
    local open = state.connection_by_name(name)
    local id = open and open.id or require('sqmeow.api').connect_named(name)
    if id and name == session.current then
      state.current = id
    end
    if open and open.state == 'connected' then
      M.connected(open)
    end
  end
end

--- Expands pending drawer nodes once `connection` is available.
---@param connection sqmeow.Connection
function M.connected(connection)
  local paths = pending[connection.name]
  if not paths then
    return
  end
  pending[connection.name] = nil

  -- Shallowest first, so a level is asked for before the levels inside it.
  table.sort(paths, function(left, right)
    return #left < #right
  end)
  local drawer = require('sqmeow.ui.drawer')
  for _, node in ipairs(paths) do
    drawer.expand(connection.id, node)
  end
  drawer.render()
end

return M
