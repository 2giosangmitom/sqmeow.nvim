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

--- Warm the root cache; deeper metadata is loaded when completion is requested.
function M.ensure(conn_id)
  nodes(conn_id, {})
end

--- col is a zero-based byte offset; row is an optional one-based buffer row.
---@return table[] items
---@return boolean incomplete
function M.items(bufnr, line, col, row)
  local conn = require('sqmeow.api.connection').target(bufnr)
  if not conn then
    return {}, false
  end
  local refs, qualifier, qualifier_schema =
    require('sqmeow.completion.context').read(bufnr, line, col, row)
  local available, incomplete, schemas = relations(conn.id)
  local items = {}
  for _, schema in ipairs(schemas or {}) do
    if schema.kind == 'schema' and not qualifier then
      table.insert(items, { label = schema.name, kind = 'schema', detail = 'schema' })
    end
  end
  local function same(a, b)
    return a and b and a:lower() == b:lower()
  end
  for _, relation in ipairs(available) do
    local rel, schema = relation.node, relation.schema
    if not qualifier or same(qualifier, schema) then
      table.insert(items, { label = rel.name, kind = rel.kind, detail = rel.kind, schema = schema })
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
          table.insert(items, {
            label = column.name,
            kind = 'column',
            detail = column.type_name,
            schema = schema,
            relation = rel.name,
            primary_key = column.primary_key,
            documentation = #doc > 0 and table.concat(doc, ', ') or nil,
          })
        end
      end
    end
  end
  return items, incomplete
end

return M
