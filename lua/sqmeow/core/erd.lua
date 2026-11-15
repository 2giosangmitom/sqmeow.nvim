--- Extract schema metadata and foreign key relationships into a Mermaid `erDiagram`.

local M = {}

local struct_waiters = {}
local rel_waiters = {}
local nodes_waiters = {}

---@param a string|nil
---@param b string|nil
---@return boolean
local function same_ident(a, b)
  return a == b or (type(a) == 'string' and type(b) == 'string' and a:lower() == b:lower())
end

---@param schema string|nil
---@param relation string
---@return string
local function table_key(schema, relation)
  return ((schema or ''):lower()) .. '.' .. relation:lower()
end

---@param raw_type string|nil
---@return string
local function normalize_mermaid_type(raw_type)
  if not raw_type or raw_type == '' then
    return 'unknown'
  end
  local t = vim.trim(raw_type):lower()
  t = t:gsub('^character varying', 'varchar')
  t = t:gsub('^character', 'char')
  t = t:gsub('^timestamp without time zone', 'timestamp')
  t = t:gsub('^timestamp with time zone', 'timestamptz')
  t = t:gsub('^time without time zone', 'time')
  t = t:gsub('^time with time zone', 'timetz')
  t = t:gsub('^double precision', 'float8')
  t = t:gsub('%s+', '_')
  t = t:gsub('[^%w_%-(),%[%]]', '')
  if t == '' then
    t = 'unknown'
  end
  return t
end

---@param name string|nil
---@return string
local function normalize_mermaid_ident(name)
  if not name or name == '' then
    return 'unnamed'
  end
  local s = name:gsub('[^%w_]', '_')
  if s:match('^%d') then
    s = '_' .. s
  end
  return s
end

---@param schema string|nil
---@param relation string
---@param multi_schema boolean
---@return string
local function format_mermaid_entity_name(schema, relation, multi_schema)
  local raw = (multi_schema and schema and schema ~= '') and (schema .. '.' .. relation) or relation
  if raw:match('^[%a_][%w_]*$') then
    return raw
  end
  return '"' .. raw:gsub('"', '') .. '"'
end

--- Whether `fk_cols` forms an exact UNIQUE or PRIMARY KEY index on `struct`.
---@param struct table|nil
---@param fk_cols string[]|nil
---@return boolean
local function is_unique_fk(struct, fk_cols)
  if not struct or not fk_cols or #fk_cols == 0 then
    return false
  end
  for _, idx in ipairs(struct.indexes or {}) do
    if (idx.unique or idx.primary) and idx.columns and #idx.columns == #fk_cols then
      local all_match = true
      for _, fc in ipairs(fk_cols) do
        local found = false
        for _, ic in ipairs(idx.columns) do
          if same_ident(fc, ic) then
            found = true
            break
          end
        end
        if not found then
          all_match = false
          break
        end
      end
      if all_match then
        return true
      end
    end
  end
  if #fk_cols == 1 then
    local pk_count = 0
    local fk_is_pk = false
    for _, col in ipairs(struct.columns or {}) do
      if col.primary_key then
        pk_count = pk_count + 1
        if same_ident(col.name, fk_cols[1]) then
          fk_is_pk = true
        end
      end
    end
    if fk_is_pk and pk_count == 1 then
      return true
    end
  end
  return false
end

--- Whether any column in `fk_cols` on `struct` is nullable.
---@param struct table|nil
---@param fk_cols string[]|nil
---@return boolean
local function is_nullable_fk(struct, fk_cols)
  if not struct or not fk_cols or #fk_cols == 0 then
    return true
  end
  for _, fc in ipairs(fk_cols) do
    for _, col in ipairs(struct.columns or {}) do
      if same_ident(col.name, fc) and col.nullable then
        return true
      end
    end
  end
  return false
end

