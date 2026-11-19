--- Render collected table structures as a Mermaid `erDiagram`. Pure: no RPC, no editor state.

local M = {}

local model = require('sqmeow.core.erd.model')

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

--- Directions Mermaid's ER lexer finds anywhere on a line after `direction`.
local directions = { TB = true, BT = true, RL = true, LR = true }

--- Text safe inside a Mermaid double-quoted string.
---@param text string
---@return string
local function quoted(text)
  text = text:gsub('["%%\\]', "'"):gsub('%c', ' ')
  -- `direction LR` anywhere on a line is read as a layout statement, in any letter case.
  text = text:gsub('([Dd][Ii][Rr][Ee][Cc][Tt][Ii][Oo][Nn])(%s+)(%a%a)', function(word, _, way)
    if directions[way:upper()] then
      return word .. '_' .. way
    end
  end)
  return '"' .. text .. '"'
end

--- Render `schema` as a Mermaid `erDiagram`.
---
--- Relationship lines come first, parent to child. The parent end is `||` when every
--- foreign key column is NOT NULL and `|o` otherwise; the child end is `|o` when the
--- foreign key contains the primary key or a full unique index, compared under the
--- parent's collation where the adapter reports one, and `o{` otherwise. The line is
--- solid (`--`) when the key is part of the child's primary key and dotted (`..`)
--- otherwise. Foreign keys to tables outside `schema.tables` are tagged on their
--- columns but drawn as no line.
---@param schema { tables: sqmeow.SchemaTable[] }
---@return string
function M.erd(schema)
  local tables = schema.tables or {}
  local facts = model.analyze(tables)
  local finders = facts.finders

  -- Entity names are always quoted, so keywords such as `end` stay names, and qualified
  -- only where the bare table name would be ambiguous.
  local entity_name = allocator(' ')
  local entities = {}
  for _, tbl in ipairs(tables) do
    entities[tbl] = quoted(entity_name(quoted(facts.catalog.label(tbl)):sub(2, -2)))
  end

  local lines = { 'erDiagram' }
  for _, relation in ipairs(facts.relations) do
    local columns = relation.columns
    local fk = relation.fk
    local label = #columns > 0
        and (table.concat(columns, ', ') .. ' -> ' .. table.concat(relation.referenced, ', '))
      or ((fk.name or '') ~= '' and fk.name or 'references')
    table.insert(
      lines,
      ('  %s %s%s%s %s : %s'):format(
        entities[relation.parent],
        relation.optional and '|o' or '||',
        relation.identifying and '--' or '..',
        relation.unique and '|o' or 'o{',
        entities[relation.child],
        quoted(label)
      )
    )
  end
  if #lines > 1 then
    table.insert(lines, '')
  end

  for _, tbl in ipairs(tables) do
    local find_column = finders[tbl]
    local references = {}
    for _, fk in ipairs(tbl.foreign_keys or {}) do
      for i, name in ipairs(fk.columns or {}) do
        local column = find_column(name)
        if column then
          local referenced = (fk.referenced or {})[i]
          references[column] = referenced and (fk.target .. '.' .. referenced) or fk.target
        end
      end
    end
    -- `UK` marks a column unique on its own; a composite key does not make each member
    -- unique, and a partial index only among the rows it covers.
    local unique = model.unique_columns(tbl, find_column)

    local attribute_name = allocator('_')
    table.insert(lines, ('  %s {'):format(entities[tbl]))
    if #(tbl.columns or {}) == 0 then
      table.insert(lines, '    string _no_columns_ "empty"')
    end
    for _, column in ipairs(tbl.columns or {}) do
      local reference = references[column] or column.references
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
