--- The connection and schema tree, and the scratchpads below it.
---
--- Each level is fetched when the user expands it and not before. A database with ten thousand
--- tables would otherwise stall the drawer on open, to fetch names almost none of which are about
--- to be read.
---
--- The tree itself is drawn here rather than in the engine. It is tens of lines, not tens of
--- thousands of rows, so there is nothing to gain by sending it across the channel twice.

local M = {}

local namespace = vim.api.nvim_create_namespace('sqmeow.drawer')

local buf = nil
local win = nil

-- Which nodes the user has opened, and what each one's children turned out to be. Keyed by
-- connection and path, so state survives a redraw and a collapse.
local expanded = {}
local cache = {}

-- Line number to the node drawn on it, rebuilt on every render.
local rows = {}

local function node_key(conn_id, path)
  return conn_id .. '\0' .. table.concat(path, '\0')
end

local function valid_buf()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Whether the drawer window is still the drawer window.
---
--- A valid handle is not enough: something else can take a window over, and the tree would then
--- be drawn into a buffer nobody is looking at. Treating that as closed means the next `:Sqmeow
--- toggle` opens a sidebar rather than fighting over one.
local function valid_win()
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and valid_buf()
    and vim.api.nvim_win_get_buf(win) == buf
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
  local entry = cache[node_key(conn_id, path)]
  if entry and entry.loading then
    return
  end

  cache[node_key(conn_id, path)] = { loading = true }
  local _, err = require('sqmeow.rpc').request('introspect', { conn_id = conn_id, path = path })
  if err then
    cache[node_key(conn_id, path)] = { error = err }
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
    if cached == prefix or cached:sub(1, #prefix + 1) == prefix .. '\0' then
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
  schema = true,
  table = true,
  view = true,
  ['function'] = true,
  procedure = true,
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

  local parts = { node.type_name }
  if node.primary_key then
    table.insert(parts, 'primary key')
  elseif not node.nullable then
    table.insert(parts, 'not null')
  end
  return table.concat(parts, '  ')
end

--- Add one row, with its marker and its icon coloured apart from the text.
---
--- The three spans get different groups on purpose. A marker says whether a row is open, an icon
--- says what the row holds, and colouring them is most of what makes a tree readable without
--- reading it. Every marker shares `SqmeowMarker`, since none of them names a kind of thing.
---
---@return string # The label, so a caller can measure where its own trailing note begins.
local function emit(lines, highlights, node)
  local icon, icon_group = require('sqmeow.icons').get(node.kind)
  local indent = node.indent or ''
  local prefix = ('%s%s '):format(indent, node.marker)
  local label = ('%s%s %s'):format(prefix, icon, node.name)

  local note = node.note or ''
  table.insert(lines, note == '' and label or ('%s  %s'):format(label, note))
  table.insert(rows, node.row)

  local line = #lines - 1
  -- A leaf's marker is blank by default, and an extmark over nothing is one more thing for the
  -- editor to keep track of on every row of a long tree.
  if node.marker:match('%S') then
    table.insert(highlights, {
      line = line,
      group = 'SqmeowMarker',
      from = #indent,
      to = #indent + #node.marker,
    })
  end
  table.insert(
    highlights,
    { line = line, group = icon_group, from = #prefix, to = #prefix + #icon }
  )
  if note ~= '' then
    table.insert(highlights, { line = line, group = 'SqmeowNull', from = #label, to = -1 })
  end

  return label
end

local function draw(lines, highlights, conn_id, path, depth)
  local entry = cache[node_key(conn_id, path)]
  if not entry then
    return
  end

  local indent = ('  '):rep(depth)

  if entry.loading then
    table.insert(lines, indent .. '…')
    table.insert(rows, false)
    return
  end
  if entry.error then
    table.insert(lines, indent .. entry.error)
    table.insert(rows, false)
    table.insert(highlights, { line = #lines - 1, group = 'SqmeowError', from = 0, to = -1 })
    return
  end

  local marks = require('sqmeow.icons').markers()

  for _, node in ipairs(entry.nodes or {}) do
    -- The engine's own word for the node, which for a group heading is not what is drawn:
    -- `Tables` is a label, `tables` is what the engine matches on.
    local child = vim.list_extend(vim.list_slice(path, 1, #path), { node.key or node.name })
    local marker = marks.leaf
    if node.expandable then
      marker = M.is_expanded(conn_id, child) and marks.open or marks.closed
    end

    emit(lines, highlights, {
      indent = indent,
      marker = marker,
      kind = node.kind,
      name = node.name,
      note = annotate(node),
      row = {
        conn_id = conn_id,
        path = child,
        name = node.name,
        kind = node.kind,
        -- Only a group heading has one, so it doubles as how an action tells a heading apart
        -- from something the database actually holds.
        count = node.count,
        expandable = node.expandable == true,
      },
    })

    if node.expandable and M.is_expanded(conn_id, child) then
      draw(lines, highlights, conn_id, child, depth + 1)
    end
  end
end

-- The scratchpad section is keyed on this rather than a connection id, because a scratchpad
-- belongs to the plugin's data directory and outlives whatever connection it was written for.
local SCRATCHPADS = 'scratchpads'

--- Draw the saved scratchpads under a heading of their own.
---
--- Below the connections, because the tree is about databases first. They are here rather than
--- only in a picker so that reopening yesterday's query is something a user can see, not something
--- they have to remember exists.
local function draw_scratchpads(lines, highlights, marks)
  local pads = require('sqmeow.ui.editor').list()
  local open = expanded[SCRATCHPADS] == true

  emit(lines, highlights, {
    marker = open and marks.open or marks.closed,
    kind = 'scratchpads',
    name = 'scratchpads',
    note = #pads == 0 and 'none saved' or tostring(#pads),
    row = { kind = 'scratchpads', name = 'scratchpads', expandable = true },
  })
  if not open then
    return
  end

  for _, pad in ipairs(pads) do
    emit(lines, highlights, {
      indent = '  ',
      marker = marks.leaf,
      kind = 'scratchpad',
      name = pad.name,
      row = { kind = 'scratchpad', name = pad.name, file = pad.path, expandable = false },
    })
  end
end

--- Redraw the tree.
function M.render()
  if not valid_buf() then
    return
  end

  local state = require('sqmeow.state')
  local marks = require('sqmeow.icons').markers()
  local lines, highlights = {}, {}
  rows = {}

  for _, connection in ipairs(state.connection_list()) do
    local open = M.is_expanded(connection.id, {})
    emit(lines, highlights, {
      marker = open and marks.open or marks.closed,
      kind = require('sqmeow.icons').connection_kind(connection.dialect),
      name = connection.name,
      note = connection.dialect or connection.state,
      row = {
        conn_id = connection.id,
        path = {},
        name = connection.name,
        kind = 'connection',
        expandable = true,
      },
    })

    if open then
      draw(lines, highlights, connection.id, {}, 1)
    end
  end

  if #lines == 0 then
    table.insert(lines, 'no connections, run :Sqmeow connect')
    table.insert(rows, false)
  end

  draw_scratchpads(lines, highlights, marks)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.from, {
      end_col = highlight.to == -1 and #lines[highlight.line + 1] or highlight.to,
      hl_group = highlight.group,
    })
  end
end

--- The node the cursor is on, if it is on one.
---@return table|nil
function M.current_node()
  if not valid_win() then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local node = rows[line]
  return node or nil
end

local function dialect_of(conn_id)
  local connection = require('sqmeow.state').connections[conn_id]
  return connection and connection.dialect or nil
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

--- Whether a node is something a `SELECT` can name.
local function is_relation(kind)
  return kind == 'table' or kind == 'view' or kind == 'materialized view' or kind == 'relation'
end

--- Act on the node under the cursor.
---
--- One key, because what the primary action is depends on the thing rather than on the user: a
--- branch opens, and a scratchpad, which is a leaf holding a file, opens the file.
function M.actions.toggle()
  local node = M.current_node()
  if not node then
    return
  end

  if node.kind == 'scratchpad' then
    return require('sqmeow.ui.editor').open_path(node.file)
  end
  if not node.expandable then
    return
  end

  if node.kind == 'scratchpads' then
    expanded[SCRATCHPADS] = not expanded[SCRATCHPADS] or nil
    return M.render()
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

  M.invalidate(node.conn_id, node.path)
  if M.is_expanded(node.conn_id, node.path) then
    M.load(node.conn_id, node.path)
  end
  M.render()
end

--- Run a `SELECT` over the relation under the cursor.
function M.actions.preview()
  local node = M.current_node()
  if not node or not is_relation(node.kind) then
    return
  end

  local api = require('sqmeow.api')
  api.use(node.conn_id)
  api.execute(
    require('sqmeow.sql').select_from(
      dialect_of(node.conn_id),
      sql_parts(node.path),
      require('sqmeow.config').get().ui.result.page_size
    )
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
  vim.notify('sqmeow: yanked ' .. name)
end

--- Copy a `SELECT` for the relation under the cursor.
function M.actions.yank_select()
  local node = M.current_node()
  if not node or not is_relation(node.kind) then
    return
  end

  local statement = require('sqmeow.sql').select_from(
    dialect_of(node.conn_id),
    sql_parts(node.path),
    require('sqmeow.config').get().ui.result.page_size
  )
  vim.fn.setreg(vim.v.register or '"', statement)
  vim.notify('sqmeow: yanked ' .. statement)
end

--- Find a relation, narrowed to the schema the cursor is in.
---
--- Standing on a schema means the search is about that schema, and standing anywhere else means
--- it is about the whole connection. That is what makes one key useful at every level of the tree.
function M.actions.find()
  local node = M.current_node()
  if node and node.kind == 'scratchpad' or node and node.kind == 'scratchpads' then
    return require('sqmeow.pickers').scratchpads()
  end

  if node and node.conn_id then
    require('sqmeow.api').use(node.conn_id)
  end

  require('sqmeow.pickers').relations({
    schema = node and node.path and #node.path >= 1 and node.path[1] or nil,
  })
end

--- Rename the connection or the scratchpad under the cursor.
---
--- The current name is offered as the default, so the prompt is somewhere to edit rather than
--- somewhere to retype, and leaving it alone changes nothing.
function M.actions.rename()
  local node = M.current_node()
  if node and node.kind ~= 'scratchpad' and node.conn_id and #node.path == 0 then
    return vim.ui.input({ prompt = 'Call it: ', default = node.name }, function(name)
      if not name or name == '' or name == node.name then
        return
      end
      -- A connection that was saved under the old name is renamed with it, since a user who
      -- renames what they are looking at meant the connection, not this session's copy of it.
      if require('sqmeow.sources').find(node.name) then
        return require('sqmeow.api').edit(node.name, { name = name })
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
      return vim.notify('sqmeow: ' .. err, vim.log.levels.ERROR)
    end

    vim.notify(('sqmeow: renamed %s to %s'):format(node.name, vim.fn.fnamemodify(renamed, ':t:r')))
    M.render()
  end)
end

--- Add a connection.
---
--- The same dialog `:Sqmeow add` opens, put on a key because the drawer is where a person is
--- looking when they notice the connection they want is not there.
function M.actions.add()
  require('sqmeow.ui.connection').create()
end

--- Edit the connection under the cursor.
---
--- Everything about it, unlike `rename`, which is the quick version of the same thing.
function M.actions.edit()
  local node = M.current_node()
  if not node or node.kind == 'scratchpad' or not node.conn_id or #node.path > 0 then
    return
  end

  local spec = require('sqmeow.sources').find(node.name)
  if not spec then
    return vim.notify(
      ('sqmeow: `%s` is open but not saved, so there is nothing to edit'):format(node.name),
      vim.log.levels.WARN
    )
  end

  if not require('sqmeow.ui.connection').edit(spec) then
    vim.notify(
      ('sqmeow: `%s` holds a url the form cannot take apart'):format(node.name),
      vim.log.levels.WARN
    )
  end
end

--- Delete the scratchpad under the cursor.
---
--- Asked first, because a scratchpad is a file the user wrote and deleting one cannot be undone.
--- `no` is the first choice, so a `<CR>` meant for something else does nothing.
function M.actions.delete()
  local node = M.current_node()
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
      return vim.notify('sqmeow: ' .. err, vim.log.levels.ERROR)
    end

    vim.notify('sqmeow: deleted the scratchpad ' .. node.name)
    M.render()
  end)
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
  if valid_buf() then
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
  if valid_win() then
    return win
  end

  local config = require('sqmeow.config').get().ui.drawer
  -- Whichever surface opens first records the layout, and whichever closes last puts it back.
  require('sqmeow.ui.layout').remember()
  local previous = vim.api.nvim_get_current_win()

  vim.cmd(
    ('%s vertical %dsplit'):format(
      config.position == 'right' and 'botright' or 'topleft',
      config.width
    )
  )
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
  if valid_win() then
    require('sqmeow.ui.layout').close_window(win)
  end
  win = nil
  require('sqmeow.ui.layout').restore()
end

--- Whether the drawer is showing.
---@return boolean
function M.is_open()
  return valid_win()
end

--- Forget everything. Used when the engine restarts, since its session went with it.
function M.reset()
  -- The scratchpad section is kept open if it was: those are the plugin's own files, and the
  -- engine restarting says nothing about them.
  local pads = expanded[SCRATCHPADS]

  expanded = { [SCRATCHPADS] = pads }
  cache = {}
  rows = {}
  M.render()
end

return M
