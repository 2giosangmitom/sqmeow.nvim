--- Relationship facts shared by the diagram renderers: which table a foreign key points at,
--- and whether each end is optional, unique, or identifying. Pure: no RPC, no editor state.

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

--- An index key as a column name. Index keys can be SQL, as PostgreSQL's quote mixed-case
--- names; catalog column names never are, so only index keys pass through here.
---@param name string
---@return string
function M.unquote(name)
  local inner = name:match('^"(.*)"$')
  return inner and inner:gsub('""', '"') or name
end

--- Find a table's columns by name: an exact match, else the only case-insensitive one.
---@param tbl sqmeow.SchemaTable
---@return fun(name: string|nil): table|nil
function M.column_finder(tbl)
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
    return exact[name] or folded[lower(name)] or nil
  end
end

--- The columns `names` resolve to, or nil when any of them is not a known column.
---@param find fun(name: string|nil): table|nil
---@param names string[]
---@return table<table, true>|nil
function M.column_set(find, names)
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

--- Whether every column of the nonempty set `a` is in `b`.
---@param a table<table, true>|nil
---@param b table<table, true>|nil
---@return boolean
local function subset(a, b)
  if not a or not b or next(a) == nil then
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
function M.primary_key(tbl)
  local set = {}
  for _, column in ipairs(tbl.columns or {}) do
    if column.primary_key then
      set[column] = true
    end
  end
  return set
end

---@class sqmeow.ErdKey
---@field columns table<table, true>
---@field collations table<table, string> Collation of each column, where the adapter says.

--- The keys that hold a value at most once: the primary key and every full unique index.
--- A partial index leaves rows outside its predicate free to repeat, so it is no key.
---@param tbl sqmeow.SchemaTable
---@param find fun(name: string|nil): table|nil
---@return sqmeow.ErdKey[]
function M.unique_keys(tbl, find)
  local keys = { { columns = M.primary_key(tbl), collations = {} } }
  for _, index in ipairs(tbl.indexes or {}) do
    if (index.unique or index.primary) and not index.partial then
      local columns, collations = {}, {}
      for i, name in ipairs(index.columns or {}) do
        local column = find(M.unquote(name))
        if not column then
          columns = nil
          break
        end
        columns[column] = true
        collations[column] = (index.collations or {})[i]
      end
      if columns then
        table.insert(keys, { columns = columns, collations = collations })
      end
    end
  end
  return keys
end

--- The columns unique on their own: a full single-column unique index that is not the
--- primary key. A composite key does not make each member unique, and a partial index
--- only among the rows it covers.
---@param tbl sqmeow.SchemaTable
---@param find fun(name: string|nil): table|nil
---@return table<table, true>
function M.unique_columns(tbl, find)
  local unique = {}
  for _, index in ipairs(tbl.indexes or {}) do
    if index.unique and not index.primary and not index.partial and #(index.columns or {}) == 1 then
      local column = find(M.unquote(index.columns[1]))
      if column then
        unique[column] = true
      end
    end
  end
  return unique
end

---@class sqmeow.ErdCatalog
---@field find fun(child: sqmeow.SchemaTable, fk: table): sqmeow.SchemaTable|nil
---@field label fun(tbl: sqmeow.SchemaTable): string Qualified only where the bare name is ambiguous.

--- Index tables by name once; a folded name shared by two tables resolves to neither.
---@param tables sqmeow.SchemaTable[]
---@return sqmeow.ErdCatalog
function M.catalog(tables)
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
  local qualify = vim.tbl_count(schemas) > 1

  return {
    --- The table a foreign key references. The catalog's `target_schema` and
    --- `target_relation` decide when present; hand-built input may give only `target`:
    --- `relation` in the child's schema, or `schema.relation`. An unqualified name may
    --- contain dots itself, so it is tried whole first.
    find = function(child, fk)
      if (fk.target_relation or '') ~= '' then
        local target_schema = (fk.target_schema or '') ~= '' and fk.target_schema or child.schema
        return exact[key(target_schema or '', fk.target_relation)]
      end
      local target = fk.target or ''
      local found = lookup(child.schema or '', target)
      if found then
        return found
      end
      local target_schema, relation = target:match('^([^.]+)%.(.+)$')
      return target_schema and lookup(target_schema, relation) or nil
    end,
    label = function(tbl)
      local name = tbl.relation
      if (qualify or names[lower(name)] > 1) and (tbl.schema or '') ~= '' then
        name = tbl.schema .. '.' .. name
      end
      return name
    end,
  }
