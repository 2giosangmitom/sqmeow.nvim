--- Completion metadata shared by all database adapters and completion providers.
local M = {}

-- Metadata and in-flight requests belong to the drawer cache.
function M.invalidate(_conn_id) end
function M.invalidate_all() end

local function nodes(conn_id, path)
  local drawer = require('sqmeow.ui.drawer')
  local cached = drawer.cached_nodes(conn_id, path)
  if cached == nil then
    drawer.load(conn_id, path, true)
  end
  return cached
end

local function relations(conn_id)
  local result, incomplete = {}, false
  local schemas = nodes(conn_id, {})
  if not schemas then
    return result, true
  end
  for _, schema in ipairs(schemas) do
    -- Cluster databases and the Roles heading are not schemas.
    if schema.kind == 'schema' then
      local groups = nodes(conn_id, { schema.name })
      incomplete = incomplete or groups == nil
      for _, group in ipairs(groups or {}) do
        if group.kind == 'tables' or group.kind == 'views' or group.kind == 'keys' then
          local path = { schema.name, group.key }
          local members = nodes(conn_id, path)
          incomplete = incomplete or members == nil
          for _, relation in ipairs(members or {}) do
            table.insert(result, {
              schema = schema.name,
              node = relation,
              path = { schema.name, group.key, relation.name },
            })
          end
        end
      end
    end
  end
  return result, incomplete, schemas
end

--- Warm the schema and relation cache; leaf columns are loaded when completion is requested.
function M.ensure(conn_id)
  relations(conn_id)
end

local function quote_with_opener(opener, name)
  if opener == '[' then
    return '[' .. name:gsub(']', ']]') .. ']'
  elseif opener == '`' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- col is a zero-based byte offset; row is an optional one-based buffer row.
---@return table[] items
---@return boolean incomplete
function M.items(bufnr, line, col, row)
  local conn = require('sqmeow.api.connection').target(bufnr)
  if not conn then
    return {}, false
  end
  local prefix = line and line:sub(1, col) or ''
  local q_start, q_char = prefix:match('()(["`\x5b])[%w_$]*$')
  if
    q_start
    and q_start > 1
    and not prefix:sub(q_start - 1, q_start - 1):match('^[%s%.,%(%=<>!%+%-/%*;]$')
  then
    q_start, q_char = nil, nil
  end
  local sql_util = require('sqmeow.core.sql')
  local is_nosql = conn.dialect == 'redis' or conn.dialect == 'mongodb'
  local function format_item(item)
    if is_nosql or item.kind == 'key' then
      return item
    end
    local needs_quote = not item.label:match('^[a-z_][a-z0-9_$]*$')
    if item.kind == 'schema' and not conn.dialect and item.label:match('^%d+$') then
      needs_quote = false
    end
    local should_quote = q_start ~= nil
      or needs_quote
      or (conn.dialect ~= nil and (item.kind == 'table' or item.kind == 'view'))
    if not should_quote then
      return item
    end
    local quoted = conn.dialect and sql_util.quote(conn.dialect, item.label)
      or quote_with_opener(q_char, item.label)
    if q_start then
      item.filterText = quoted
      item.textEdit = {
        newText = quoted,
        range = {
          start = { line = (row or 1) - 1, character = q_start - 1 },
          ['end'] = { line = (row or 1) - 1, character = col },
        },
      }
    else
      item.insertText = quoted
      item.filterText = item.label
    end
    return item
  end

  local refs, qualifier, qualifier_schema =
    require('sqmeow.completion.context').read(bufnr, line, col, row)
  local available, incomplete, schemas = relations(conn.id)
  local items = {}
  for _, schema in ipairs(schemas or {}) do
    if schema.kind == 'schema' and not qualifier then
      table.insert(items, format_item({ label = schema.name, kind = 'schema', detail = 'schema' }))
    end
  end
  local function same(a, b)
    return a and b and a:lower() == b:lower()
  end
  for _, relation in ipairs(available) do
    local rel, schema = relation.node, relation.schema
    if not qualifier or same(qualifier, schema) then
      table.insert(
        items,
        format_item({ label = rel.name, kind = rel.kind, detail = rel.kind, schema = schema })
      )
    end
    local selected = same(qualifier, rel.name)
      and (not qualifier_schema or same(qualifier_schema, schema))
    -- When a qualifier is bound in FROM, its schema is authoritative.
    for _, ref in ipairs(refs) do
      if same(qualifier, ref.alias or ref.name) then
        selected = false
        break
      end
    end
    for _, ref in ipairs(refs) do
      if same(ref.name, rel.name) and (not ref.schema or same(ref.schema, schema)) then
        selected = selected or not qualifier or same(qualifier, ref.alias or ref.name)
      end
    end
    if selected and rel.expandable ~= false then
      local columns = nodes(conn.id, relation.path)
      incomplete = incomplete or columns == nil
      for _, column in ipairs(columns or {}) do
        if column.kind == 'column' then
          local doc = {}
          if column.primary_key then
            table.insert(doc, 'Primary Key')
          end
          if column.references then
            table.insert(doc, 'Foreign Key: ' .. column.references)
          end
          table.insert(
            items,
            format_item({
              label = column.name,
              kind = 'column',
              detail = column.type_name,
              schema = schema,
              relation = rel.name,
              primary_key = column.primary_key,
              documentation = #doc > 0 and table.concat(doc, ', ') or nil,
            })
          )
        end
      end
    end
  end
  return items, incomplete
end

return M