--- Build a Mermaid `erDiagram` string and normalized relationship edge list.
---@param tables_map table<string, sqmeow.ErdTable>
---@param table_order string[]
---@return string mermaid
---@return sqmeow.ErdEdge[] edges
function M.build_mermaid(tables_map, table_order)
  local schemas_seen = {}
  local schema_count = 0
  for _, key in ipairs(table_order) do
    local entry = tables_map[key]
    if entry and entry.schema and entry.schema ~= '' and not schemas_seen[entry.schema:lower()] then
      schemas_seen[entry.schema:lower()] = true
      schema_count = schema_count + 1
    end
  end
  local multi_schema = schema_count > 1

  local edges = {}
  local edge_seen = {}

  for _, key in ipairs(table_order) do
    local entry = tables_map[key]
    local struct = entry and entry.structure
    if struct then
      for _, fk in ipairs(struct.foreign_keys or {}) do
        local target_raw = fk.target or ''
        local target_schema, target_rel = target_raw:match('^([^.]+)%.(.+)$')
        if not target_rel then
          target_schema = entry.schema or ''
          target_rel = target_raw
        end
        local target_key = table_key(target_schema, target_rel or '')
        if not tables_map[target_key] then
          for k, candidate in pairs(tables_map) do
            if same_ident(candidate.relation, target_rel) then
              target_key = k
              target_schema = candidate.schema
              target_rel = candidate.relation
              break
            end
          end
        end

        if tables_map[target_key] then
          local src_cols = table.concat(fk.columns or {}, ', ')
          local ref_cols = table.concat(fk.referenced or {}, ', ')
          local sig = ('%s(%s)->%s(%s)'):format(key, src_cols:lower(), target_key, ref_cols:lower())
          if not edge_seen[sig] then
            edge_seen[sig] = true
            local nullable = is_nullable_fk(struct, fk.columns)
            local unique = is_unique_fk(struct, fk.columns)
            local parent_card = nullable and '|o' or '||'
            local child_card = unique and '|o' or 'o{'
            table.insert(edges, {
              source_key = key,
              source_schema = entry.schema,
              source_relation = entry.relation,
              target_key = target_key,
              target_schema = tables_map[target_key].schema,
              target_relation = tables_map[target_key].relation,
              columns = fk.columns or {},
              referenced = fk.referenced or {},
              name = fk.name or '',
              connector = parent_card .. '--' .. child_card,
              cardinality_label = (unique and '1:1' or '1:N') .. (nullable and ' (optional)' or ''),
            })
          end
        end
      end
    end
  end

  local mmd_lines = { 'erDiagram' }

  for _, edge in ipairs(edges) do
    local parent_name =
      format_mermaid_entity_name(edge.target_schema, edge.target_relation, multi_schema)
    local child_name =
      format_mermaid_entity_name(edge.source_schema, edge.source_relation, multi_schema)
    local src_cols = table.concat(edge.columns, ', ')
    local ref_cols = table.concat(edge.referenced, ', ')
    local label = src_cols ~= '' and (src_cols .. ' -> ' .. ref_cols)
      or (edge.name ~= '' and edge.name or 'references')
    label = label:gsub('"', "'")
    table.insert(
      mmd_lines,
      ('  %s %s %s : "%s"'):format(parent_name, edge.connector, child_name, label)
    )
  end

  if #edges > 0 then
    table.insert(mmd_lines, '')
  end

  for _, key in ipairs(table_order) do
    local entry = tables_map[key]
    local struct = entry and entry.structure or {}
    local entity_name = format_mermaid_entity_name(entry.schema, entry.relation, multi_schema)
    table.insert(mmd_lines, ('  %s {'):format(entity_name))

    local fk_col_map = {}
    for _, fk in ipairs(struct.foreign_keys or {}) do
      for idx, c in ipairs(fk.columns or {}) do
        local ref_target = fk.target or ''
        local ref_col = (fk.referenced and fk.referenced[idx]) or ''
        fk_col_map[c:lower()] = ref_col ~= '' and (ref_target .. '.' .. ref_col) or ref_target
      end
    end
    local uk_col_map = {}
    for _, idx in ipairs(struct.indexes or {}) do
      if idx.unique and not idx.primary then
        for _, c in ipairs(idx.columns or {}) do
          uk_col_map[c:lower()] = true
        end
      end
    end

    local cols = struct.columns or {}
    if #cols == 0 then
      table.insert(mmd_lines, '    string _no_columns_ "empty"')
    else
      for _, col in ipairs(cols) do
        local mtype = normalize_mermaid_type(col.type_name)
        local mname = normalize_mermaid_ident(col.name)
        local badges = {}
        if col.primary_key then
          table.insert(badges, 'PK')
        end
        local fk_ref = col.references or fk_col_map[(col.name or ''):lower()]
        if fk_ref then
          table.insert(badges, 'FK')
        elseif uk_col_map[(col.name or ''):lower()] and not col.primary_key then
          table.insert(badges, 'UK')
        end
        local badge_str = #badges > 0 and (' ' .. table.concat(badges, ',')) or ''

        local notes = {}
        if not col.nullable and not col.primary_key then
          table.insert(notes, 'NOT NULL')
        end
        if fk_ref then
          table.insert(notes, '-> ' .. tostring(fk_ref))
        end
        local comment_str = #notes > 0 and (' "%s"'):format(table.concat(notes, ' ')) or ''
        table.insert(mmd_lines, ('    %s %s%s%s'):format(mtype, mname, badge_str, comment_str))
      end
    end

    table.insert(mmd_lines, '  }')
  end

  return table.concat(mmd_lines, '\n'), edges
