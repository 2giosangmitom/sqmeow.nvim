--- Builds SQL that names things correctly per dialect.

local M = {}

--- Quotes one identifier for a dialect.
---@param dialect string|nil `'mysql'` uses backticks, others use double quotes.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'mssql' then
    return '[' .. name:gsub(']', ']]') .. ']'
  end
  if dialect == 'mysql' then
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

--- Returns an ALTER TABLE template for modifying a table's schema.
---@param dialect string|nil
---@param parts string[]
---@param columns table[]|nil Optional column nodes from schema cache
---@return string
function M.alter_table(dialect, parts, columns)
  local qualified = M.qualify(dialect, parts)
  local lines = {}

  if columns and #columns > 0 then
    table.insert(lines, '-- Current columns:')
    for _, col in ipairs(columns) do
      local details = {}
      if col.type_name and col.type_name ~= '' then
        table.insert(details, col.type_name)
      end
      if col.primary_key then
        table.insert(details, 'primary key')
      elseif col.nullable == false then
        table.insert(details, 'not null')
      end
      local detail_str = #details > 0 and (' (' .. table.concat(details, ', ') .. ')') or ''
      table.insert(lines, ('--   %s%s'):format(col.name, detail_str))
    end
    table.insert(lines, '')
  end

  if dialect == 'surrealdb' then
    local tbl_name = parts[#parts]
    table.insert(
      lines,
      ('-- DEFINE FIELD new_column ON TABLE %s TYPE string;'):format(M.quote(dialect, tbl_name))
    )
    table.insert(
      lines,
      ('-- REMOVE FIELD old_column ON TABLE %s;'):format(M.quote(dialect, tbl_name))
    )
    table.insert(lines, '')
    table.insert(
      lines,
      ('DEFINE FIELD new_column ON TABLE %s TYPE string;'):format(M.quote(dialect, tbl_name))
    )
    return table.concat(lines, '\n')
  end

  if dialect == 'mysql' or dialect == 'mariadb' then
    table.insert(lines, '-- Operations:')
    table.insert(lines, '--   ADD COLUMN new_column varchar(255),')
    table.insert(lines, '--   DROP COLUMN old_column,')
    table.insert(lines, '--   MODIFY COLUMN column_name new_type,')
    table.insert(lines, '--   CHANGE COLUMN old_name new_name new_type;')
    table.insert(lines, '')
    table.insert(lines, ('ALTER TABLE %s'):format(qualified))
    table.insert(lines, '  ADD COLUMN new_column varchar(255);')
    return table.concat(lines, '\n')
  end

  if dialect == 'mssql' then
    table.insert(lines, '-- Operations:')
    table.insert(lines, '--   ADD new_column nvarchar(255);')
    table.insert(lines, '--   ALTER COLUMN column_name new_type;')
    table.insert(lines, '--   DROP COLUMN old_column;')
    table.insert(lines, '')
    table.insert(lines, ('ALTER TABLE %s'):format(qualified))
    table.insert(lines, '  ADD new_column nvarchar(255);')
    return table.concat(lines, '\n')
  end

  if dialect == 'sqlite' then
    table.insert(lines, '-- Operations:')
    table.insert(lines, '--   ADD COLUMN new_column text;')
    table.insert(lines, '--   RENAME COLUMN old_name TO new_name;')
    table.insert(lines, '--   DROP COLUMN old_column;')
    table.insert(lines, '')
    table.insert(lines, ('ALTER TABLE %s'):format(qualified))
    table.insert(lines, '  ADD COLUMN new_column text;')
    return table.concat(lines, '\n')
  end

  if dialect == 'oracle' then
    table.insert(lines, '-- Operations:')
    table.insert(lines, '--   ADD new_column varchar2(255);')
    table.insert(lines, '--   MODIFY column_name new_type;')
    table.insert(lines, '--   DROP COLUMN old_column;')
    table.insert(lines, '')
    table.insert(lines, ('ALTER TABLE %s'):format(qualified))
    table.insert(lines, '  ADD new_column varchar2(255);')
    return table.concat(lines, '\n')
  end

  if dialect == 'clickhouse' then
    table.insert(lines, '-- Operations:')
    table.insert(lines, '--   ADD COLUMN new_column String,')
    table.insert(lines, '--   DROP COLUMN old_column,')
    table.insert(lines, '--   MODIFY COLUMN column_name new_type;')
    table.insert(lines, '')
    table.insert(lines, ('ALTER TABLE %s'):format(qualified))
    table.insert(lines, '  ADD COLUMN new_column String;')
    return table.concat(lines, '\n')
  end

  -- PostgreSQL, CockroachDB, DuckDB, standard SQL
  table.insert(lines, '-- Operations:')
  table.insert(lines, '--   ADD COLUMN new_column text,')
  table.insert(lines, '--   DROP COLUMN old_column,')
  table.insert(lines, '--   ALTER COLUMN column_name TYPE new_type,')
  table.insert(lines, '--   RENAME COLUMN old_name TO new_name;')
  table.insert(lines, '')
  table.insert(lines, ('ALTER TABLE %s'):format(qualified))
  table.insert(lines, '  ADD COLUMN new_column text;')
  return table.concat(lines, '\n')
end

return M
