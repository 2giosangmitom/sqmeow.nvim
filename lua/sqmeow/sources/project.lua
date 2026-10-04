--- Connections from the nearest project's TOML file.
---
--- Lua discovers files and validates fields; the engine decodes TOML and rejects exec directives.
--- Loading is read-only and uncached so directory/config changes are visible on
--- the next source read. A malformed entry rejects the whole project source.

local M = {}

--- Find the nearest config, starting at the window's working directory on each load.
--- Uses getcwd(), including :lcd/:tcd, rather than the current buffer's directory.
--- Stops at the first existing candidate; it does not merge ancestor configs.
---@return string|nil path Absolute config path, or nil if no candidate exists.
function M.path()
  local directory = vim.fn.getcwd()
  while directory do
    local path = vim.fs.joinpath(directory, '.sqmeow', 'connections.toml')
    if vim.uv.fs_stat(path) then
      return path
    end
    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
end

--- Validate dialect-specific fields and build the URL expected by other sources.
--- Database paths are rooted at the project; credentials use the shared encoder.
local function connection(name, fields, root)
  if vim.trim(name) == '' then
    return nil, 'a connection needs a non-empty name'
  end
  local dialects = require('sqmeow.dialects')
  local dialect = type(fields.type) == 'string' and dialects.get(fields.type)
  if not dialect then
    return nil, 'type must name a supported database dialect'
  end

  local allowed = { type = true, read_only = true, ssh = true }
  for _, field in ipairs(dialect.fields) do
    allowed[field.key] = true
  end
  local values = {}
  for key, value in pairs(fields) do
    if not allowed[key] then
      return nil, ('unknown field `%s`'):format(key)
    end
    if key == 'port' then
      if type(value) ~= 'number' or value < 1 or value > 65535 or value % 1 ~= 0 then
        return nil, 'port must be an integer between 1 and 65535'
      end
      values[key] = tostring(value)
    elseif key == 'read_only' or key == 'tls' or key == 'srv' then
      if type(value) ~= 'boolean' then
        return nil, ('%s must be a boolean'):format(key)
      end
      values[key] = value and 'yes' or 'no'
    else
      if type(value) ~= 'string' then
        return nil, ('%s must be a string'):format(key)
      end
      values[key] = value
    end
  end

  -- File-backed databases belong to the project, even when opened from a subdirectory.
  if values.path and values.path ~= '' and values.path ~= ':memory:' then
    local path = vim.fs.normalize(values.path)
    if not path:match('^/') and not path:match('^%a:/') then
      path = vim.fs.joinpath(root, path)
    end
    values.path = vim.fs.normalize(path)
  end
  local url, err = require('sqmeow.url').build(fields.type, values)
  if not url then
    return nil, err
  end
  return { name = name, url = url, read_only = fields.read_only, ssh = fields.ssh }
end

--- Read and validate the nearest config, starting the engine only if one exists.
--- Missing files are an empty source. Read, parse, or validation failures return
--- no entries and an error containing the file path; no database is opened.
---@return sqmeow.ConnectionSpec[] connections Sorted by section name.
---@return string|nil error Source failure, without echoing credential values.
function M.load()
  local path = M.path()
  if not path then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return {}, ('could not read %s'):format(path)
  end
  local decoded, err = require('sqmeow.rpc').request('project_connections', {
    contents = table.concat(lines, '\n'),
  })
  if not decoded then
    return {}, ('%s: %s'):format(path, err)
  end

  local connections = {}
  local root = vim.fs.dirname(vim.fs.dirname(path))
  for _, name in ipairs(vim.fn.sort(vim.tbl_keys(decoded))) do
    local entry, problem = connection(name, decoded[name], root)
    if not entry then
      return {}, ('%s [%s]: %s'):format(path, name, problem)
    end
    table.insert(connections, entry)
  end
  return connections
end

return M
