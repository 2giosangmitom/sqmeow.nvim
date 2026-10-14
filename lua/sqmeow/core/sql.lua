--- Builds SQL that names things correctly per dialect.

local M = {}

--- Quotes one identifier for a dialect.
---@param dialect string|nil MySQL and MariaDB use backticks, others use double quotes.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'mssql' then
    return '[' .. name:gsub(']', ']]') .. ']'
  end
  if dialect == 'mysql' or dialect == 'mariadb' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  if dialect == 'surrealdb' then
    return '`' .. name:gsub('[\\`]', '\\%0') .. '`'
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
  -- Nor is a SurrealDB table, which is quoted all the same.
  if dialect == 'surrealdb' then
    return M.quote(dialect, parts[#parts])
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
  if dialect == 'mssql' then
    return limit and ('select top (%d) * from %s'):format(limit, M.qualify(dialect, parts)) or sql
  end
  if dialect == 'oracle' then
    -- Oracle reads the first rows with `FETCH FIRST`, not `LIMIT`.
    return limit and ('%s fetch first %d rows only'):format(sql, limit) or sql
  end
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

  -- limit=nil means no cap; limit=0 means empty result; limit>0 means at most N elements.
  local commands = {
    strings = ('GET %s'):format(quoted),
    hashes = ('HGETALL %s'):format(quoted),
    lists = limit == 0 and ('LRANGE %s 1 0'):format(quoted)
      or ('LRANGE %s 0 %d'):format(quoted, limit and limit - 1 or -1),
    sets = ('SMEMBERS %s'):format(quoted),
    sorted_sets = limit == 0 and ('ZRANGE %s 1 0 WITHSCORES'):format(quoted)
      or ('ZRANGE %s 0 %d WITHSCORES'):format(quoted, limit and limit - 1 or -1),
    streams = limit == 0 and ('XRANGE %s - -'):format(quoted)
      or ('XRANGE %s - +%s'):format(quoted, limit and (' COUNT %d'):format(limit) or ''),
    json = ('JSON.GET %s'):format(quoted),
  }
  return commands[group]
end

--- Returns separate, editable statements using the table's current column types.
---@param dialect string|nil
---@param parts string[]
---@param columns table[]|nil Column nodes from schema cache
---@return string|nil template Nil for unsupported dialects.
function M.alter_table(dialect, parts, columns)
  local operations = {
    postgres = 'ALTER COLUMN %s TYPE %s',
    cockroachdb = 'ALTER COLUMN %s TYPE %s',
    duckdb = 'ALTER COLUMN %s TYPE %s',
    mysql = 'MODIFY COLUMN %s %s',
    mariadb = 'MODIFY COLUMN %s %s',
    mssql = 'ALTER COLUMN %s %s',
    oracle = 'MODIFY (%s %s)',
    clickhouse = 'MODIFY COLUMN %s %s',
  }
  local operation = operations[dialect]
  if not operation and dialect ~= 'sqlite' and dialect ~= 'surrealdb' then
    return nil
  end

  local qualified = M.qualify(dialect, parts)
  local lines = { '-- Edit these placeholders before running; nothing has been executed.', '' }
  if dialect == 'sqlite' then
    table.insert(
      lines,
      2,
      '-- SQLite cannot alter column types directly; rename placeholders follow.'
    )
  elseif dialect == 'mysql' or dialect == 'mariadb' then
    table.insert(
      lines,
      2,
      '-- MODIFY replaces the definition: review defaults, generated values and AUTO_INCREMENT.'
    )
  elseif dialect == 'surrealdb' then
    table.insert(
      lines,
      2,
      '-- OVERWRITE replaces field definitions: review VALUE, ASSERT and PERMISSIONS clauses.'
    )
  end

  local editable = {}
  for _, col in ipairs(columns or {}) do
    -- SurrealDB's record id is implicit, not an editable field definition.
    if not (dialect == 'surrealdb' and col.name == 'id' and col.primary_key) then
      table.insert(editable, col)
    end
  end
  if #editable == 0 then
    editable = { { name = 'column_name', type_name = 'new_type' } }
  end

  for _, col in ipairs(editable) do
    local name = M.quote(dialect, col.name)
    local type_name = col.type_name and col.type_name ~= '' and col.type_name or 'new_type'
    -- Unusual type metadata needs a manual definition, not executable extra lines.
    if type_name:find('[\r\n]') then
      type_name = 'new_type'
    end
    local statement
    if dialect == 'sqlite' then
      statement = ('ALTER TABLE %s RENAME COLUMN %s TO %s;'):format(
        qualified,
        name,
        M.quote(dialect, col.name .. '_renamed')
      )
    elseif dialect == 'surrealdb' then
      statement = ('DEFINE FIELD OVERWRITE %s ON TABLE %s TYPE %s;'):format(
        name,
        qualified,
        type_name
      )
    else
      local definition = type_name
      if dialect == 'mysql' or dialect == 'mariadb' or dialect == 'mssql' then
        definition = definition
          .. ((col.nullable == false or col.primary_key) and ' NOT NULL' or ' NULL')
      end
      if (dialect == 'mysql' or dialect == 'mariadb') and col.default then
        definition = definition .. ' DEFAULT ' .. col.default
      end
      statement = ('ALTER TABLE %s\n  %s;'):format(qualified, operation:format(name, definition))
    end
    table.insert(lines, statement)
    table.insert(lines, '')
  end
  table.remove(lines)
  return table.concat(lines, '\n')
end

return M
