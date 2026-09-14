--- Reading and hiding parts of a connection URL.

local M = {}

--- Replace the password in a URL with a mask.
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

--- Hide the password only when the configuration asks for it.
---@param url string
---@return string
function M.display(url)
  if require('sqmeow.config').get().redact_urls then
    return M.redact(url)
  end
  return url
end

--- A short name for a URL, for a tab label or a list row.
---@param url string
---@return string
function M.label(url)
  if url:match('^sqlite:') or url:match('^file:') then
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

--- Take a URL apart into the fields the connection dialog shows.
---@param url string
---@return table|nil fields `dialect` plus the keys that dialect asks for.
function M.parse(url)
  local scheme, rest = url:match('^(%w[%w%+%-%.]*):(.*)$')
  if not scheme then
    return nil
  end

  local dialect = require('sqmeow.dialects').from_scheme(scheme)
  if not dialect then
    return nil
  end

  if dialect == 'sqlite' then
    -- `sqlite:///path` is an absolute path.
    local path = rest:gsub('^//', ''):gsub('%?.*$', '')
    return { dialect = dialect, path = path }
  end

  local authority, tail = rest:gsub('^//', ''):match('^([^/%?#]*)(.*)$')
  local user, password, address = credentials(authority)
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
  -- The same for MongoDB's SRV lookup, which an edited connection would otherwise lose.
  if dialect == 'mongodb' then
    fields.srv = scheme:lower() == 'mongodb+srv' and 'yes' or 'no'
  end
  return fields
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

  if dialect == 'sqlite' then
    local path = value('path')
    if path == '' then
      return nil, 'a SQLite connection needs a file'
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
    local login = vim.uri_encode(value('user'), 'rfc2396')
    if value('password') ~= '' then
      login = ('%s:%s'):format(login, vim.uri_encode(value('password'), 'rfc2396'))
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

  local url = ('%s://%s/%s'):format(scheme, authority, value('database'))
  if value('options') ~= '' then
    url = ('%s?%s'):format(url, (value('options'):gsub('^%?', '')))
  end
  return url
end

return M