end

--- One foreign key between two tables of the diagram.
---@class sqmeow.ErdRelation
---@field child sqmeow.SchemaTable
---@field parent sqmeow.SchemaTable
---@field fk table The foreign key as the adapter reported it.
---@field columns string[] Child columns, in key order.
---@field referenced string[] Parent columns, in key order.
---@field optional boolean A child row may reference no parent: some key column is nullable.
---@field unique boolean At most one child row per parent row.
---@field identifying boolean The key is part of the child's primary key.

--- What every renderer needs to know about a set of tables.
---@class sqmeow.ErdFacts
---@field catalog sqmeow.ErdCatalog
---@field finders table<sqmeow.SchemaTable, fun(name: string|nil): table|nil>
---@field keys table<sqmeow.SchemaTable, sqmeow.ErdKey[]>
---@field relations sqmeow.ErdRelation[] Child by child, in foreign key order.

--- Resolve every foreign key whose target is one of `tables`.
---
--- The parent end is optional when some foreign key column is nullable. The child end is
--- unique when the foreign key contains the primary key or a full unique index, compared
--- under the parent's collation where the adapter reports one. The key is identifying when
--- every one of its columns is in the child's primary key.
---@param tables sqmeow.SchemaTable[]
---@return sqmeow.ErdFacts
function M.analyze(tables)
  local catalog = M.catalog(tables)
  local finders, table_keys = {}, {}
  for _, tbl in ipairs(tables) do
    finders[tbl] = M.column_finder(tbl)
    table_keys[tbl] = M.unique_keys(tbl, finders[tbl])
  end

  --- The collation the parent compares `referenced` with: that of its key holding the
  --- column, or `BINARY`, the default of the one adapter that reports collations.
  local function parent_collation(parent, referenced)
    local column = finders[parent](referenced)
    for _, candidate in ipairs(table_keys[parent]) do
      if column and candidate.collations[column] then
        return candidate.collations[column]
      end
    end
    return 'BINARY'
  end

  --- Whether `fk` lets at most one child row reference a parent row: the foreign key
  --- contains a unique key of the child, which compares its values the way the parent
  --- key does wherever the adapter reports collations.
  local function one_child(child, parent, fk, set)
    local positions = {}
    for i, name in ipairs(fk.columns or {}) do
      local column = finders[child](name)
      if column then
        positions[column] = i
      end
    end
    for _, candidate in ipairs(table_keys[child]) do
      if subset(candidate.columns, set) then
        local agrees = true
        for column in pairs(candidate.columns) do
          local collation = candidate.collations[column]
          local referenced = (fk.referenced or {})[positions[column]]
          if collation and not referenced then
            agrees = false
          elseif collation then
            agrees = agrees and collation:upper() == parent_collation(parent, referenced):upper()
          end
        end
        if agrees then
          return true
        end
      end
    end
    return false
  end

  local relations = {}
  for _, child in ipairs(tables) do
    local pk = M.primary_key(child)
    for _, fk in ipairs(child.foreign_keys or {}) do
      local parent = catalog.find(child, fk)
      if parent then
        local columns = fk.columns or {}
        local set = M.column_set(finders[child], columns)

        local optional = not set
        for column in pairs(set or {}) do
          optional = optional or column.nullable ~= false
        end
        local identifying = set ~= nil
        for column in pairs(set or {}) do
          identifying = identifying and pk[column] == true
        end

        table.insert(relations, {
          child = child,
          parent = parent,
          fk = fk,
          columns = columns,
          referenced = fk.referenced or {},
          optional = optional,
          unique = set ~= nil and one_child(child, parent, fk, set),
          identifying = identifying,
        })
      end
    end
  end

  return { catalog = catalog, finders = finders, keys = table_keys, relations = relations }
end

