--- Reading and hiding parts of a connection URL.
---
--- A URL is the one thing in this plugin that routinely holds a secret. Everywhere one is shown
--- it goes through here first, so there is a single place to be right about it rather than a
--- decision repeated at every call site.

local M = {}

--- Replace the password in a URL with a mask.
---
--- Only the password is touched. The scheme, user, host and database are what make a connection
--- recognisable, and hiding them would make the interface useless.
---
---@param url string
---@return string
function M.redact(url)
  local scheme, rest = url:match('^(%w[%w%+%-%.]*://)(.*)$')
  if not scheme then
    return url
  end

  -- The authority ends at the first path, query or fragment character. Bounding the search here
  -- matters: a password may contain `@`, and so may a query parameter, and only the `@` inside the
  -- authority separates the credentials from the host.
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
---
---@param url string
---@return string
function M.display(url)
  if require('sqmeow.config').get().redact_urls then
    return M.redact(url)
  end
  return url
end

--- A short name for a URL, for a tab label or a list row.
---
--- Prefers the database name, because that is what a person calls the thing they connected to.
---
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
---
--- The last `@` is the separator, not the first: a password is allowed to contain one.
---
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
---
--- An IPv6 literal is bracketed and full of colons, so the port cannot be found by looking for the
--- first one.
---
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
---
--- The inverse of `build`, so a saved connection can be opened, edited and written back without
--- the user seeing the URL at all.
---
---@param url string
---@return table|nil fields `dialect` plus the keys that dialect asks for. Nil if the scheme is not
--- one the plugin knows.
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
    -- `sqlite:path`, `sqlite://path` and `sqlite:///path` are all in the wild, and the third one
    -- means an absolute path, so exactly two slashes come off.
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
  -- Redis spells TLS as a scheme, so it is carried as a field for the form to show. Dropping it
  -- would have an edited connection quietly write itself back unencrypted.
  if dialect == 'redis' then
    local secure = scheme:lower() == 'rediss' or scheme:lower() == 'valkeys'
    fields.tls = secure and 'yes' or 'no'
  end
  return fields
end

--- Write the fields back out as a URL.
---
--- The user and the password are percent encoded here rather than by the person typing them, which
--- is the whole reason the dialog collects them as separate fields.
---
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

  -- A password with no user is written too, as `:secret@host`. That is how Redis without ACLs is
  -- reached, and leaving it out would save a connection that cannot log in.
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
  end

  local url = ('%s://%s/%s'):format(scheme, authority, value('database'))
  if value('options') ~= '' then
    url = ('%s?%s'):format(url, (value('options'):gsub('^%?', '')))
  end
  return url
end

return M
