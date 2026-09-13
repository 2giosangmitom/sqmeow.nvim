--- The connection and schema tree, and the scratchpads below it.
---
--- Each level is fetched when the user expands it and not before. A database with ten thousand
--- tables would otherwise stall the drawer on open, to fetch names almost none of which are about
--- to be read.
---
--- The tree itself is drawn here rather than in the engine. It is tens of lines, not tens of
--- thousands of rows, so there is nothing to gain by sending it across the channel twice.

local M = {}

local utils = require('sqmeow.utils')

local buf = nil
local win = nil

-- Which nodes the user has opened, and what each one's children turned out to be. Keyed by
-- connection and path, so state survives a redraw and a collapse.
local expanded = {}
local cache = {}

-- The nui tree the drawer was last drawn with, kept so the cursor can be turned into a node.
local tree = nil

local function node_key(conn_id, path)
  return conn_id .. '\0' .. table.concat(path, '\0')
end

--- Read a key back into the connection and path it was built from.
---
---@param key string
---@return integer|nil conn_id Nil for a key that is not a schema node's, such as the scratchpads.
---@return string[] path
local function key_parts(key)
  local parts = vim.split(key, '\0', { plain = true })
  local conn_id = tonumber(table.remove(parts, 1))
  -- An empty path leaves one empty trailing piece behind, which is not a path element.
  if #parts == 1 and parts[1] == '' then
    parts = {}
  end
  return conn_id, parts
end

