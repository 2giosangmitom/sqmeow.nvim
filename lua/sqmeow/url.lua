--- Parses and redacts connection URLs.

local M = {}

--- Returns the URL with its password replaced by `***`.
---@param url string
---@return string
function M.redact(url)
  local scheme, rest = url:match('^(%w[%w%+%-%.]*://)(.*)$')
  if not scheme then
    return url
  end

  -- The authority ends at the first path, query or fragment character.
  local authority, tail = rest:match('^([^/%?#]*)(.*)$')
  local at = authority:find('@[^@]*$')
  if not at then
    return url
  end

  local user, password = authority:sub(1, at - 1):match('^([^:]*):(.*)$')
  if not user or password == '' then
    return url
  end

  return ('%s%s:***@%s%s'):format(scheme, user, authority:sub(at + 1), tail)
end

--- Returns the URL redacted only when `redact_urls` is enabled.
---@param url string
---@return string
function M.display(url)
  if require('sqmeow.config').get().redact_urls then
    return M.redact(url)
  end
  return url
end

--- Returns a short human-readable label for a URL.
---@param url string
---@return string
function M.label(url)
  if url:match('^sqlite:') or url:match('^file:') or url:match('^duckdb:') then
    local path = url:gsub('^%w+:/?/?', ''):gsub('%?.*$', '')
    if path == '' or path == ':memory:' then
      return 'memory'
    end
    return vim.fs.basename(path)
  end

  local host, database = url:match('@([^/:]+)[^/]*/([^%?]+)')
  if database then
    return ('%s@%s'):format(database, host)
  end

  local bare = url:match('://[^/]*/([^%?]+)')
  return bare or url:gsub('%?.*$', '')
end

--- Split the authority into credentials and address.
---@param authority string
---@return string user
---@return string password
---@return string address
local function credentials(authority)
  local at = authority:find('@[^@]*$')
  if not at then
    return '', '', authority
  end

  local head = authority:sub(1, at - 1)
  local user, password = head:match('^([^:]*):(.*)$')
  return user or head, password or '', authority:sub(at + 1)
end

--- Split an address into host and port.
---@param address string
---@return string host
---@return string port
local function host_and_port(address)
  local bracketed, port = address:match('^(%[.-%]):?(%d*)$')
  if bracketed then
    return bracketed, port
  end

  local host, tail = address:match('^([^:]*):(%d*)$')
  if host then
    return host, tail
  end
  return address, ''
end

--- Take a URL apart into the fields the connection dialog shows. A `{{ ... }}` template is kept
--- whole in the field it sits in.
---@param url string
---@return table|nil fields `dialect` plus the keys that dialect asks for.
function M.parse(url)
  -- Set aside, since a template holds the characters a URL is split on.
  local templates = {}
  url = url:gsub('{{.-}}', function(template)
    table.insert(templates, template)
    return '\1' .. #templates .. '\1'
  end)
  local fields = M.split(url)
  for key, value in pairs(fields or {}) do
    fields[key] = value:gsub('\1(%d+)\1', function(index)
      return templates[tonumber(index)]
    end)
  end
  return fields
end

