--- Completion metadata shared by all database adapters and completion providers.
local M = {}

--- Retained for backwards compatibility; metadata belongs to the drawer cache.
---@param _conn_id integer|nil
function M.invalidate(_conn_id) end

--- Retained for backwards compatibility; metadata belongs to the drawer cache.
function M.invalidate_all() end

-- The parser hint is worth one interruption per session, not one per keystroke.
local hinted = false

--- Forget the one-time parser hint. Tests call this between cases.
function M.reset_hint()
  hinted = false
end

--- Read cached drawer nodes for `path`, scheduling a background load when missing.
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

--- Collect all cached relations across schemas, queueing loads for missing levels.
---@param conn_id integer
---@return table[] result
---@return boolean incomplete
---@return table[]|nil schemas
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
---@param conn_id integer
function M.ensure(conn_id)
  relations(conn_id)
end

--- Quote `name` using the delimiter matched from `opener`.
---@param opener string|nil
---@param name string
---@return string
local function quote_with_opener(opener, name)
  if opener == '[' then
    return '[' .. name:gsub(']', ']]') .. ']'
  elseif opener == '`' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Locate an unclosed SQL identifier quote opener at the end of `prefix`.
---@param prefix string
---@return integer|nil q_start 1-based byte index of the opening delimiter
---@return string|nil q_char The opening delimiter (`"`, `` ` ``, or `[`)
local function find_open_quote(prefix)
  local q_start, q_char, close_char = nil, nil, nil
  local i, len = 1, #prefix
  while i <= len do
    local ch = prefix:sub(i, i)
    if not q_start then
      if ch == "'" then
        i = i + 1
        while i <= len do
          if prefix:sub(i, i) == "'" then
            if prefix:sub(i + 1, i + 1) == "'" then
              i = i + 1
            else
              break
            end
          end
          i = i + 1
        end
      elseif ch == '"' or ch == '`' or ch == '[' then
        local prev = i > 1 and prefix:sub(i - 1, i - 1) or ''
        if i == 1 or prev:match('^[%s%.,%(%=<>!%+%-/%*;]$') then
          q_start = i
          q_char = ch
          close_char = ch == '[' and ']' or ch
        end
      end
    elseif ch == close_char then
      if prefix:sub(i + 1, i + 1) == close_char then
        i = i + 1
      else
        q_start, q_char, close_char = nil, nil, nil
      end
    end
    i = i + 1
  end
  return q_start, q_char
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
  if hinted or parsed or incomplete or not qualifier or qualifier_schema then
    return
  end
  if conn.dialect == 'redis' or conn.dialect == 'mongodb' then
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
  local refs, qualifier, qualifier_schema, parsed =
    require('sqmeow.completion.context').read(bufnr, line, col, row)
  local prefix = line and line:sub(1, col) or ''
  local q_start, q_char = find_open_quote(prefix)
  local suffix = line and line:sub(col + 1):match('^[%w_$]*') or ''
  local end_col = col + #suffix
  local sql_util = require('sqmeow.core.sql')
  local is_nosql = conn.dialect == 'redis' or conn.dialect == 'mongodb'

  --- Format a completion item with dialect-specific identifier quoting when appropriate.
  ---@param item table
  ---@return table
  local function format_item(item)
    if is_nosql or item.kind == 'key' then
      return item
    end
    local needs_quote = not item.label:match('^[a-z_][a-z0-9_$]*$')
      or (conn.dialect ~= nil and not qualifier and sql_util.is_reserved(conn.dialect, item.label))
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
          ['end'] = { line = (row or 1) - 1, character = end_col },
        },
      }
    else
      item.insertText = quoted
      item.filterText = item.label
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
  local targets
  if qualifier and not qualifier_schema then
    local aliases, names = {}, {}
    for _, ref in ipairs(refs) do
      if known(ref, available) then
        if same(qualifier, ref.alias) then
          table.insert(aliases, ref)
        elseif same(qualifier, ref.name) then
          table.insert(names, ref)
        end
      end
    end
    targets = #aliases > 0 and aliases or names
    if #targets == 0 then
      targets = nil
    end
  end

  local function selected_by(targets_, rel, schema)
    for _, ref in ipairs(targets_) do
      if same(ref.name, rel.name) and (not ref.schema or same(ref.schema, schema)) then
        return true
      end
    end
    return false
  end

  local has_known_ref = false
  for _, ref in ipairs(refs) do
    if known(ref, available) then
      has_known_ref = true
      break
    end
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
    elseif has_known_ref then
      show_columns = selected_by(refs, rel, schema)
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
