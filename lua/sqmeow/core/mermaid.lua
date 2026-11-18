--- Render collected table structures as a Mermaid `erDiagram`. Pure: no RPC, no editor state.

local M = {}

---@param name string|nil
---@return string
local function lower(name)
  return (name or ''):lower()
end

---@param schema string
---@param relation string
---@return string
local function key(schema, relation)
  return schema .. '\0' .. relation
end

--- A column name as the catalog spells it: index definitions quote mixed-case names.
---@param name string
---@return string
local function unquote(name)
  local inner = name:match('^"(.*)"$')
  return inner and inner:gsub('""', '"') or name
end

--- Find a table's columns by name: an exact match, else the only case-insensitive one.
---@param tbl sqmeow.SchemaTable
---@return fun(name: string|nil): table|nil
local function column_finder(tbl)
  local exact, folded = {}, {}
  for _, column in ipairs(tbl.columns or {}) do
    exact[column.name] = column
    local name = lower(column.name)
    -- `false` marks a folded name shared by distinct columns.
    folded[name] = folded[name] == nil and column or false
  end
  return function(name)
    if not name then
      return nil
    end
    name = unquote(name)
    return exact[name] or folded[lower(name)] or nil
  end
end

--- The columns `names` resolve to, or nil when any of them is not a known column.
---@param find fun(name: string|nil): table|nil
---@param names string[]
---@return table<table, true>|nil
local function column_set(find, names)
  if #names == 0 then
    return nil
  end
  local set = {}
  for _, name in ipairs(names) do
    local column = find(name)
    if not column then
      return nil
    end
    set[column] = true
  end
  return set
end

---@param a table<table, true>|nil
---@param b table<table, true>|nil
---@return boolean
local function same_set(a, b)
  if not a or not b or vim.tbl_count(a) ~= vim.tbl_count(b) then
    return false
  end
  for column in pairs(a) do
    if not b[column] then
      return false
    end
  end
  return true
end

---@param tbl sqmeow.SchemaTable
---@return table<table, true>
local function primary_key(tbl)
  local set = {}
  for _, column in ipairs(tbl.columns or {}) do
    if column.primary_key then
      set[column] = true
    end
  end
  return set
end

--- Words Mermaid's attribute lexer reads as key markers rather than names.
local reserved = { pk = true, fk = true, uk = true }

--- A Mermaid attribute word: letters, digits and `_-()[]`, not a key marker.
---@param text string
---@param fallback string
---@param replacement string What other characters become.
---@return string
local function attribute_word(text, fallback, replacement)
  local word = text:gsub('[^%w_%-()%[%]]', replacement)
  if word == '' then
    word = fallback
  end
  if word:match('^[%d%-(%[]') then
    word = '_' .. word
  end
  if reserved[word:lower()] then
    word = word .. '_'
  end
  return word
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
  t = t:gsub('%s*,%s*', '_'):gsub('%s+', '_')
  return attribute_word(t, 'unknown', '')
end

--- Hand out distinct names: `base`, then `base<sep>2`, `base<sep>3`, ...
---@param separator string
---@return fun(base: string): string
local function allocator(separator)
  local taken = {}
  return function(base)
    local name, n = base, 1
    while taken[name] do
      n = n + 1
      name = base .. separator .. n
    end
    taken[name] = true
    return name
  end
end

--- Text safe inside a Mermaid double-quoted string.
---@param text string
---@return string
local function quoted(text)
  return '"' .. text:gsub('["%%\\]', "'"):gsub('%c', ' ') .. '"'
end

