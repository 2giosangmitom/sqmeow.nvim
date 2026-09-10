--- The connection and schema tree.
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

local function valid_win()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function markers()
  if require('sqmeow.config').get().integrations.icons == 'ascii' then
    return { open = 'v', closed = '>', leaf = ' ' }
  end
  return { open = '▾', closed = '▸', leaf = ' ' }
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

local function annotate(node)
  if node.kind ~= 'column' then
    return node.kind == 'schema' and '' or node.kind
  end

  local parts = { node.type_name }
  if node.primary_key then
    table.insert(parts, 'primary key')
  elseif not node.nullable then
    table.insert(parts, 'not null')
  end
  return table.concat(parts, '  ')
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

  local marks = markers()

  for _, node in ipairs(entry.nodes or {}) do
    local child = vim.list_extend(vim.list_slice(path, 1, #path), { node.name })
    local marker = marks.leaf
    if node.expandable then
      marker = M.is_expanded(conn_id, child) and marks.open or marks.closed
    end

    local label = ('%s%s %s'):format(indent, marker, node.name)
    local note = annotate(node)

    table.insert(lines, note == '' and label or ('%s  %s'):format(label, note))
    table.insert(rows, {
      conn_id = conn_id,
      path = child,
      name = node.name,
      kind = node.kind,
      expandable = node.expandable == true,
    })

    if note ~= '' then
      table.insert(highlights, { line = #lines - 1, group = 'SqmeowNull', from = #label, to = -1 })
    end

    if node.expandable and M.is_expanded(conn_id, child) then
      draw(lines, highlights, conn_id, child, depth + 1)
    end
  end
end

--- Redraw the tree.
function M.render()
  if not valid_buf() then
    return
  end

  local state = require('sqmeow.state')
  local marks = markers()
  local lines, highlights = {}, {}
  rows = {}

  for _, connection in ipairs(state.connection_list()) do
    local open = M.is_expanded(connection.id, {})
    local label = ('%s %s'):format(open and marks.open or marks.closed, connection.name)
    local note = connection.dialect or connection.state

    table.insert(lines, ('%s  %s'):format(label, note))
    table.insert(rows, {
      conn_id = connection.id,
      path = {},
      name = connection.name,
      kind = 'connection',
      expandable = true,
    })
    table.insert(highlights, { line = #lines - 1, group = 'SqmeowHeader', from = 0, to = #label })
    table.insert(highlights, { line = #lines - 1, group = 'SqmeowNull', from = #label, to = -1 })

    if open then
      draw(lines, highlights, connection.id, {}, 1)
    end
  end

  if #lines == 0 then
    lines = { 'no connections', '', 'run :Sqmeow connect' }
  end

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

--- Expand or collapse the node under the cursor.
function M.actions.toggle()
  local node = M.current_node()
  if not node or not node.expandable then
    return
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

  M.invalidate(node.conn_id, node.path)
  if M.is_expanded(node.conn_id, node.path) then
    M.load(node.conn_id, node.path)
  end
  M.render()
end

--- Run a `SELECT` over the relation under the cursor.
function M.actions.preview()
  local node = M.current_node()
  if not node or #node.path ~= 2 then
    return
  end

  local api = require('sqmeow.api')
  api.use(node.conn_id)
  api.execute(
    require('sqmeow.sql').select_from(
      dialect_of(node.conn_id),
      node.path,
      require('sqmeow.config').get().ui.result.page_size
    )
  )
end

--- Copy the qualified name of the node under the cursor.
function M.actions.yank_name()
  local node = M.current_node()
  if not node or #node.path == 0 then
    return
  end

  local name = require('sqmeow.sql').qualify(dialect_of(node.conn_id), node.path)
  vim.fn.setreg(vim.v.register or '"', name)
  vim.notify('sqmeow: yanked ' .. name)
end

--- Copy a `SELECT` for the relation under the cursor.
function M.actions.yank_select()
  local node = M.current_node()
  if not node or #node.path ~= 2 then
    return
  end

  local statement = require('sqmeow.sql').select_from(
    dialect_of(node.conn_id),
    node.path,
    require('sqmeow.config').get().ui.result.page_size
  )
  vim.fn.setreg(vim.v.register or '"', statement)
  vim.notify('sqmeow: yanked ' .. statement)
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
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

--- Whether the drawer is showing.
---@return boolean
function M.is_open()
  return valid_win()
end

--- Forget everything. Used when the engine restarts, since its session went with it.
function M.reset()
  expanded = {}
  cache = {}
  rows = {}
  M.render()
end

return M
