--- The databases the plugin can connect to, and what a connection to each one needs.
---
--- One list, read by the connection dialog to decide which fields to ask for, by the URL builder
--- to decide how to write them out, and by the health check to recognise a scheme. Adding a
--- database to the engine means adding a row here and nothing else on this side.

local M = {}

---@class sqmeow.Field
---@field key string The key it is held under while the dialog is open.
---@field label string What the dialog calls it.
---@field mask boolean|nil Drawn as asterisks, and never echoed anywhere else.
---@field optional boolean|nil Saving does not insist on a value.
---@field hint string|nil Shown in place of an empty value.

---@class sqmeow.Dialect
---@field id string What the engine calls it.
---@field label string What a person calls it.
---@field scheme string The URL scheme written when a URL is built.
---@field port integer|nil The port assumed when the field is left empty.
---@field fields sqmeow.Field[]

--- A server reached over the network: the same five questions for every one of them.
local function server_fields(port)
  return {
    { key = 'host', label = 'Host', optional = true, hint = 'localhost' },
    { key = 'port', label = 'Port', optional = true, hint = tostring(port) },
    { key = 'database', label = 'Database' },
    { key = 'user', label = 'User' },
    { key = 'password', label = 'Password', mask = true, optional = true },
    { key = 'options', label = 'Options', optional = true, hint = 'sslmode=require' },
  }
end

--- Every database, in the order the dialog offers them.
---@type sqmeow.Dialect[]
M.list = {
  {
    id = 'postgres',
    label = 'PostgreSQL',
    scheme = 'postgres',
    port = 5432,
    fields = server_fields(5432),
  },
  {
    id = 'mysql',
    label = 'MySQL or MariaDB',
    scheme = 'mysql',
    port = 3306,
    fields = server_fields(3306),
  },
  {
    id = 'sqlite',
    label = 'SQLite',
    scheme = 'sqlite',
    -- A file, so none of the network questions apply and asking them would be noise.
    fields = { { key = 'path', label = 'File', hint = 'app.db' } },
  },
}

--- Schemes that mean the same dialect, beyond the one it is written with.
local aliases = {
  postgresql = 'postgres',
  mariadb = 'mysql',
  sqlite3 = 'sqlite',
  file = 'sqlite',
}

--- One dialect by the name the engine uses.
---
---@param id string
---@return sqmeow.Dialect|nil
function M.get(id)
  for _, dialect in ipairs(M.list) do
    if dialect.id == id then
      return dialect
    end
  end
  return nil
end

--- Which dialect a URL scheme belongs to.
---
--- Answers offline, before the engine has been started, which is what lets the health check and
--- the connection dialog both work on a URL nobody has connected with yet.
---
---@param scheme string
---@return string|nil id
function M.from_scheme(scheme)
  scheme = scheme:lower()
  local direct = M.get(scheme)
  if direct then
    return direct.id
  end
  return aliases[scheme]
end

--- The fields a dialect asks for, with the name every connection carries at the top.
---
--- The name is asked for first and is never filled in for the user. It is what the drawer, the
--- statusline and every picker will call this database from now on, so it is theirs to choose, and
--- offering something assembled out of the host and the database would put a piece of the
--- connection string on screen.
---
---@param id string
---@return sqmeow.Field[]
function M.fields(id)
  local dialect = M.get(id)
  if not dialect then
    return {}
  end

  local fields = { { key = 'name', label = 'Name' } }
  return vim.list_extend(fields, vim.deepcopy(dialect.fields))
end

return M