--- Take a URL without templates apart into the connection dialog's fields.
---@param url string
---@return table|nil
function M.split(url)
  local scheme, rest = url:match('^(%w[%w%+%-%.]*):(.*)$')
  if not scheme then
    return nil
  end

  local dialect = require('sqmeow.dialects').from_scheme(scheme)
  if not dialect then
    return nil
  end

  if dialect == 'sqlite' or dialect == 'duckdb' then
    -- `sqlite:///path` is an absolute path.
    local path = rest:gsub('^//', ''):gsub('%?.*$', '')
    return { dialect = dialect, path = path }
  end

  local authority, tail = rest:gsub('^//', ''):match('^([^/%?#]*)(.*)$')
  local user, password, address = credentials(authority)
  -- Several hosts, as a cluster names, are more than one Host field holds.
  if address:find(',', 1, true) then
    return nil
  end
  local host, port = host_and_port(address)

  local fields = {
    dialect = dialect,
    host = host,
    port = port,
    user = vim.uri_decode(user),
    password = vim.uri_decode(password),
    database = (tail:match('^/([^%?#]*)') or ''),
    options = (tail:match('%?([^#]*)') or ''),
  }
  -- Redis spells TLS as a scheme.
  if dialect == 'redis' then
    local secure = scheme:lower() == 'rediss' or scheme:lower() == 'valkeys'
    fields.tls = secure and 'yes' or 'no'
  end
  -- SurrealDB's path is `/namespace/database`, and its TLS a scheme as for Redis.
  if dialect == 'surrealdb' then
    local namespace, database = fields.database:match('^([^/]*)/?(.*)$')
    fields.namespace = vim.uri_decode(namespace)
    fields.database = database
    fields.tls = scheme:lower() == 'surrealdbs' and 'yes' or 'no'
  end
  -- The same for MongoDB's SRV lookup, which an edited connection would otherwise lose.
  if dialect == 'mongodb' then
    fields.srv = scheme:lower() == 'mongodb+srv' and 'yes' or 'no'
  end
  return fields
end

--- Percent-encode text for a URL, leaving any `{{ ... }}` template in it as it is.
---@param text string
---@return string
local function encode(text)
  local out, at = {}, 1
  for start, template, finish in text:gmatch('()({{.-}})()') do
    table.insert(out, vim.uri_encode(text:sub(at, start - 1), 'rfc2396'))
    table.insert(out, template)
    at = finish
  end
  table.insert(out, vim.uri_encode(text:sub(at), 'rfc2396'))
  return table.concat(out)
end

--- Write the fields back out as a URL.
---@param dialect string
---@param values table<string, string>
---@return string|nil url
---@return string|nil error
function M.build(dialect, values)
  local spec = require('sqmeow.dialects').get(dialect)
  if not spec then
    return nil, ('there is no `%s` database'):format(tostring(dialect))
  end

  local function value(key)
    return vim.trim(values[key] or '')
  end

  if dialect == 'sqlite' or dialect == 'duckdb' then
    local path = value('path')
    if path == '' then
      return nil, ('a %s connection needs a file'):format(spec.label)
    end
    return ('%s:%s'):format(spec.scheme, path)
  end

  local host = value('host')
  if host == '' then
    host = 'localhost'
  end

  local authority = host
  if value('port') ~= '' then
    authority = ('%s:%s'):format(host, value('port'))
  end

  -- A password with no user is written too, as `:secret@host`.
  if value('user') ~= '' or value('password') ~= '' then
    local login = encode(value('user'))
    if value('password') ~= '' then
      login = ('%s:%s'):format(login, encode(value('password')))
    end
    authority = ('%s@%s'):format(login, authority)
  end

  local scheme = spec.scheme
  if
    dialect == 'redis' and vim.tbl_contains({ 'yes', 'true', 'on', '1' }, value('tls'):lower())
  then
    scheme = 'rediss'
  elseif dialect == 'mongodb' and value('srv') == 'yes' then
    -- The port comes from the DNS record, and the driver refuses an SRV address that names one.
    if value('port') ~= '' then
      return nil, 'a MongoDB SRV address takes no port'
    end
    scheme = 'mongodb+srv'
  end

  local path = value('database')
  if dialect == 'surrealdb' then
    scheme = value('tls') == 'yes' and 'surrealdbs' or scheme
    -- The database comes second, so an empty namespace is written as the server's default.
    local namespace = value('namespace') ~= '' and encode(value('namespace'))
      or (path ~= '' and 'main' or '')
    path = path ~= '' and ('%s/%s'):format(namespace, path) or namespace
  end

  local url = ('%s://%s/%s'):format(scheme, authority, path)
  if value('options') ~= '' then
    url = ('%s?%s'):format(url, (value('options'):gsub('^%?', '')))
  end
  return url
end

return M
