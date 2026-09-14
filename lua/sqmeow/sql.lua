--- Writing SQL that names things.

local M = {}

--- Quote one identifier for a dialect.
---@param dialect string|nil 'mysql' uses backticks.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'mysql' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Join name parts into a qualified name.
---@param dialect string|nil
---@param parts string[] Such as `{ 'public', 'users' }`.
---@return string
function M.qualify(dialect, parts)
  -- A Redis key is not qualified by its database.
  if dialect == 'redis' or dialect == 'mongodb' then
    return parts[#parts]
  end
  return table.concat(
    vim.tbl_map(function(part)
      return M.quote(dialect, part)
    end, parts),
    '.'
  )
end

--- A `SELECT` over a relation.
---@param dialect string|nil
---@param parts string[]
---@param limit integer
---@return string
function M.select_from(dialect, parts, limit)
  if dialect == 'mongodb' then
    -- Written by hand rather than encoded from a table.
    return ('{"find": %s, "limit": %d, "$db": %s}'):format(
      vim.json.encode(parts[#parts]),
      limit,
      vim.json.encode(parts[1])
    )
  end
  return ('select * from %s limit %d'):format(M.qualify(dialect, parts), limit)
end

--- The command that reads a Redis key back, by the drawer group it is listed under.
---@param group string A drawer group key, such as `hashes`.
---@param key string
---@param limit integer
---@return string|nil command Nil for a group that is not a Redis type.
function M.read_key(group, key, limit)
  local escaped = key:gsub('[\\"]', '\\%0'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  local quoted = '"' .. escaped .. '"'

  local commands = {
    strings = ('GET %s'):format(quoted),
    hashes = ('HGETALL %s'):format(quoted),
    lists = ('LRANGE %s 0 %d'):format(quoted, limit - 1),
    sets = ('SMEMBERS %s'):format(quoted),
    sorted_sets = ('ZRANGE %s 0 %d WITHSCORES'):format(quoted, limit - 1),
    streams = ('XRANGE %s - + COUNT %d'):format(quoted, limit),
    json = ('JSON.GET %s'):format(quoted),
  }
  return commands[group]
end

return M