end

--- Assemble an `sqmeow.Erd` result from an ordered list of table entries.
---@param table_entries sqmeow.ErdTable[]
---@param meta table|nil
---@return sqmeow.Erd
function M.format(table_entries, meta)
  meta = meta or {}
  local tables_map = {}
  local table_order = {}
  local tables = {}

  for _, item in ipairs(table_entries or {}) do
    local schema = item.schema or ''
    local relation = item.relation
    if relation and relation ~= '' then
      local key = table_key(schema, relation)
      if not tables_map[key] then
        local entry = {
          schema = schema,
          relation = relation,
          structure = item.structure or { columns = {}, indexes = {}, foreign_keys = {} },
        }
        tables_map[key] = entry
        table.insert(table_order, key)
        table.insert(tables, entry)
      end
    end
  end

  local mermaid, edges = M.build_mermaid(tables_map, table_order)
  return {
    mermaid = mermaid,
    conn_id = meta.conn_id,
    connection = meta.connection,
    dialect = meta.dialect,
    mode = meta.mode or (meta.center_relation and 'neighborhood' or 'schema'),
    schema = meta.schema or '',
    center_schema = meta.center_schema,
    center_relation = meta.center_relation,
    hops = meta.hops,
    tables = tables,
    tables_map = tables_map,
    table_order = table_order,
    edges = edges,
  }
end

--- Handle a `structure:done` engine event.
---@param payload table
function M.on_structure(payload)
  if not payload or not payload.conn_id or not payload.relation then
    return
  end
  local key = ('%d:%s:%s'):format(
    payload.conn_id,
    (payload.schema or ''):lower(),
    payload.relation:lower()
  )
  local cbs = struct_waiters[key]
  if not cbs then
    return
  end
  struct_waiters[key] = nil
  for _, cb in ipairs(cbs) do
    cb(payload)
  end
end

--- Handle a `relationships:done` engine event.
---@param payload table
function M.on_relationships(payload)
  if not payload or not payload.request_id then
    return
  end
  local cb = rel_waiters[payload.request_id]
  if not cb then
    return
  end
  rel_waiters[payload.request_id] = nil
  cb(payload)
end

--- Handle a `schema:nodes` engine event.
---@param payload table
function M.on_nodes(payload)
  if not payload or not payload.conn_id then
    return
  end
  local path_str = table.concat(payload.path or {}, '\0')
  local key = ('%d:%s'):format(payload.conn_id, path_str)
  local cbs = nodes_waiters[key]
  if not cbs then
    return
  end
  nodes_waiters[key] = nil
  for _, cb in ipairs(cbs) do
    cb(payload)
  end
end

