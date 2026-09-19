--- Describes supported database dialects and their connection fields.

local M = {}

---@class sqmeow.Field
---@field key string The key it is held under while the dialog is open.
---@field label string What the dialog calls it.
---@field mask boolean|nil Drawn as asterisks, and never echoed anywhere else.
---@field optional boolean|nil Saving does not insist on a value.
---@field hint string|nil Shown in place of an empty value.
---@field options string[]|nil Chosen from rather than typed: editing the field cycles to its next option.
---@field checkbox boolean|nil Holds 'yes' or 'no', drawn as a box editing ticks or clears.
---@field enabled nil|fun(values: table<string, string>): boolean Dimmed and left alone while false.

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
    -- Left empty, the drawer lists every database on the server.
    { key = 'database', label = 'Database', optional = true, hint = 'all' },
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
    id = 'redis',
    -- Valkey and Dragonfly speak the same protocol over the same URLs, so they are one choice.
    label = 'Redis, Valkey or Dragonfly',
    scheme = 'redis',
    port = 6379,
    fields = {
      { key = 'host', label = 'Host', optional = true, hint = 'localhost' },
      { key = 'port', label = 'Port', optional = true, hint = '6379' },
      { key = 'database', label = 'Database', optional = true, hint = '0' },
      { key = 'user', label = 'User', optional = true, hint = 'default' },
      { key = 'password', label = 'Password', mask = true, optional = true },
      { key = 'tls', label = 'TLS', optional = true, hint = 'no' },
    },
  },
  {
    id = 'mongodb',
    label = 'MongoDB',
    scheme = 'mongodb',
    port = 27017,
    -- The server questions with an optional user.
    fields = {
      { key = 'host', label = 'Host', optional = true, hint = 'localhost' },
      { key = 'port', label = 'Port', optional = true, hint = '27017' },
      -- Left empty, the drawer lists every database on the server, as for PostgreSQL.
      { key = 'database', label = 'Database', optional = true, hint = 'all' },
      { key = 'user', label = 'User', optional = true },
      { key = 'password', label = 'Password', mask = true, optional = true },
      { key = 'options', label = 'Options', optional = true, hint = 'authSource=admin' },
      { key = 'srv', label = 'SRV', checkbox = true },
    },
  },
  {
    id = 'scylla',
    -- Cassandra speaks the same CQL, so they are one choice.
    label = 'ScyllaDB or Cassandra',
    scheme = 'scylla',
    port = 9042,
    fields = {
      { key = 'host', label = 'Host', optional = true, hint = 'localhost' },
      { key = 'port', label = 'Port', optional = true, hint = '9042' },
      -- Left empty, the drawer lists every keyspace.
      { key = 'database', label = 'Keyspace', optional = true, hint = 'all' },
      { key = 'user', label = 'User', optional = true },
      { key = 'password', label = 'Password', mask = true, optional = true },
    },
  },
  {
    id = 'surrealdb',
    label = 'SurrealDB',
    scheme = 'surrealdb',
    port = 8000,
    fields = {
      { key = 'host', label = 'Host', optional = true, hint = 'localhost' },
      { key = 'port', label = 'Port', optional = true, hint = '8000' },
      { key = 'namespace', label = 'Namespace', optional = true, hint = 'main' },
      -- Left empty, the drawer lists every database in the namespace.
      { key = 'database', label = 'Database', optional = true, hint = 'all' },
      { key = 'user', label = 'User', optional = true, hint = 'root' },
      { key = 'password', label = 'Password', mask = true, optional = true },
      { key = 'options', label = 'Options', optional = true, hint = 'auth=database' },
      { key = 'tls', label = 'TLS', checkbox = true },
    },
  },
  {
    id = 'sqlite',
    label = 'SQLite',
    scheme = 'sqlite',
    -- A file, so none of the network questions apply and asking them would be noise.
    fields = { { key = 'path', label = 'File', hint = 'app.db' } },
  },
  {
    id = 'duckdb',
    label = 'DuckDB',
    scheme = 'duckdb',
    fields = { { key = 'path', label = 'File', hint = 'app.duckdb' } },
  },
}

--- Schemes that mean the same dialect, beyond the one it is written with.
local aliases = {
  postgresql = 'postgres',
  mariadb = 'mysql',
  rediss = 'redis',
  ['redis+cluster'] = 'redis',
  ['rediss+cluster'] = 'redis',
  ['redis+sentinel'] = 'redis',
  ['rediss+sentinel'] = 'redis',
  valkey = 'redis',
  valkeys = 'redis',
  ['mongodb+srv'] = 'mongodb',
  cassandra = 'scylla',
  surrealdbs = 'surrealdb',
  sqlite3 = 'sqlite',
  file = 'sqlite',
}

--- Returns one dialect by the engine's id.
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

--- Returns which dialect a URL scheme belongs to.
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

--- Returns which dialect a URL is for, without parsing the rest.
---@param url string
---@return string|nil id
function M.of_url(url)
  local scheme = url:match('^(%w[%w%+%-%.]*):')
  return scheme and M.from_scheme(scheme) or nil
end

--- Returns the fields a dialect asks for, prefixed by the name field.
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
