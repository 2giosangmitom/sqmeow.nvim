--- Where connections come from.
---
--- Source modules load definitions; this module owns name uniqueness, provenance,
--- and write routing. Definitions can exist without a live database connection.

local M = {}

---@class sqmeow.ConnectionSpec
---@field name string
---@field url string
---@field read_only boolean|nil Runs only statements that read.
---@field ssh string|nil The `user@host` an SSH tunnel to the database goes through.
---@field source string|nil Which source it came from.
---@field env_file string|nil Project-local dotenv path, resolved only in the engine.

--- The sources that ship with the plugin.
---@type table<string, { load: fun(opts: table|nil): sqmeow.ConnectionSpec[], string|nil }>
M.builtin = {
  file = require('sqmeow.sources.file'),
  project = require('sqmeow.sources.project'),
}

local function valid(entry)
  return type(entry) == 'table'
    and type(entry.name) == 'string'
    and entry.name ~= ''
    and type(entry.url) == 'string'
    and entry.url ~= ''
end

--- Read project definitions, then saved connections. Both sources are always enabled.
--- The first valid entry for a name wins. Invalid entries and source failures
--- are collected as problems without discarding entries from other sources.
---@return sqmeow.ConnectionSpec[] connections In source order, names unique.
---@return string[] problems Everything that went wrong.
function M.load()
  local connections = {}
  local problems = {}
  local seen = {}

  for _, name in ipairs({ 'project', 'file' }) do
    local found, err = M.builtin[name].load()
    if err then
      table.insert(problems, err)
    end

    for _, entry in ipairs(found or {}) do
      if not valid(entry) then
        table.insert(problems, ('%s: a connection needs a name and a url'):format(name))
      elseif seen[entry.name] then
        table.insert(
          problems,
          ('two connections are named `%s`, from %s and %s'):format(
            entry.name,
            seen[entry.name],
            name
          )
        )
      else
        seen[entry.name] = name
        table.insert(connections, {
          name = entry.name,
          url = entry.url,
          read_only = entry.read_only == true or nil,
          ssh = type(entry.ssh) == 'string' and entry.ssh ~= '' and entry.ssh or nil,
          source = name,
          env_file = entry.env_file,
        })
      end
    end
  end

  return connections, problems
end

--- Reload sources and find the first accepted definition with this name.
--- Discards source diagnostics; callers needing them should use load() directly.
---@param name string
---@return sqmeow.ConnectionSpec|nil
function M.find(name)
  for _, connection in ipairs((M.load())) do
    if connection.name == name then
      return connection
    end
  end
  return nil
end

--- Save a connection to the file source.
---@param connection sqmeow.ConnectionSpec
---@return boolean written
---@return string|nil error
function M.save(connection)
  return require('sqmeow.sources.file').add({
    name = connection.name,
    url = connection.url,
    read_only = connection.read_only,
    ssh = connection.ssh,
  })
end

--- Update a file-source entry by its existing name, preserving other entries.
--- Refuses an entry whose winning definition came from a read-only source,
--- even when the JSON file contains a shadowed connection of the same name.
---@param name string
---@param connection sqmeow.ConnectionSpec The name and url to save instead.
---@return boolean written
---@return string|nil error
function M.update(name, connection)
  local spec = M.find(name)
  if spec and spec.source ~= 'file' then
    return false, ('`%s` comes from %s, so it cannot be edited'):format(name, spec.source)
  end
  return require('sqmeow.sources.file').update(name, connection)
end

--- Delete a saved connection, by the name it is saved under. Only the file source is writable,
--- so a connection from any other source cannot be deleted.
---@param name string
---@return boolean written
---@return string|nil error
function M.remove(name)
  local spec = M.find(name)
  if not spec then
    return false, ('there is no configured connection named `%s`'):format(name)
  end
  if spec.source ~= 'file' then
    return false, ('`%s` comes from %s, so it cannot be deleted'):format(name, spec.source)
  end
  return require('sqmeow.sources.file').remove(name)
end

return M
