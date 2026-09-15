--- Builds SQL that names things correctly per dialect.

local M = {}

--- Quotes one identifier for a dialect.
---@param dialect string|nil `'mysql'` uses backticks, others use double quotes.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'mysql' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Joins name parts into a qualified identifier.
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

--- Returns a `SELECT` over a relation.
---@param dialect string|nil
---@param parts string[]
---@param limit integer|nil Nil reads every row.
---@return string
function M.select_from(dialect, parts, limit)
  if dialect == 'mongodb' then
    -- Written by hand rather than encoded from a table.
    return ('{"find": %s,%s "$db": %s}'):format(
      vim.json.encode(parts[#parts]),
      limit and (' "limit": %d,'):format(limit) or '',
      vim.json.encode(parts[1])
    )
  end
  local sql = ('select * from %s'):format(M.qualify(dialect, parts))
  return limit and ('%s limit %d'):format(sql, limit) or sql
end

--- Returns the command that reads a Redis key for a drawer group.
---@param group string A drawer group key (e.g. `'hashes'`).
---@param key string
---@param limit integer|nil Nil reads every element.
---@return string|nil command Nil for a group that is not a Redis type.
function M.read_key(group, key, limit)
  local escaped = key:gsub('[\\"]', '\\%0'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  local quoted = '"' .. escaped .. '"'

  local commands = {
    strings = ('GET %s'):format(quoted),
    hashes = ('HGETALL %s'):format(quoted),
    lists = ('LRANGE %s 0 %d'):format(quoted, limit and limit - 1 or -1),
    sets = ('SMEMBERS %s'):format(quoted),
    sorted_sets = ('ZRANGE %s 0 %d WITHSCORES'):format(quoted, limit and limit - 1 or -1),
    streams = ('XRANGE %s - +%s'):format(quoted, limit and (' COUNT %d'):format(limit) or ''),
    json = ('JSON.GET %s'):format(quoted),
  }
  return commands[group]
end

return M
