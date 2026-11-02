--- Builds SQL that names things correctly per dialect.

local M = {}

local reserved_words = {
  ['all'] = true,
  ['analyse'] = true,
  ['analyze'] = true,
  ['and'] = true,
  ['any'] = true,
  ['array'] = true,
  ['as'] = true,
  ['asc'] = true,
  ['asymmetric'] = true,
  ['authorization'] = true,
  ['between'] = true,
  ['binary'] = true,
  ['both'] = true,
  ['case'] = true,
  ['cast'] = true,
  ['check'] = true,
  ['collate'] = true,
  ['collation'] = true,
  ['column'] = true,
  ['concurrently'] = true,
  ['constraint'] = true,
  ['create'] = true,
  ['cross'] = true,
  ['current_catalog'] = true,
  ['current_date'] = true,
  ['current_role'] = true,
  ['current_schema'] = true,
  ['current_time'] = true,
  ['current_timestamp'] = true,
  ['current_user'] = true,
  ['default'] = true,
  ['deferrable'] = true,
  ['desc'] = true,
  ['distinct'] = true,
  ['do'] = true,
  ['else'] = true,
  ['end'] = true,
  ['except'] = true,
  ['false'] = true,
  ['fetch'] = true,
  ['for'] = true,
  ['foreign'] = true,
  ['freeze'] = true,
  ['from'] = true,
  ['full'] = true,
  ['grant'] = true,
  ['group'] = true,
  ['having'] = true,
  ['ilike'] = true,
  ['in'] = true,
  ['initially'] = true,
  ['inner'] = true,
  ['intersect'] = true,
  ['into'] = true,
  ['is'] = true,
  ['isnull'] = true,
  ['join'] = true,
  ['lateral'] = true,
  ['leading'] = true,
  ['left'] = true,
  ['like'] = true,
  ['limit'] = true,
  ['localtime'] = true,
  ['localtimestamp'] = true,
  ['natural'] = true,
  ['not'] = true,
  ['notnull'] = true,
  ['null'] = true,
  ['offset'] = true,
  ['on'] = true,
  ['only'] = true,
  ['or'] = true,
  ['order'] = true,
  ['outer'] = true,
  ['overlaps'] = true,
  ['placing'] = true,
  ['primary'] = true,
  ['references'] = true,
  ['returning'] = true,
  ['right'] = true,
  ['select'] = true,
  ['session_user'] = true,
  ['similar'] = true,
  ['some'] = true,
  ['symmetric'] = true,
  ['system_user'] = true,
  ['table'] = true,
  ['tablesample'] = true,
  ['then'] = true,
  ['to'] = true,
  ['trailing'] = true,
  ['true'] = true,
  ['union'] = true,
  ['unique'] = true,
  ['user'] = true,
  ['using'] = true,
  ['variadic'] = true,
  ['verbose'] = true,
  ['when'] = true,
  ['where'] = true,
  ['window'] = true,
  ['with'] = true,
}

-- MySQL and MariaDB reserve more words than PostgreSQL.
local mysql_reserved = {}
local mysql_words = [[
  change condition database databases delete div dual exists explain groups index insert
  interval key keys kill lines load lock long match mod option partition range rank read
  release rename repeat replace require row rows schema schemas separator show signal sql
  update usage use values write xor
]]
for word in mysql_words:gmatch('%S+') do
  mysql_reserved[word] = true
end

local closers = { ['"'] = '"', ['`'] = '`', ['['] = ']' }

--- The closing delimiter for an identifier opened with `open`.
---@param open string
---@return string
function M.closer(open)
  return closers[open]
end

--- The delimiter a dialect opens a quoted identifier with.
---@param dialect string|nil
---@return string
function M.opener(dialect)
  if dialect == 'mssql' then
    return '['
  elseif dialect == 'mysql' or dialect == 'mariadb' or dialect == 'surrealdb' then
    return '`'
  end
  return '"'
end

--- Quotes `name` between `open` and its closer, doubling any closer inside.
---@param open string
---@param name string
---@return string
function M.wrap(open, name)
  local close = closers[open]
  return open .. name:gsub(vim.pesc(close), close .. close) .. close
end

--- Quotes one identifier for a dialect.
---@param dialect string|nil MySQL and MariaDB use backticks, others use double quotes.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'surrealdb' then
    return '`' .. name:gsub('[\\`]', '\\%0') .. '`'
  end
  return M.wrap(M.opener(dialect), name)
end

--- Whether `name` must be quoted to be read back unchanged.
---@param dialect string|nil
---@param name string
---@param qualified boolean A reserved word after a dot needs no quotes.
---@return boolean
function M.needs_quote(dialect, name, qualified)
  if not name:match('^[%a_][%w_$]*$') then
    return true
  end
  -- These fold unquoted names; the rest keep or ignore case.
  if dialect == 'postgres' or dialect == 'scylla' then
    if name:match('%u') then
      return true
    end
  elseif dialect == 'oracle' and name:match('%l') then
    return true
  end
  if qualified then
    return false
  end
  local word = name:lower()
  return reserved_words[word] == true
    or ((dialect == 'mysql' or dialect == 'mariadb') and mysql_reserved[word] == true)
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

--- Returns a `SELECT` over a relation filtered by already-built predicates.
---
--- The engine builds each predicate from the retained cell in its own dialect, so this only
--- qualifies the relation and joins the predicates. No row limit is added: the engine's
--- `query.max_rows` cap still applies, and its truncation marker then says whether the
--- drilldown was cut short.
---@param dialect string|nil
---@param parts string[]
---@param conditions string[] SQL predicates, already quoted and typed for the dialect.
---@return string
function M.select_where(dialect, parts, conditions)
  local sql = ('select * from %s'):format(M.qualify(dialect, parts))
  if #conditions == 0 then
    return sql
  end
  return ('%s where %s'):format(sql, table.concat(conditions, ' and '))
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