--- Whether a key names something at or under a path.
---
--- The separator has to be there exactly once. A key for a path of no elements — a whole
--- connection — already ends in one, so appending another matches nothing, and refreshing a
--- connection would quietly reload none of the levels under it.
local function under(key, prefix)
  if key == prefix then
    return true
  end
  local boundary = prefix:sub(-1) == '\0' and prefix or (prefix .. '\0')
  return key:sub(1, #boundary) == boundary
end

--- Whether the tree currently shows this node's children.
---@param conn_id integer
---@param path string[]
---@return boolean
function M.is_expanded(conn_id, path)
  return expanded[node_key(conn_id, path)] == true
end

--- Ask the engine for one level of the tree.
---
---@param conn_id integer
---@param path string[]
function M.load(conn_id, path)
  local key = node_key(conn_id, path)
  local entry = cache[key]
  if entry and entry.loading then
    return
  end

  -- What is already drawn is kept while the reply is on its way, so reloading a level someone is
  -- looking at renews it in place rather than emptying it and filling it back in.
  cache[key] = { loading = true, nodes = entry and entry.nodes }
  local _, err = require('sqmeow.rpc').request('introspect', { conn_id = conn_id, path = path })
  if err then
    cache[key] = { error = err }
    M.render()
  end
end

--- Take one level of the tree from the engine.
---
---@param payload table
function M.on_nodes(payload)
  cache[node_key(payload.conn_id, payload.path or {})] = {
    nodes = payload.nodes or {},
    error = payload.error,
  }
  M.render()
end

--- Forget what is cached below a node, so the next expansion reads it again.
---
---@param conn_id integer
---@param path string[]
function M.invalidate(conn_id, path)
  local prefix = node_key(conn_id, path)
  for cached in pairs(cache) do
    if under(cached, prefix) then
      cache[cached] = nil
    end
  end
end

--- Kinds whose name says nothing the row above it has not already said.
---
--- A table sits under `Tables` and a function under `Functions`, so repeating the kind on every
--- row is noise. What survives is the kind a group does not imply: a materialised view among the
--- views, or a foreign table among the tables.
local implied = {
  database = true,
  schema = true,
  table = true,
  view = true,
  ['function'] = true,
  procedure = true,
  key = true,
}

local function annotate(node)
  -- A group heading carries how many things it holds, which is the whole reason to draw one
  -- before it is opened.
  if node.count then
    return ('(%d)'):format(node.count)
  end

  if node.kind ~= 'column' then
    return implied[node.kind] and '' or node.kind
  end

  -- A key says so in two letters beside its type, the same way the row detail does.
  local key = node.primary_key and ' (PK)' or node.references and ' (FK)' or ''
  local parts = { node.type_name .. key }
  if not node.primary_key and not node.nullable then
    table.insert(parts, 'not null')
  end
  return table.concat(parts, '  ')
end

--- The nui.nvim components the drawer is built from.
local function nui()
  return utils.nui({ 'tree', 'line', 'text' }, 'the drawer')
end

--- Turn one node into the line the drawer draws for it.
---
--- Each piece gets its own highlight on purpose. A marker says whether a row is open, a badge says
--- something about the thing itself, an icon says what the row holds, and colouring them apart is
--- most of what makes a tree readable without reading it.
---
--- Built as a `NuiLine` rather than as a string with byte offsets worked out beside it, which is
--- what this used to be: the offsets had to be recomputed whenever a piece changed width, and a
--- multi-byte glyph made every one of them a measurement rather than a length.
local function prepare_node(node)
  local parts = assert(nui())
  local icons = require('sqmeow.icons')
  local line = parts.Line()

  line:append(('  '):rep(node:get_depth() - 1))

  -- A row the tree could not fill in: still loading, or an error where children should be.
  if node.placeholder then
    line:append(parts.Text(node.placeholder, node.placeholder_group))
    return line
  end

  local marks = icons.markers()
  local marker = marks.leaf
  -- A connection carries a marker whether or not it can be opened yet: pressing the same key on a
  -- closed one connects it, so a leaf's blank marker would say it is a dead end when it is not.
  if node.expandable or node.show_marker then
    marker = node:is_expanded() and marks.open or marks.closed
  end
  -- A leaf's marker is a space, and a highlight over nothing is one more thing for the editor to
  -- keep track of on every row of a long tree.
  if marker:match('%S') then
    line:append(parts.Text(marker, 'SqmeowMarker'))
  else
    line:append(marker)
  end
  line:append(' ')

  -- A badge sits between the marker and the icon: the marker says whether the row is open, the
  -- badge says something about the thing itself, and the icon says what kind of thing it is.
  if node.badge then
    local text, group = icons.get(node.badge)
    line:append(parts.Text(text, group))
    line:append(' ')
  end

  local icon, icon_group = icons.get(node.icon_kind or node.kind)
  line:append(parts.Text(icon, icon_group))
  line:append(' ')
  line:append(node.name)

  if node.note and node.note ~= '' then
    line:append('  ')
    line:append(parts.Text(node.note, 'SqmeowNull'))
  end

  return line
end

--- The nodes one level of the schema tree contributes.
---
---@param conn_id integer
---@param path string[]
---@return table[]
local function schema_nodes(conn_id, path)
  local parts = assert(nui())
  local icons = require('sqmeow.icons')
  local entry = cache[node_key(conn_id, path)]
  if not entry then
    return {}
  end

  local id = ('node:%d:%s'):format(conn_id, table.concat(path, '/'))

  if entry.loading and not entry.nodes then
    return { parts.Tree.Node({ id = id .. ':loading', placeholder = '…' }) }
  end
  if entry.error then
    return {
      parts.Tree.Node({
        id = id .. ':error',
        placeholder = entry.error,
        placeholder_group = 'SqmeowError',
      }),
    }
  end

  local nodes = {}
  for _, node in ipairs(entry.nodes or {}) do
    -- The engine's own word for the node, which for a group heading is not what is drawn:
    -- `Tables` is a label, `tables` is what the engine matches on.
    local child = vim.list_extend(vim.list_slice(path, 1, #path), { node.key or node.name })
    local expandable = node.expandable == true
    local open = expandable and M.is_expanded(conn_id, child)

    local children = nil
    if open and node.kind == 'database' then
      -- One database of a cluster is a connection of its own, opened when it was expanded, and
      -- what it holds is that connection's tree.
      local opened = require('sqmeow.state').child_connection(conn_id, node.name)
      if opened and opened.state == 'connected' then
        -- A MongoDB database is its own only schema, so a schema row would repeat the database's
        -- name one level down. Its groups are drawn in that row's place.
        children = schema_nodes(opened.id, opened.dialect == 'mongodb' and { node.name } or {})
      elseif opened then
        children = {
          parts.Tree.Node({
            id = ('node:%d:%s:loading'):format(conn_id, table.concat(child, '/')),
            placeholder = '…',
          }),
        }
      end
    elseif open then
      children = schema_nodes(conn_id, child)
    end

    local built = parts.Tree.Node({
      id = ('node:%d:%s'):format(conn_id, table.concat(child, '/')),
      conn_id = conn_id,
      path = child,
      name = node.name,
      kind = node.kind,
      icon_kind = node.kind == 'column' and icons.column_kind(node) or nil,
      note = annotate(node),
      -- Only a group heading has one, so it doubles as how an action tells a heading apart from
      -- something the database actually holds.
      count = node.count,
      expandable = expandable,
    }, children)

    if open then
      built:expand()
    end
    table.insert(nodes, built)
  end

  return nodes
end

-- The scratchpad section is keyed on this rather than a connection id, because a scratchpad
-- belongs to the plugin's data directory and outlives whatever connection it was written for.
local SCRATCHPADS = 'scratchpads'

--- The saved scratchpads, under a heading of their own.
---
--- Below the connections, because the tree is about databases first. Reopening yesterday's query
--- is something a user can see rather than something they have to remember exists.
local function scratchpad_node()
  local parts = assert(nui())
  local pads = require('sqmeow.ui.editor').list()
  local open = expanded[SCRATCHPADS] == true

  local children = {}
  for index, pad in ipairs(pads) do
    children[index] = parts.Tree.Node({
      -- By path, since two connections can each have a scratchpad of the same name.
      id = 'pad:' .. pad.path,
      kind = 'scratchpad',
      name = pad.name,
      -- The connection folder it is in, so `report` for one database reads apart from another's.
      note = pad.folder,
      file = pad.path,
      expandable = false,
    })
  end

  local node = parts.Tree.Node({
    id = SCRATCHPADS,
    kind = 'scratchpads',
    name = 'scratchpads',
    note = #pads == 0 and 'none saved' or tostring(#pads),
    expandable = true,
  }, children)

  if open then
    node:expand()
  end
  return node
end

-- Keyed on this for the same reason as the scratchpads: the log belongs to the plugin rather than
-- to any one connection, and it outlives every connection in the tree.
local HISTORY = 'history'

--- How many queries the drawer offers before the section becomes a wall of text.
local HISTORY_SHOWN = 20

--- What has been run, under a heading of its own.
local function history_node()
  local parts = assert(nui())
  local log = require('sqmeow.ui.log')
  local entries = log.entries({ limit = HISTORY_SHOWN })
  local open = expanded[HISTORY] == true

  local children = {}
  for index, entry in ipairs(entries) do
    -- One line, however it was written. A statement spread over six lines would otherwise take
    -- six rows of the tree and say no more than its first clause does.
    local statement = (entry.statement:gsub('%s+', ' '):gsub('^%s', ''))
    children[index] = parts.Tree.Node({
      id = ('query:%d'):format(index),
      kind = 'query',
      name = statement,
      note = log.ago(entry.at),
      entry = entry,
      expandable = false,
    })
  end

  local node = parts.Tree.Node({
    id = HISTORY,
    kind = 'history',
    name = 'history',
    note = #entries == 0 and 'nothing yet' or tostring(#entries),
    expandable = true,
  }, children)

  if open then
    node:expand()
  end
  return node
end

--- Every connection the drawer draws.
---
--- The open ones, and then the saved ones that are not open. A database client lists what you can
--- connect to, not only what you have connected to, and the dot beside each says which is which.
---
--- Read on every draw rather than remembered, so a connection saved in another Neovim, or written
--- straight into the file, is there without anyone asking for a refresh.
---
---@return table[]
function M.connection_rows()
  local state = require('sqmeow.state')
  local drawn = {}
  local open = {}

  for _, connection in ipairs(state.connection_list()) do
    -- One database of a cluster is drawn inside the cluster, not beside it.
    if not connection.parent then
      open[connection.name] = true
      table.insert(drawn, {
        id = connection.id,
        name = connection.name,
        dialect = connection.dialect,
        note = connection.state,
        status = connection.state,
        connected = connection.state == 'connected',
      })
    end
  end

  for _, spec in ipairs((require('sqmeow.sources').load())) do
    if not open[spec.name] then
      table.insert(drawn, {
        name = spec.name,
        url = spec.url,
        dialect = require('sqmeow.dialects').of_url(spec.url),
        note = 'saved',
        status = state.failures[spec.name] and 'error' or 'disconnected',
        connected = false,
      })
    end
  end

  return drawn
end

--- Redraw the tree.
function M.render()
  if not (buf and utils.buf_valid(buf)) then
    return
  end

  local parts, err = nui()
  if not parts then
    return utils.notify(err, vim.log.levels.ERROR)
  end

  local icons = require('sqmeow.icons')
  local nodes = {}

  for _, connection in ipairs(M.connection_rows()) do
    local open = connection.id ~= nil and M.is_expanded(connection.id, {})

    local node = parts.Tree.Node({
      id = 'conn:' .. tostring(connection.id or connection.name),
      conn_id = connection.id,
      path = {},
      name = connection.name,
      kind = 'connection',
      icon_kind = icons.connection_kind(connection.dialect),
      badge = connection.status,
      -- A connection on its way, or one that failed, says so in words beside the dot.
      note = (connection.status == 'connecting' or connection.status == 'error')
          and connection.status
        or connection.dialect
        or connection.note,
      url = connection.url,
      -- A connection nobody has opened has nothing to show yet. Pressing the same key opens it,
      -- and then it does, which is why the marker is drawn either way.
      expandable = connection.connected,
      show_marker = true,
    }, open and schema_nodes(connection.id, {}) or nil)

    if open then
      node:expand()
    end
    table.insert(nodes, node)
  end

  if #nodes == 0 then
    table.insert(
      nodes,
      parts.Tree.Node({ id = 'empty', placeholder = 'no connections, run :Sqmeow add' })
    )
  end

  table.insert(nodes, scratchpad_node())
  table.insert(nodes, history_node())

  -- One tree for the life of the buffer, fed new nodes rather than rebuilt. A fresh tree does not
  -- know which lines the last one occupied, so rendering it writes a second copy underneath the
  -- first instead of replacing it.
  if not (tree and tree.bufnr == buf) then
    tree = parts.Tree({
      bufnr = buf,
      -- The same namespace the drawer has always marked in, so anything looking for its highlights
      -- still finds them under that name rather than under one nui invented.
      ns_id = 'sqmeow.drawer',
      prepare_node = prepare_node,
      -- The id exactly as it was set, rather than nui's default of prefixing it: these are looked
      -- up by name from elsewhere, and a lookup that has to know about a prefix is one that breaks
      -- when the prefix changes.
      get_node_id = function(node)
        return node.id
      end,
    })
  end

  tree:set_nodes(nodes)

  vim.bo[buf].modifiable = true
  tree:render()
  vim.bo[buf].modifiable = false
end

--- The node the cursor is on, if it is on one.
---
--- Asked of the tree by line rather than of the window it is showing in, so an action fired from
--- somewhere else still reads the drawer's own cursor.
---
---@return table|nil
function M.current_node()
  if not (win and tree and utils.shows(win, buf)) then
    return nil
  end

  local node = tree:get_node(vim.api.nvim_win_get_cursor(win)[1])
  -- A placeholder is a line the tree could not fill in, not something to act on.
  if not node or node.placeholder then
    return nil
  end
  return node
end

local function dialect_of(conn_id)
  local connection = require('sqmeow.state').connections[conn_id]
  return connection and connection.dialect or nil
end

--- The connection opened for the database row under the cursor, if it is open.
local function opened_database(node)
  return require('sqmeow.state').child_connection(node.conn_id, node.name)
end

--- Expand or collapse one database of a cluster, opening a connection for it the first time.
---
--- A PostgreSQL connection reads one database only, so each database a cluster lists is opened as
--- a connection of its own, named after both. Queries, previews and scratchpads under it then run
--- there, with nothing else having to know it came from a cluster.
local function toggle_database(node)
  local key = node_key(node.conn_id, node.path)
  if opened_database(node) then
    expanded[key] = not expanded[key] or nil
    return M.render()
  end

  local parent = require('sqmeow.state').connections[node.conn_id]
  expanded[key] = true
  local id = require('sqmeow.api').connect(parent.url, {
    name = ('%s/%s'):format(parent.name, node.name),
    parent = parent.id,
    database = node.name,
  })
  -- Marked open, the way a connection someone expanded is, so a refresh reloads what it holds.
  if id then
    expanded[node_key(id, {})] = true
    -- The level drawn in place of a MongoDB database's schema row, open for the same reason.
    if parent.dialect == 'mongodb' then
      expanded[node_key(id, { node.name })] = true
    end
  end
  M.render()
end

--- Actions the drawer's keys are bound to.
M.actions = {}

--- The parts of a node's path that name something in SQL.
---
--- The tree has a level the database does not: a relation sits under `Tables`, which is a heading
--- rather than something anything is named after. Dropping it is what keeps a yanked name
--- `"public"."users"` instead of `"public"."tables"."users"`.
---
---@param path string[]
---@return string[]
local function sql_parts(path)
  if #path < 2 then
    return path
  end
  return vim.list_extend({ path[1] }, vim.list_slice(path, 3, #path))
end

--- Whether a node is something a `SELECT` can name, or a Redis key that can be read the same way.
local function is_relation(kind)
  return kind == 'table'
    or kind == 'view'
    or kind == 'materialized view'
    or kind == 'relation'
    or kind == 'key'
end

--- The statement that shows what a relation holds.
---
--- For a Redis key that depends on its type, which is the group the key sits under.
local function preview_statement(node)
  local sql = require('sqmeow.sql')
  local dialect = dialect_of(node.conn_id)
  local limit = require('sqmeow.config').get().ui.result.page_size
  if dialect == 'redis' then
    return sql.read_key(node.path[2], node.path[#node.path], limit)
  end
  return sql.select_from(dialect, sql_parts(node.path), limit)
end

--- Open the node under the cursor.
---
--- One key, because what opening means depends on the thing rather than on the user: a branch
--- expands, a scratchpad opens its file, a past query goes back on screen, and a connection that
--- is closed is opened so that there is something to expand.
function M.actions.toggle()
  local node = M.current_node()
  if not node then
    return
  end

  if node.kind == 'scratchpad' then
    return require('sqmeow.ui.editor').open_path(node.file)
  end
  if node.kind == 'query' then
    return require('sqmeow.ui.log').reopen(node.entry)
  end

  -- This key opens things and nothing else. Choosing which database queries run on is `use`, on a
  -- key of its own, so neither can happen by accident while doing the other.
  if node.kind == 'connection' and not node.conn_id then
    return require('sqmeow.api').connect_named(node.name)
  end

  if not node.expandable then
    return
  end

  if node.kind == 'scratchpads' then
    expanded[SCRATCHPADS] = not expanded[SCRATCHPADS] or nil
    return M.render()
  end
  if node.kind == 'history' then
    expanded[HISTORY] = not expanded[HISTORY] or nil
    return M.render()
  end
  if node.kind == 'database' then
    return toggle_database(node)
  end

  local id = node_key(node.conn_id, node.path)
  if expanded[id] then
    expanded[id] = nil
  else
    expanded[id] = true
    if not cache[id] then
      M.load(node.conn_id, node.path)
    end
  end
  M.render()
end

--- Drop and reload everything at or under one level of one connection's tree.
---
---@param conn_id integer
---@param path string[]
local function reload(conn_id, path)
  local prefix = node_key(conn_id, path)

  -- Everything at or under the node is dropped, so everything at or under it has to be asked for
  -- again. Reloading only the node itself would leave every level someone has open below it with
  -- no cache entry and nothing on its way, which draws as a level that has quietly lost its
  -- children rather than as one being refreshed.
  M.invalidate(conn_id, path)

  local levels = {}
  for key, open in pairs(expanded) do
    if open == true and under(key, prefix) then
      table.insert(levels, key)
    end
  end
  -- Shallowest first, so a level arrives before the levels drawn inside it.
  table.sort(levels, function(left, right)
    return #left < #right
  end)

  for _, key in ipairs(levels) do
    local owner, level = key_parts(key)
    if owner then
      M.load(owner, level)
    end
  end

  -- A row is drawn from the level above it, so the count on `Tables (3)` belongs to the schema's
  -- children and not to the tables themselves. Reloading only what sits under the node would
  -- leave that number saying what it said before the refresh.
  if #path > 0 then
    M.load(conn_id, vim.list_slice(path, 1, #path - 1))
  end

  -- The relation picker searches a list the engine holds for the whole connection, and a refresh
  -- that renewed the tree but not that list would have the two disagreeing about what exists.
  if #path == 0 then
    require('sqmeow.rpc').request('catalog', { conn_id = conn_id, refresh = true })
  end
end

--- Reload the node under the cursor.
function M.actions.refresh()
  local node = M.current_node()
  if not node then
    return
  end
  -- Scratchpads are read from the directory on every draw, so redrawing is the whole refresh.
  if not node.conn_id then
    return M.render()
  end
  -- A database of a cluster is refreshed as the connection it was opened as.
  if node.kind == 'database' then
    local opened = opened_database(node)
    if not opened then
      return
    end
    node = { conn_id = opened.id, path = {} }
  end

  local path = node.path or {}
  reload(node.conn_id, path)

  -- The databases opened from a server are connections of their own, drawn inside this one, so
  -- their trees are cached under their own ids and a refresh of the server has to reach them too.
  if #path == 0 then
    for _, connection in pairs(require('sqmeow.state').connections) do
      if connection.parent == node.conn_id then
        reload(connection.id, {})
      end
    end
  end
  M.render()
end

--- Run a `SELECT` over the relation under the cursor.
function M.actions.preview()
  local node = M.current_node()
  if not node or not is_relation(node.kind) then
    return
  end

  -- Nil for a Redis key of a type nothing reads back.
  local statement = preview_statement(node)
  if not statement then
    return
  end

  local api = require('sqmeow.api')
  api.use(node.conn_id)
  api.execute(
    statement,
    -- Written by the plugin, not by anyone at the keyboard, so it stays out of the query log.
    { history = false }
  )
end

--- Copy the qualified name of the node under the cursor.
function M.actions.yank_name()
  local node = M.current_node()
  -- A group heading names nothing, so there is nothing to copy from one.
  if not node or not node.path or #node.path == 0 or node.count then
    return
  end

  local name = require('sqmeow.sql').qualify(dialect_of(node.conn_id), sql_parts(node.path))
  vim.fn.setreg(vim.v.register or '"', name)
  utils.notify('yanked ' .. name)
end

--- Copy a `SELECT` for the relation under the cursor.
function M.actions.yank_select()
  local node = M.current_node()
  if not node or not is_relation(node.kind) then
    return
  end

  local statement = preview_statement(node)
  if not statement then
    return
  end
  vim.fn.setreg(vim.v.register or '"', statement)
  utils.notify('yanked ' .. statement)
end

--- Rename the connection or the scratchpad under the cursor.
---
--- The current name is offered as the default, so the prompt is somewhere to edit rather than
--- somewhere to retype, and leaving it alone changes nothing.
function M.actions.rename()
  local node = M.current_node()
  if node and node.kind == 'connection' then
    return vim.ui.input({ prompt = 'Call it: ', default = node.name }, function(name)
      if not name or name == '' or name == node.name then
        return
      end
      -- A connection that was saved under the old name is renamed with it, since a user who
      -- renames what they are looking at meant the connection, not this session's copy of it.
      if require('sqmeow.sources').find(node.name) then
        require('sqmeow.api').edit(node.name, { name = name })
        return
      end
      require('sqmeow.api').rename(node.conn_id, name)
    end)
  end

  if not node or node.kind ~= 'scratchpad' then
    return
  end

  vim.ui.input({ prompt = 'Rename the scratchpad to: ', default = node.name }, function(name)
    if not name or name == '' or name == node.name then
      return
    end

    local renamed, err = require('sqmeow.ui.editor').rename(node.file, name)
    if not renamed then
      return utils.notify(err or 'the scratchpad could not be renamed', vim.log.levels.ERROR)
    end

    utils.notify(('renamed %s to %s'):format(node.name, vim.fn.fnamemodify(renamed, ':t:r')))
    M.render()
  end)
end

--- Run queries against the connection under the cursor.
---
--- The only thing that changes the active connection from the drawer. Expanding a connection to
--- read its schemas is a different intention from sending the next query to it, so it is a
--- different key.
function M.actions.use()
  local node = M.current_node()
  if node and node.kind == 'database' then
    local opened = opened_database(node)
    node = { kind = 'connection', name = node.name, conn_id = opened and opened.id }
  end
  if not node or node.kind ~= 'connection' then
    return
  end
  if not node.conn_id then
    return utils.notify(('`%s` is not open yet'):format(node.name), vim.log.levels.WARN)
  end

  local connection = require('sqmeow.api').use(node.conn_id)
  if connection then
    utils.notify(('queries now run on %s'):format(connection.name))
  end
end

--- Add a connection.
---
--- The same dialog `:Sqmeow add` opens, put on a key because the drawer is where a person is
--- looking when they notice the connection they want is not there.
function M.actions.add()
  require('sqmeow.ui.connection').create()
end

--- Create a scratchpad for the connection under the cursor.
---
--- Anywhere inside a connection counts, so a user reading a table does not have to climb back up
--- to the connection's own row first. The name is asked for, and nothing is created if none is
--- given.
function M.actions.new_scratchpad()
  local node = M.current_node()
  local name = node and node.kind == 'connection' and node.name or nil
  if node and node.kind == 'database' then
    local opened = opened_database(node)
    name = opened and opened.name
  elseif node and not name and node.conn_id then
    local connection = require('sqmeow.state').connections[node.conn_id]
    name = connection and connection.name
  end

  if not name then
    return utils.notify(
      'put the cursor on a connection to create a scratchpad for it',
      vim.log.levels.WARN
    )
  end
  require('sqmeow.api').scratchpad(name)
end

--- Edit the connection under the cursor.
---
--- Everything about it, unlike `rename`, which is the quick version of the same thing.
function M.actions.edit()
  local node = M.current_node()
  if not node or node.kind ~= 'connection' then
    return
  end

  local spec = require('sqmeow.sources').find(node.name)
  if not spec then
    return utils.notify(
      ('`%s` is open but not saved, so there is nothing to edit'):format(node.name),
      vim.log.levels.WARN
    )
  end

  if not require('sqmeow.ui.connection').edit(spec) then
    utils.notify(
      ('`%s` holds a url the form cannot take apart'):format(node.name),
      vim.log.levels.WARN
    )
  end
end

--- Delete the scratchpad under the cursor, or empty the query log.
---
--- Asked first, because a scratchpad is a file the user wrote and deleting one cannot be undone.
--- `no` is the first choice, so a `<CR>` meant for something else does nothing.
function M.actions.delete()
  local node = M.current_node()
  if node and (node.kind == 'history' or node.kind == 'query') then
    return vim.ui.select(
      { 'no', 'yes' },
      { prompt = 'Forget every query in the log?' },
      function(answer)
        if answer ~= 'yes' then
          return
        end
        require('sqmeow.history').clear()
        utils.notify('the query log is empty')
        M.render()
      end
    )
  end

  if not node or node.kind ~= 'scratchpad' then
    return
  end

  vim.ui.select({ 'no', 'yes' }, {
    prompt = ('Delete the scratchpad `%s`?'):format(node.name),
  }, function(answer)
    if answer ~= 'yes' then
      return
    end

    local removed, err = require('sqmeow.ui.editor').remove(node.file)
    if not removed then
      return utils.notify(err or 'the scratchpad could not be deleted', vim.log.levels.ERROR)
    end

    utils.notify('deleted the scratchpad ' .. node.name)
    M.render()
  end)
end

--- Open the history section and put the cursor on it.
---
--- What `:Sqmeow log` does, so the command lands somewhere useful rather than only drawing the
--- tree and leaving the section shut.
function M.reveal_history()
  expanded[HISTORY] = true
  M.render()

  -- Asked of the tree by node id rather than by walking lines: the tree knows where it put the
  -- heading, and the id is fixed whatever else the drawer happens to be showing.
  if not tree then
    return
  end
  local _, linenr = tree:get_node(HISTORY)
  if linenr then
    pcall(vim.api.nvim_win_set_cursor, M.open(), { linenr, 0 })
  end
end

--- Show the drawer's mappings.
function M.actions.help()
  require('sqmeow.ui.help').open('drawer')
end

--- Close the drawer.
function M.actions.close()
  M.close()
end

--- The drawer buffer, created on first use.
---@return integer
function M.buffer()
  if buf and utils.buf_valid(buf) then
    return buf
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'sqmeow://drawer')

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'sqmeow-drawer'
  vim.bo[buf].modifiable = false

  require('sqmeow.keymap').apply('drawer', buf, M.actions)
  return buf
end

--- Show the drawer.
---@return integer win
function M.open()
  if win and utils.shows(win, buf) then
    return win
  end

  local config = require('sqmeow.config').get().ui.drawer
  -- Whichever surface opens first records the layout, and whichever closes last puts it back.
  require('sqmeow.ui.layout').remember()
  local previous = vim.api.nvim_get_current_win()

  vim.cmd(('topleft vertical %dsplit'):format(config.width))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M.buffer())

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  -- Another split must not squash the tree into unreadable width.
  vim.wo[win].winfixwidth = true

  M.render()
  vim.api.nvim_set_current_win(previous)
  return win
end

--- Hide the drawer, keeping what it has loaded.
function M.close()
  if win and utils.shows(win, buf) then
    require('sqmeow.ui.layout').close_window(win)
  end
  win = nil
  require('sqmeow.ui.layout').restore()
end

--- Whether the drawer is showing.
---@return boolean
function M.is_open()
  return utils.shows(win, buf)
end

--- Forget everything. Used when the engine restarts, since its session went with it.
function M.reset()
  -- The scratchpad section is kept open if it was: those are the plugin's own files, and the
  -- engine restarting says nothing about them.
  local pads = expanded[SCRATCHPADS]

  expanded = { [SCRATCHPADS] = pads }
  cache = {}
  tree = nil
  M.render()
end

return M
