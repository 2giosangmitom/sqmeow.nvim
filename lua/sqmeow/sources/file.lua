--- Connections from a JSON file.

local M = {}

--- Where connections are kept when the source does not name a path.
---@return string
function M.default_path()
  return require('sqmeow.paths').connections()
end

--- The path this source reads.
---@param opts table|nil Source options: `path` overrides the default.
---@return string
function M.path(opts)
  return vim.fs.normalize((opts or {}).path or M.default_path())
end

--- Read connections from the file.
---@param opts table|nil
---@return sqmeow.ConnectionSpec[]
---@return string|nil error
function M.load(opts)
  local path = M.path(opts)
  if not vim.uv.fs_stat(path) then
    return {}
  end

  local ok, contents = pcall(vim.fn.readfile, path)
  if not ok then
    return {}, ('could not read %s: %s'):format(path, contents)
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(contents, '\n'))
  if not ok then
    return {}, ('%s does not hold valid JSON: %s'):format(path, decoded)
  end
  if type(decoded) ~= 'table' then
    return {}, ('%s must hold a JSON array of connections'):format(path)
  end

  return decoded
end

--- Replace the file's contents.
---@param connections sqmeow.ConnectionSpec[]
---@param opts table|nil
---@return boolean written
---@return string|nil error
function M.save(connections, opts)
  local path = M.path(opts)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')

  -- Only the fields that describe a connection are written back.
  local plain = vim.tbl_map(function(connection)
    return { name = connection.name, url = connection.url, read_only = connection.read_only or nil }
  end, connections)

  local ok, err = pcall(vim.fn.writefile, vim.split(vim.json.encode(plain), '\n'), path)
  if not ok then
    return false, ('could not write %s: %s'):format(path, err)
  end
  return true
end

--- Replace one connection.
---@param name string The name it is saved under now.
---@param connection sqmeow.ConnectionSpec What to save instead.
---@param opts table|nil
---@return boolean written
---@return string|nil error
function M.update(name, connection, opts)
  local connections, err = M.load(opts)
  if err then
    return false, err
  end

  local found
  for index, existing in ipairs(connections) do
    if existing.name == name then
      found = index
      break
    end
  end
  if not found then
    return false, ('there is no saved connection called `%s`'):format(name)
  end

  for index, existing in ipairs(connections) do
    if index ~= found and existing.name == connection.name then
      return false, ('there is already a saved connection called `%s`'):format(connection.name)
    end
  end

  connections[found] = {
    name = connection.name,
    url = connection.url,
    read_only = connection.read_only,
  }
  return M.save(connections, opts)
end

--- Add one connection, keeping the rest.
---@param connection sqmeow.ConnectionSpec
---@param opts table|nil
---@return boolean written
---@return string|nil error
function M.add(connection, opts)
  local connections, err = M.load(opts)
  if err then
    return false, err
  end

  for index, existing in ipairs(connections) do
    if existing.name == connection.name then
      connections[index] = connection
      return M.save(connections, opts)
    end
  end

  table.insert(connections, connection)
  return M.save(connections, opts)
end

return M