--- Render `schema` as a Mermaid `erDiagram`.
---
--- Relationship lines come first, parent to child. The parent end is `||` when every
--- foreign key column is NOT NULL and `|o` otherwise; the child end is `|o` when the
--- key columns are unique and `o{` otherwise. The line is solid (`--`) when the key
--- is part of the child's primary key and dotted (`..`) otherwise. Foreign keys to
--- tables outside `schema.tables` are tagged on their columns but drawn as no line.
---@param schema { tables: sqmeow.SchemaTable[] }
---@return string
function M.erd(schema)
  local tables = schema.tables or {}

  -- Index tables once; a folded name shared by two tables resolves to neither.
  local exact, folded, schemas, names = {}, {}, {}, {}
  for _, tbl in ipairs(tables) do
    local table_schema = tbl.schema or ''
    exact[key(table_schema, tbl.relation)] = exact[key(table_schema, tbl.relation)] or tbl
    local fold = key(lower(table_schema), lower(tbl.relation))
    folded[fold] = folded[fold] == nil and tbl or false
    schemas[table_schema] = true
    names[lower(tbl.relation)] = (names[lower(tbl.relation)] or 0) + 1
  end
  local function lookup(table_schema, relation)
    return exact[key(table_schema, relation)]
      or folded[key(lower(table_schema), lower(relation))]
      or nil
  end
  --- The table a foreign key names: `relation` in the child's schema, or `schema.relation`.
  --- An unqualified name may contain dots itself, so it is tried whole first.
  local function find(child, target)
    target = target or ''
    local found = lookup(child.schema or '', target)
    if found then
      return found
    end
    local target_schema, relation = target:match('^([^.]+)%.(.+)$')
    return target_schema and lookup(target_schema, relation) or nil
  end

  -- Entity names are always quoted, so keywords such as `end` stay names, and qualified
  -- only where the bare table name would be ambiguous.
  local qualify = vim.tbl_count(schemas) > 1
  local entity_name = allocator(' ')
  local entities = {}
  for _, tbl in ipairs(tables) do
    local name = tbl.relation
    if (qualify or names[lower(name)] > 1) and (tbl.schema or '') ~= '' then
      name = tbl.schema .. '.' .. name
    end
    entities[tbl] = quoted(entity_name(quoted(name):sub(2, -2)))
  end

  local finders = {}
  for _, tbl in ipairs(tables) do
    finders[tbl] = column_finder(tbl)
  end

  local lines = { 'erDiagram' }
  for _, child in ipairs(tables) do
    local find_column = finders[child]
    local pk = primary_key(child)
    for _, fk in ipairs(child.foreign_keys or {}) do
      local parent = find(child, fk.target)
      if parent then
        local columns = fk.columns or {}
        local set = column_set(find_column, columns)

        local optional = not set
        for column in pairs(set or {}) do
          optional = optional or column.nullable ~= false
        end
        local unique = same_set(set, pk)
        for _, index in ipairs(child.indexes or {}) do
          if (index.unique or index.primary) and not unique then
            unique = same_set(set, column_set(find_column, index.columns or {}))
          end
        end
        local identifying = set ~= nil
        for column in pairs(set or {}) do
          identifying = identifying and pk[column] == true
        end

        local label = #columns > 0
            and (table.concat(columns, ', ') .. ' -> ' .. table.concat(fk.referenced or {}, ', '))
          or ((fk.name or '') ~= '' and fk.name or 'references')
        table.insert(
          lines,
          ('  %s %s%s%s %s : %s'):format(
            entities[parent],
            optional and '|o' or '||',
            identifying and '--' or '..',
            unique and '|o' or 'o{',
            entities[child],
            quoted(label)
          )
        )
      end
    end
  end
  if #lines > 1 then
    table.insert(lines, '')
  end

  for _, tbl in ipairs(tables) do
    local find_column = finders[tbl]
    local references, unique = {}, {}
    for _, fk in ipairs(tbl.foreign_keys or {}) do
      for i, name in ipairs(fk.columns or {}) do
        local column = find_column(name)
        if column then
          local referenced = (fk.referenced or {})[i]
          references[column] = referenced and (fk.target .. '.' .. referenced) or fk.target
        end
      end
    end
    -- `UK` marks a column unique on its own; a composite key does not make each member unique.
    for _, index in ipairs(tbl.indexes or {}) do
      if index.unique and not index.primary and #(index.columns or {}) == 1 then
        local column = find_column(index.columns[1])
        if column then
          unique[column] = true
        end
      end
    end

    local attribute_name = allocator('_')
    table.insert(lines, ('  %s {'):format(entities[tbl]))
    if #(tbl.columns or {}) == 0 then
      table.insert(lines, '    string _no_columns_ "empty"')
    end
    for _, column in ipairs(tbl.columns or {}) do
      local reference = column.references or references[column]
      local keys = {}
      if column.primary_key then
        table.insert(keys, 'PK')
      end
      if reference then
        table.insert(keys, 'FK')
      end
      if unique[column] and not column.primary_key then
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
          attribute_name(attribute_word(column.name or '', 'unnamed', '_')),
          #keys > 0 and (' ' .. table.concat(keys, ', ')) or '',
          #notes > 0 and (' ' .. quoted(table.concat(notes, ' '))) or ''
        )
      )
    end
    table.insert(lines, '  }')
  end

  return table.concat(lines, '\n')
end

return M