--- Short spellings of verbose SQL type names, longest first: `character` is a prefix of
--- `character varying`.
local aliases = {
  { '^character varying', 'varchar' },
  { '^character', 'char' },
  { '^timestamp without time zone', 'timestamp' },
  { '^timestamp with time zone', 'timestamptz' },
  { '^time without time zone', 'time' },
  { '^time with time zone', 'timetz' },
  { '^double precision', 'float8' },
}

--- A type name as short as it can be without losing its arguments.
---@param type_name string|nil
---@return string
function M.short_type(type_name)
  local t = vim.trim(type_name or '')
  local folded = t:lower()
  for _, alias in ipairs(aliases) do
    local _, stop = folded:find(alias[1])
    if stop then
      return alias[2] .. t:sub(stop + 1)
    end
  end
  return t
end

---@class sqmeow.ErdColumn
---@field name string
---@field type string Short type name.
---@field pk boolean
---@field fk boolean
---@field uk boolean Unique on its own.
---@field nullable boolean
---@field references string|nil `table.column` this column points at, inside or outside the diagram.

---@class sqmeow.ErdNode
---@field id integer
---@field schema string
---@field relation string
---@field label string
---@field columns sqmeow.ErdColumn[]

---@class sqmeow.ErdEdge
---@field id integer
---@field child integer Node id.
---@field parent integer Node id.
---@field child_columns integer[] Indexes into the child's columns, in key order.
---@field parent_columns integer[] Indexes into the parent's columns, in key order.
---@field name string
---@field label string `a, b -> x, y`.
---@field optional boolean
---@field unique boolean
---@field identifying boolean

---@class sqmeow.ErdGraph
---@field nodes sqmeow.ErdNode[]
---@field edges sqmeow.ErdEdge[]

--- The diagram's tables and the foreign keys between them.
---@param schema { tables: sqmeow.SchemaTable[] }
---@return sqmeow.ErdGraph
function M.graph(schema)
  local tables = schema.tables or {}
  local facts = M.analyze(tables)

  local ids, positions = {}, {}
  local nodes = {}
  for index, tbl in ipairs(tables) do
    ids[tbl] = index
    positions[tbl] = {}
    local references = {}
    for _, fk in ipairs(tbl.foreign_keys or {}) do
      for i, name in ipairs(fk.columns or {}) do
        local column = facts.finders[tbl](name)
        if column then
          local referenced = (fk.referenced or {})[i]
          local target = fk.target or fk.target_relation or ''
          references[column] = referenced and (target .. '.' .. referenced) or target
        end
      end
    end
    local unique = M.unique_columns(tbl, facts.finders[tbl])

    local columns = {}
    for position, column in ipairs(tbl.columns or {}) do
      positions[tbl][column] = position
      local reference = references[column] or column.references
      table.insert(columns, {
        name = column.name or '',
        type = M.short_type(column.type_name),
        pk = column.primary_key == true,
        fk = reference ~= nil,
        uk = unique[column] == true and not column.primary_key,
        nullable = column.nullable ~= false,
        references = reference,
      })
    end
    table.insert(nodes, {
      id = index,
      schema = tbl.schema or '',
      relation = tbl.relation,
      label = facts.catalog.label(tbl),
      columns = columns,
    })
  end

  local function indexes(tbl, names)
    local found = {}
    for _, name in ipairs(names) do
      local column = facts.finders[tbl](name)
      if column then
        table.insert(found, positions[tbl][column])
      end
    end
    return found
  end

  local edges = {}
  for _, relation in ipairs(facts.relations) do
    local columns, referenced = relation.columns, relation.referenced
    table.insert(edges, {
      id = #edges + 1,
      child = ids[relation.child],
      parent = ids[relation.parent],
      child_columns = indexes(relation.child, columns),
      parent_columns = indexes(relation.parent, referenced),
      name = relation.fk.name or '',
      label = #columns > 0
          and (table.concat(columns, ', ') .. ' -> ' .. table.concat(referenced, ', '))
        or ((relation.fk.name or '') ~= '' and relation.fk.name or 'references'),
      optional = relation.optional,
      unique = relation.unique,
      identifying = relation.identifying,
    })
  end

  return { nodes = nodes, edges = edges }
end

return M
