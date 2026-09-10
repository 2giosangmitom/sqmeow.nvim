--- Where connections come from.
---
--- Sources are read in the order they are configured, and every one contributes. A later source
--- does not shadow an earlier one: a duplicate name is reported, because two different databases
--- answering to one name is a mistake worth seeing rather than a preference to resolve silently.

local M = {}

---@class sqmeow.ConnectionSpec
---@field name string
---@field url string
---@field source string|nil Which source it came from. Added by the loader.

--- The sources that ship with the plugin.
---@type table<string, { load: fun(opts: table|nil): sqmeow.ConnectionSpec[], string|nil }>
M.builtin = {
  memory = require('sqmeow.sources.memory'),
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
---
---@return sqmeow.ConnectionSpec[] connections In configured order, names unique.
---@return string[] problems Everything that went wrong, so one call reports it all.
function M.load()
  local config = require('sqmeow.config').get()
  local connections = {}
  local problems = {}
  local seen = {}

  -- Inline connections are a memory source whether or not one was configured, so `connections`
  -- in `setup()` works on its own.
  local configured = vim.deepcopy(config.sources)
  if #config.connections > 0 then
    table.insert(configured, 1, { type = 'memory' })
  end

  for _, spec in ipairs(configured) do
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
          table.insert(connections, { name = entry.name, url = entry.url, source = spec.type })
        end
      end
    end
  end

  return connections, problems
end

--- Find one connection by name.
---
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
---
---@param connection sqmeow.ConnectionSpec
---@return boolean written
---@return string|nil error
function M.save(connection)
  local opts
  for _, spec in ipairs(require('sqmeow.config').get().sources) do
    if spec.type == 'file' then
      opts = spec
      break
    end
  end

  return require('sqmeow.sources.file').add({ name = connection.name, url = connection.url }, opts)
end

return M
