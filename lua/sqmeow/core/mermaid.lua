--- Render collected table structures as a Mermaid `erDiagram`. Pure: no RPC, no editor state.

local M = {}

---@param name string|nil
---@return string
local function lower(name)
  return (name or ''):lower()
end

--- Whether `columns` names exactly the set `wanted`, ignoring case and order.
---@param columns string[]
---@param wanted string[]
---@return boolean
local function same_columns(columns, wanted)
  if #columns ~= #wanted or #wanted == 0 then
    return false
  end
  local set = {}
  for _, column in ipairs(columns) do
    set[lower(column)] = true
  end
  for _, column in ipairs(wanted) do
    if not set[lower(column)] then
      return false
    end
  end
  return true
end

--- Whether at most one child row can point at a parent: the key columns are the primary
--- key or a unique index.
---@param tbl sqmeow.SchemaTable
---@param columns string[]
---@return boolean
local function is_unique(tbl, columns)
  local primary = {}
  for _, column in ipairs(tbl.columns or {}) do
    if column.primary_key then
      table.insert(primary, column.name)
    end
  end
  if same_columns(primary, columns) then
    return true
  end
  for _, index in ipairs(tbl.indexes or {}) do
    if (index.unique or index.primary) and same_columns(index.columns or {}, columns) then
      return true
    end
  end
  return false
end

--- Whether a child row may have no parent: any key column is nullable.
---@param tbl sqmeow.SchemaTable
---@param columns string[]
---@return boolean
local function is_optional(tbl, columns)
  local nullable = {}
  for _, column in ipairs(tbl.columns or {}) do
    nullable[lower(column.name)] = column.nullable
  end
  for _, name in ipairs(columns) do
    if nullable[lower(name)] ~= false then
      return true
    end
  end
  return false
end

---@param type_name string|nil
---@return string
local function attribute_type(type_name)
  local t = vim.trim(type_name or ''):lower()
  -- Longest spelling first: `character` is a prefix of `character varying`.
  for _, alias in ipairs({
    { '^character varying', 'varchar' },
    { '^character', 'char' },
    { '^timestamp without time zone', 'timestamp' },
    { '^timestamp with time zone', 'timestamptz' },
    { '^time without time zone', 'time' },
    { '^time with time zone', 'timetz' },
    { '^double precision', 'float8' },
  }) do
    local replaced, count = t:gsub(alias[1], alias[2])
    if count > 0 then
      t = replaced
      break
    end
  end
  t = t:gsub('%s*,%s*', '_'):gsub('%s+', '_'):gsub('[^%w_%-()%[%]]', '')
  return t ~= '' and t or 'unknown'
end

---@param name string|nil
---@return string
local function attribute_name(name)
  local s = (name or ''):gsub('[^%w_]', '_')
  if s == '' then
    return 'unnamed'
  end
  return s:match('^%d') and ('_' .. s) or s
end

--- Render `schema` as a Mermaid `erDiagram`.
---
--- Relationship lines come first, parent to child. The parent end is `||` when every
--- foreign key column is NOT NULL and `|o` otherwise; the child end is `|o` when the
--- key columns are unique and `o{` otherwise. Foreign keys to tables outside
--- `schema.tables` are tagged on their columns but drawn as no line.
---@param schema { tables: sqmeow.SchemaTable[] }
---@return string
function M.erd(schema)
  local tables = schema.tables or {}

  -- Qualify entity names only where the bare table name would be ambiguous.
  local schemas, names = {}, {}
  for _, tbl in ipairs(tables) do
    schemas[tbl.schema or ''] = true
    names[lower(tbl.relation)] = (names[lower(tbl.relation)] or 0) + 1
  end
  local qualify = vim.tbl_count(schemas) > 1
  local function entity(tbl)
    local raw = tbl.relation
    if (qualify or names[lower(raw)] > 1) and (tbl.schema or '') ~= '' then
      raw = tbl.schema .. '.' .. raw
    end
    return raw:match('^[%a_][%w_]*$') and raw or ('"' .. raw:gsub('"', '') .. '"')
  end

  --- The table a foreign key target names: `relation` in the child's schema, or `schema.relation`.
  local function find(child, target)
    local target_schema, relation = (target or ''):match('^([^.]+)%.(.+)$')
    target_schema = target_schema or child.schema or ''
    relation = relation or target or ''
    local match, count = nil, 0
    for _, tbl in ipairs(tables) do
      if tbl.schema == target_schema and tbl.relation == relation then
        return tbl
      end
      if lower(tbl.schema) == lower(target_schema) and lower(tbl.relation) == lower(relation) then
        match, count = tbl, count + 1
      end
    end
    return count == 1 and match or nil
  end

  local lines = { 'erDiagram' }
  for _, child in ipairs(tables) do
    for _, fk in ipairs(child.foreign_keys or {}) do
      local parent = find(child, fk.target)
      if parent then
        local columns = fk.columns or {}
        local label = #columns > 0
            and (table.concat(columns, ', ') .. ' -> ' .. table.concat(fk.referenced or {}, ', '))
          or ((fk.name or '') ~= '' and fk.name or 'references')
        table.insert(
          lines,
          ('  %s %s--%s %s : "%s"'):format(
            entity(parent),
            is_optional(child, columns) and '|o' or '||',
            is_unique(child, columns) and '|o' or 'o{',
            entity(child),
            (label:gsub('"', "'"))
          )
        )
      end
    end
  end
  if #lines > 1 then
    table.insert(lines, '')
  end

  for _, tbl in ipairs(tables) do
    local references, unique = {}, {}
    for _, fk in ipairs(tbl.foreign_keys or {}) do
      for i, column in ipairs(fk.columns or {}) do
        local referenced = (fk.referenced or {})[i]
        references[lower(column)] = referenced and (fk.target .. '.' .. referenced) or fk.target
      end
    end
    for _, index in ipairs(tbl.indexes or {}) do
      if index.unique and not index.primary then
        for _, column in ipairs(index.columns or {}) do
          unique[lower(column)] = true
        end
      end
    end

    table.insert(lines, ('  %s {'):format(entity(tbl)))
    if #(tbl.columns or {}) == 0 then
      table.insert(lines, '    string _no_columns_ "empty"')
    end
    for _, column in ipairs(tbl.columns or {}) do
      local reference = column.references or references[lower(column.name)]
      local keys = {}
      if column.primary_key then
        table.insert(keys, 'PK')
      end
      if reference then
        table.insert(keys, 'FK')
      end
      if unique[lower(column.name)] and not column.primary_key then
        table.insert(keys, 'UK')
      end
      local notes = {}
      if column.nullable == false and not column.primary_key then
        table.insert(notes, 'NOT NULL')
      end
      if reference then
        table.insert(notes, '-> ' .. reference)
      end
      table.insert(
        lines,
        ('    %s %s%s%s'):format(
          attribute_type(column.type_name),
          attribute_name(column.name),
          #keys > 0 and (' ' .. table.concat(keys, ', ')) or '',
          #notes > 0 and (' "%s"'):format(table.concat(notes, ' ')) or ''
        )
      )
    end
    table.insert(lines, '  }')
  end

  return table.concat(lines, '\n')
end

return M