--- Fail pending waiters for a closed or lost connection.
---@param conn_id integer
function M.invalidate(conn_id)
  local prefix = ('%d:'):format(conn_id)
  for key, cbs in pairs(struct_waiters) do
    if key:sub(1, #prefix) == prefix then
      struct_waiters[key] = nil
      for _, cb in ipairs(cbs) do
        cb({ conn_id = conn_id, error = 'connection closed' })
      end
    end
  end
  for key, cbs in pairs(nodes_waiters) do
    if key:sub(1, #prefix) == prefix then
      nodes_waiters[key] = nil
      for _, cb in ipairs(cbs) do
        cb({ conn_id = conn_id, nodes = {}, error = 'connection closed' })
      end
    end
  end
end

--- Clear all pending waiters on engine restart.
function M.reset()
  struct_waiters = {}
  rel_waiters = {}
  nodes_waiters = {}
end

local function fetch_structure(conn_id, schema, relation, callback)
  local rpc = require('sqmeow.rpc.client')
  local key = ('%d:%s:%s'):format(conn_id, (schema or ''):lower(), relation:lower())
  struct_waiters[key] = struct_waiters[key] or {}
  table.insert(struct_waiters[key], callback)
  local _, err = rpc.request('structure', {
    conn_id = conn_id,
    schema = schema or '',
    relation = relation,
  })
  if err then
    struct_waiters[key] = nil
    callback({ error = err, conn_id = conn_id, schema = schema, relation = relation })
  end
end

local function fetch_relationships(conn_id, schema, relation, callback)
  local rpc = require('sqmeow.rpc.client')
  local req_id = rpc.next_request_id()
  rel_waiters[req_id] = callback
  local _, err = rpc.request('relationships', {
    conn_id = conn_id,
    schema = schema or '',
    relation = relation,
    request_id = req_id,
  })
  if err then
    rel_waiters[req_id] = nil
    callback({ error = err, conn_id = conn_id, schema = schema, relation = relation })
  end
end

local function fetch_nodes(conn_id, path, callback)
  local drawer = require('sqmeow.ui.drawer')
  local cached = drawer.cached_nodes(conn_id, path)
  if cached then
    return callback({ conn_id = conn_id, path = path, nodes = cached })
  end
  local rpc = require('sqmeow.rpc.client')
  local path_str = table.concat(path or {}, '\0')
  local key = ('%d:%s'):format(conn_id, path_str)
  nodes_waiters[key] = nodes_waiters[key] or {}
  table.insert(nodes_waiters[key], callback)
  local _, err = rpc.request('introspect', {
    conn_id = conn_id,
    path = path or {},
  })
  if err then
    nodes_waiters[key] = nil
    callback({ error = err, nodes = {} })
  end
end

local function collect_structures(meta, table_list, discovered_rels, callback)
  local tables_map = {}
  local table_order = {}
  local pending = 0
  local finished = false

  for _, item in ipairs(table_list) do
    local key = table_key(item.schema, item.relation)
    if not tables_map[key] then
      tables_map[key] = {
        schema = item.schema or '',
        relation = item.relation,
        structure = nil,
      }
      table.insert(table_order, key)
      pending = pending + 1
    end
  end

  if pending == 0 then
    callback(nil, 'no tables found for ERD')
    return
  end

  local function finalize()
    if finished then
      return
    end
    finished = true

    for _, rel in ipairs(discovered_rels or {}) do
      local src_key = table_key(rel.source_schema, rel.source_relation or '')
      local src_entry = tables_map[src_key]
      if src_entry then
        src_entry.structure = src_entry.structure
          or { columns = {}, indexes = {}, foreign_keys = {} }
        src_entry.structure.foreign_keys = src_entry.structure.foreign_keys or {}
        local target_q = (
          rel.target_schema
          and rel.target_schema ~= ''
          and rel.target_schema ~= rel.source_schema
        )
            and (rel.target_schema .. '.' .. rel.target_relation)
          or rel.target_relation
        local exists = false
        for _, fk in ipairs(src_entry.structure.foreign_keys) do
          if same_ident(fk.target, target_q) or same_ident(fk.target, rel.target_relation) then
            if table.concat(fk.columns or {}, ',') == table.concat(rel.columns or {}, ',') then
              exists = true
              break
            end
          end
        end
        if not exists then
          table.insert(src_entry.structure.foreign_keys, {
            name = rel.name or '',
            columns = rel.columns or {},
            target = target_q,
            referenced = rel.referenced or {},
          })
        end
      end
    end

    local ordered_entries = {}
    for _, key in ipairs(table_order) do
      table.insert(ordered_entries, tables_map[key])
    end
    callback(M.format(ordered_entries, meta), nil)
  end

  for _, key in ipairs(table_order) do
    local entry = tables_map[key]
    fetch_structure(meta.conn_id, entry.schema, entry.relation, function(payload)
      if payload and not payload.error then
        entry.structure = payload
        if payload.schema and payload.schema ~= '' then
          entry.schema = payload.schema
        end
      else
        entry.structure = { columns = {}, indexes = {}, foreign_keys = {} }
      end
      pending = pending - 1
      if pending <= 0 then
        finalize()
      end
    end)
  end
end

---@param opts sqmeow.ErdOpts|nil
---@return sqmeow.Connection|nil
---@return string|nil err
local function resolve_connection(opts)
  local state = require('sqmeow.core.state')
  if opts and opts.conn_id then
    local conn = state.connections[opts.conn_id]
    if not conn or conn.state ~= 'connected' then
      return nil, 'ERD generation needs an open connection'
    end
    return conn, nil
  end
  if opts and opts.connection and opts.connection ~= '' then
    local conn = state.connection_by_name(opts.connection)
    if not conn or conn.state ~= 'connected' then
      return nil, ('connection %s is not open'):format(opts.connection)
    end
    return conn, nil
  end
  local conn = require('sqmeow.api.connection').target(0) or state.current_connection()
  if not conn or conn.state ~= 'connected' then
    return nil, 'ERD generation needs an open connection'
  end
  return conn, nil
end

--- Generate an ERD for a table neighborhood, a schema, or an explicit table list.
---@param opts sqmeow.ErdOpts|nil
---@param callback fun(erd: sqmeow.Erd|nil, err: string|nil)|nil
---@return sqmeow.Erd|boolean|nil result
---@return string|nil err
function M.generate(opts, callback)
  opts = opts or {}
  local cb = callback or function() end

  if opts.tables then
    local erd = M.format(opts.tables, {
      conn_id = opts.conn_id,
      connection = opts.connection,
      schema = opts.schema or '',
      center_schema = opts.schema,
      center_relation = opts.relation,
      hops = opts.hops,
      mode = opts.relation and 'neighborhood' or 'schema',
    })
    cb(erd, nil)
    return erd, nil
  end

  local conn, err = resolve_connection(opts)
  if not conn then
    cb(nil, err)
    return false, err
  end
  if conn.dialect == 'redis' or conn.dialect == 'mongodb' then
    local dialect_err = ('ERD is not supported for %s'):format(conn.dialect)
    cb(nil, dialect_err)
    return false, dialect_err
  end

  require('sqmeow.rpc.events').ensure()

  local conn_id = conn.id
  local schema = opts.schema or ''
  local relation = opts.relation

  if relation and relation ~= '' then
    local hops = math.max(1, opts.hops or 1)
    local visited = {}
    local table_list = {}
    local discovered_rels = {}

    local function add_table(s, r)
      local key = table_key(s, r)
      if not visited[key] then
        visited[key] = { schema = s or '', relation = r, rel_fetched = false }
        table.insert(table_list, visited[key])
      end
      return visited[key]
    end

    local root_item = add_table(schema, relation)

    local function expand_hop(remaining, done)
      if remaining <= 0 then
        return done()
      end
      local to_fetch = {}
      for _, item in ipairs(table_list) do
        if not item.rel_fetched then
          item.rel_fetched = true
          table.insert(to_fetch, item)
        end
      end
      if #to_fetch == 0 then
        return done()
      end

      local pending = #to_fetch
      for _, item in ipairs(to_fetch) do
        fetch_relationships(conn_id, item.schema, item.relation, function(payload)
          if payload and not payload.error then
            if payload.resolved_schema and payload.resolved_schema ~= '' then
              item.schema = payload.resolved_schema
            end
            for _, rel in ipairs(payload.relationships or {}) do
              table.insert(discovered_rels, rel)
              if rel.source_relation then
                add_table(rel.source_schema or item.schema, rel.source_relation)
              end
              if rel.target_relation then
                add_table(rel.target_schema or item.schema, rel.target_relation)
              end
            end
          end
          pending = pending - 1
          if pending <= 0 then
            expand_hop(remaining - 1, done)
          end
        end)
      end
    end

    expand_hop(hops, function()
      collect_structures({
        conn_id = conn_id,
        connection = conn.name,
        dialect = conn.dialect,
        mode = 'neighborhood',
        schema = root_item.schema,
        center_schema = root_item.schema,
        center_relation = relation,
        hops = hops,
      }, table_list, discovered_rels, cb)
    end)
    return true, nil
  end

  local function load_schema_tables(target_schema)
    local path = target_schema ~= '' and { target_schema, 'tables' } or { 'tables' }
    fetch_nodes(conn_id, path, function(payload)
      if payload and payload.error then
        return cb(nil, payload.error)
      end
      local table_list = {}
      for _, n in ipairs((payload and payload.nodes) or {}) do
        if n.kind == 'table' or n.kind == 'relation' then
          table.insert(table_list, { schema = target_schema, relation = n.name })
        end
      end
      if #table_list == 0 then
        return cb(
          nil,
          ('no tables found in schema %s'):format(
            target_schema ~= '' and target_schema or 'default'
          )
        )
      end
      collect_structures({
        conn_id = conn_id,
        connection = conn.name,
        dialect = conn.dialect,
        mode = 'schema',
        schema = target_schema,
      }, table_list, nil, cb)
    end)
  end

  if opts.schema ~= nil then
    load_schema_tables(schema)
    return true, nil
  end

  fetch_nodes(conn_id, {}, function(payload)
    if payload and payload.error then
      return cb(nil, payload.error)
    end
    local schemas = {}
    for _, n in ipairs((payload and payload.nodes) or {}) do
      if n.kind == 'schema' then
        table.insert(schemas, n.name)
      end
    end
    if #schemas == 0 then
      return load_schema_tables('')
    elseif #schemas == 1 then
      return load_schema_tables(schemas[1])
    end
    for _, pref in ipairs({ 'public', 'dbo', 'main' }) do
      for _, s in ipairs(schemas) do
        if s:lower() == pref then
          return load_schema_tables(s)
        end
      end
    end
    load_schema_tables(schemas[1])
  end)
  return true, nil
end

return M
