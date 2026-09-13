--- Writing SQL that names things.
---
--- Quoting is per dialect, and getting it wrong is not cosmetic: an unquoted name that happens to
--- be a reserved word, or that has a capital letter in PostgreSQL, refers to something else or to
--- nothing at all.

local M = {}

--- Quote one identifier for a dialect.
---
---@param dialect string|nil 'mysql' uses backticks; everything else uses double quotes.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'mysql' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Join name parts into a qualified name.
---
---@param dialect string|nil
---@param parts string[] Such as `{ 'public', 'users' }`.
---@return string
function M.qualify(dialect, parts)
  -- A Redis key is not qualified by its database, which `SELECT` chooses, so the key is the name.
  if dialect == 'redis' then
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
---
--- The limit is there because a drawer action should never be the thing that pulls a hundred
--- million rows across a network.
---
---@param dialect string|nil
---@param parts string[]
---@param limit integer
---@return string
function M.select_from(dialect, parts, limit)
  return ('select * from %s limit %d'):format(M.qualify(dialect, parts), limit)
end

--- The command that reads a Redis key back, by the drawer group it is listed under.
---
--- The key is double quoted with the escapes the engine reads, so a name with a space or a quote
--- in it is still one word. A hash and a set have no range to ask for, so those two come back whole
--- and the engine's row cap is what limits them.
---
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
  }
  return commands[group]
end

return M
