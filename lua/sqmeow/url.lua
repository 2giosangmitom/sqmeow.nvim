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

--- A short name for a URL, for a tab label or a picker row.
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

return M
