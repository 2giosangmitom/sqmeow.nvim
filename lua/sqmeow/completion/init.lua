--- Completion metadata shared by all database adapters and completion providers.
local M = {}

-- The parser hint is worth one interruption per session, not one per keystroke.
local hinted = false

--- Forget the one-time parser hint. Tests call this between cases.
function M.reset_hint()
  hinted = false
end

--- Cached drawer nodes for `path`, loading them in the background when missing.
---@param conn_id integer
---@param path string[]
---@return table[]|nil
local function nodes(conn_id, path)
  local drawer = require('sqmeow.ui.drawer')
  local cached = drawer.cached_nodes(conn_id, path)
  if cached == nil then
    drawer.load(conn_id, path, true)
  end
  return cached
end

--- Every cached relation, loading missing levels. `warm` skips Redis keys, which can be many.
---@param conn_id integer
---@param warm boolean|nil
---@return table[] relations
---@return boolean incomplete
---@return table[]|nil schemas
local function relations(conn_id, warm)
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
        if
          group.kind == 'tables'
          or group.kind == 'views'
          or (group.kind == 'keys' and not warm)
        then
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

--- Warm the schema and relation cache; columns load when completion asks for them.
---@param conn_id integer
function M.ensure(conn_id)
  relations(conn_id, true)
end

--- Redis and MongoDB have keys and collections, not SQL identifiers.
---@param conn table
---@return boolean
local function nosql(conn)
  return conn.dialect == 'redis' or conn.dialect == 'mongodb'
end

--- Case-insensitive identifier equality.
---@param a string|nil
---@param b string|nil
---@return boolean
local function same(a, b)
  return a ~= nil and b ~= nil and a:lower() == b:lower()
end

--- Whether a parsed reference names a relation the cache knows.
---@param ref table
---@param available table[]
---@return boolean
local function known(ref, available)
  for _, relation in ipairs(available) do
    if
      same(ref.name, relation.node.name)
      and (not ref.schema or same(ref.schema, relation.schema))
    then
      return true
    end
  end
  return false
end

--- Tell the user once when an alias cannot resolve because the parser is missing.
local function hint_parser(
  conn,
  bufnr,
  line,
  row,
  qualifier,
  qualifier_schema,
  available,
  schemas,
  parsed,
  incomplete
)
  if hinted or parsed or incomplete or not qualifier or qualifier_schema or nosql(conn) then
    return
  end
  -- A schema or a table name is not an alias, and resolves without the parser.
  for _, schema in ipairs(schemas or {}) do
    if same(qualifier, schema.name) then
      return
    end
  end
  for _, relation in ipairs(available) do
    if same(qualifier, relation.node.name) then
      return
    end
  end
  local text = line
  if row and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  end
  text = text:lower()
  if not (text:find('%f[%w_]from%f[^%w_]') or text:find('%f[%w_]join%f[^%w_]')) then
    return
  end
  hinted = true
  require('sqmeow.core.utils').notify(
    'table-alias completion needs the SQL parser; run :TSInstall sql (see :h sqmeow-completion)',
    vim.log.levels.WARN
  )
end

--- col is a zero-based byte offset; row is an optional one-based buffer row.
---@param bufnr integer
---@param line string
---@param col integer
---@param row integer|nil
---@return table[] items
---@return boolean incomplete
function M.items(bufnr, line, col, row)
  local conn = require('sqmeow.api.connection').target(bufnr)
  if not conn then
    return {}, false
  end
  local context = require('sqmeow.completion.context')
  local sql = require('sqmeow.core.sql')
  local refs, qualifier, qualifier_schema, parsed = context.read(bufnr, line, col, row)
  local quote_start, open = context.open_quote(line:sub(1, col))
  -- Replace through the rest of the word and a closer an autopair plugin added.
  local end_col = col + #line:sub(col + 1):match('^[%w_$]*')
  if open and line:sub(end_col + 1, end_col + 1) == sql.closer(open) then
    end_col = end_col + 1
  end

  --- Add the quoting, or the edit over a typed quote, an identifier needs.
  ---@param item table
  ---@return table
  local function format_item(item)
    if nosql(conn) or item.kind == 'key' then
      return item
    end
    if open then
      -- Keep the delimiter the user typed so the typed text still filters.
      local quoted = open == sql.opener(conn.dialect) and sql.quote(conn.dialect, item.label)
        or sql.wrap(open, item.label)
      local lnum = (row or 1) - 1
      item.filterText = quoted
      item.textEdit = {
        newText = quoted,
        range = {
          start = { line = lnum, character = quote_start - 1 },
          ['end'] = { line = lnum, character = end_col },
        },
      }
    elseif sql.needs_quote(conn.dialect, item.label, qualifier ~= nil) then
      item.insertText = sql.quote(conn.dialect, item.label)
    end
    return item
  end

  local available, incomplete, schemas = relations(conn.id)
  hint_parser(
    conn,
    bufnr,
    line,
    row,
    qualifier,
    qualifier_schema,
    available,
    schemas,
    parsed,
    incomplete
  )

  local items = {}
  for _, schema in ipairs(schemas or {}) do
    if schema.kind == 'schema' and not qualifier then
      table.insert(items, format_item({ label = schema.name, kind = 'schema', detail = 'schema' }))
    end
  end

  -- An alias in the statement wins over a relation of the same name. A ref only
  -- counts when its relation is known, so an unfinished `main.` stays a schema.
  local known_refs = vim.tbl_filter(function(ref)
    return known(ref, available)
  end, refs)
  local targets
  if qualifier and not qualifier_schema then
    local aliases, names = {}, {}
    for _, ref in ipairs(known_refs) do
      if same(qualifier, ref.alias) then
        table.insert(aliases, ref)
      elseif same(qualifier, ref.name) then
        table.insert(names, ref)
      end
    end
    targets = #aliases > 0 and aliases or names
    if #targets == 0 then
      targets = nil
    end
  end

  --- Whether one of `targets_` names `rel` in `schema`.
  ---@param targets_ table[]
  ---@param rel table
  ---@param schema string
  ---@return boolean
  local function selected_by(targets_, rel, schema)
    for _, ref in ipairs(targets_) do
      if same(ref.name, rel.name) and (not ref.schema or same(ref.schema, schema)) then
        return true
      end
    end
    return false
  end

  for _, relation in ipairs(available) do
    local rel, schema = relation.node, relation.schema
    local show_relation, show_columns = false, false
    if qualifier_schema then
      -- `schema.table.` names one relation directly.
      show_columns = same(qualifier, rel.name) and same(qualifier_schema, schema)
    elseif qualifier then
      if targets then
        show_columns = selected_by(targets, rel, schema)
      elseif same(qualifier, schema) then
        show_relation = true
      else
        show_columns = same(qualifier, rel.name)
      end
    elseif #known_refs > 0 then
      show_columns = selected_by(known_refs, rel, schema)
    else
      show_relation = true
    end
    if show_relation then
      table.insert(
        items,
        format_item({ label = rel.name, kind = rel.kind, detail = rel.kind, schema = schema })
      )
    end
    if show_columns and rel.expandable ~= false then
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
