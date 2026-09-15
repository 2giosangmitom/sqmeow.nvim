--- Where connections come from.

local M = {}

---@class sqmeow.ConnectionSpec
---@field name string
---@field url string
---@field read_only boolean|nil Runs only statements that read.
---@field ssh string|nil The `user@host` an SSH tunnel to the database goes through.
---@field source string|nil Which source it came from.

--- The sources that ship with the plugin.
---@type table<string, { load: fun(opts: table|nil): sqmeow.ConnectionSpec[], string|nil }>
M.builtin = {
  command = require('sqmeow.sources.command'),
  env = require('sqmeow.sources.env'),
  file = require('sqmeow.sources.file'),
}

local function valid(entry)
  return type(entry) == 'table'
    and type(entry.name) == 'string'
    and entry.name ~= ''
    and type(entry.url) == 'string'
    and entry.url ~= ''
end

--- Read every configured source.
---@return sqmeow.ConnectionSpec[] connections In configured order, names unique.
---@return string[] problems Everything that went wrong.
function M.load()
  local config = require('sqmeow.config').get()
  local connections = {}
  local problems = {}
  local seen = {}

  for _, spec in ipairs(config.sources) do
    local source = M.builtin[spec.type]

    if not source then
      table.insert(problems, ('unknown source type `%s`'):format(tostring(spec.type)))
    else
      local found, err = source.load(spec)
      if err then
        table.insert(problems, err)
      end

      for _, entry in ipairs(found or {}) do
        if not valid(entry) then
          table.insert(problems, ('%s: a connection needs a name and a url'):format(spec.type))
        elseif seen[entry.name] then
          table.insert(
            problems,
            ('two connections are named `%s`, from %s and %s'):format(
              entry.name,
              seen[entry.name],
              spec.type
            )
          )
        else
          seen[entry.name] = spec.type
          table.insert(connections, {
            name = entry.name,
            url = entry.url,
            read_only = entry.read_only == true or nil,
            ssh = type(entry.ssh) == 'string' and entry.ssh ~= '' and entry.ssh or nil,
            source = spec.type,
          })
        end
      end
    end
  end

  return connections, problems
end

--- Find one connection by name.
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

--- The options of the configured file source.
local function writable()
  for _, spec in ipairs(require('sqmeow.config').get().sources) do
    if spec.type == 'file' then
      return spec
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
  }, writable())
end

--- Change a saved connection, by the name it is saved under.
---@param name string
---@param connection sqmeow.ConnectionSpec The name and url to save instead.
---@return boolean written
---@return string|nil error
function M.update(name, connection)
  return require('sqmeow.sources.file').update(name, connection, writable())
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
  return require('sqmeow.sources.file').remove(name, writable())
end

return M
