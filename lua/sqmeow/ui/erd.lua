--- The entity-relationship diagram: a read-only drawing of tables and their foreign keys,
--- in a tab of its own. Reads metadata through `sqmeow.core.schema`; never queries rows.

local M = {}

local notify = require('sqmeow.core.utils').notify

local ns = vim.api.nvim_create_namespace('sqmeow.erd')
local ns_focus = vim.api.nvim_create_namespace('sqmeow.erd.focus')

--- What each drawn role is highlighted with.
local groups = {
  border = 'SqmeowErdBorder',
  title = 'SqmeowErdTitle',
  key_name = 'SqmeowErdKey',
  type = 'SqmeowErdType',
  more = 'SqmeowErdMore',
  edge = 'SqmeowErdEdge',
  marker = 'SqmeowErdMarker',
}

--- One drawn schema and what is needed to find things in it.
---@class sqmeow.ErdDrawing
---@field schema sqmeow.Schema
---@field graph sqmeow.ErdGraph
---@field layout sqmeow.ErdLayout
---@field picture sqmeow.ErdPicture
---@field edge_cells table<integer, { [1]: integer, [2]: integer }[]> Cells each edge covers, `{ y, x }`.
---@field edge_at table<integer, table<integer, integer[]>> Edges through each cell, by line and cell.

---@class sqmeow.ErdView
---@field buf integer
---@field win integer
---@field opts sqmeow.SchemaOpts What the drawing shows.
---@field conn_id integer|nil
---@field drawing sqmeow.ErdDrawing|nil Nil while loading the first time, or showing a message.
---@field history { opts: sqmeow.SchemaOpts, detail: sqmeow.ErdDetail|nil }[] Views `back`
--- returns to, with how much each showed.
---@field expanded table<string, boolean> Tables showing every column, by schema and name.
---@field detail sqmeow.ErdDetail|nil Chosen with `C` or `O`; nil follows the table count.
---@field loading boolean
---@field disconnected boolean

---@type sqmeow.ErdView|nil
local view = nil
--- Bumped by every request, so an answer for an older one is dropped.
local token = 0

local function config()
  return require('sqmeow.config').get().ui.erd
end

---@param schema string
---@param relation string
---@return string
local function qualified(schema, relation)
  return schema == '' and relation or (schema .. '.' .. relation)
end

---@param node sqmeow.ErdNode
---@return string
local function node_key(node)
  return node.schema .. '\0' .. node.relation
end

--- How much a table shows: every column (`full`), key columns (`keys`), or only its name
--- (`overview`).
---@alias sqmeow.ErdDetail 'full'|'keys'|'overview'

--- The detail a schema of this size starts at, `overview` left out when `overview` is false.
---@param schema sqmeow.Schema
---@param overview boolean
---@return sqmeow.ErdDetail
local function default_detail(schema, overview)
  local cfg = config()
  local count = #(schema.tables or {})
  if overview and cfg.overview_from > 0 and count >= cfg.overview_from then
    return 'overview'
  end
  if cfg.compact or (cfg.compact_from > 0 and count >= cfg.compact_from) then
    return 'keys'
  end
  return 'full'
end

---@param v sqmeow.ErdView
---@param schema sqmeow.Schema
---@return sqmeow.ErdDetail
local function detail_for(v, schema)
  return v.detail or default_detail(schema, true)
end

--- The highlight a drawn role takes; icons take their kind's, as in the result grid.
---@param role string
---@return string|nil
local function group_of(role)
  if role == 'label' then
    return 'SqmeowErdLabel'
  elseif role == 'cap' then
    return 'SqmeowErdCap'
  end
  local kind = role:match('^icon:(.+)$')
  if kind then
    return require('sqmeow.core.icons').highlights[kind] or 'SqmeowIconTypeUnknown'
  end
  return groups[role]
end

--- `%` is the statusline's escape.
---@param text string
---@return string
local function escape(text)
  return (text:gsub('%%', '%%%%'))
end

--- The view, if its window still shows it.
---@return sqmeow.ErdView|nil
local function shown()
  if
    view
    and vim.api.nvim_win_is_valid(view.win)
    and vim.api.nvim_win_get_buf(view.win) == view.buf
  then
    return view
  end
end

--- The view and its drawing, if both are showing.
---@return sqmeow.ErdView|nil
---@return sqmeow.ErdDrawing|nil
local function drawn()
  local v = shown()
  if v and v.drawing then
    return v, v.drawing
  end
end

--- The cell under the cursor: zero-based line and display column.
---@param v sqmeow.ErdView
---@return integer y
---@return integer x
local function cursor_cell(v)
  local y = vim.api.nvim_win_get_cursor(v.win)[1] - 1
  local x = vim.api.nvim_win_call(v.win, function()
    return vim.fn.virtcol('.', true)[1] - 1
  end)
  return y, x
end

--- The table under the cursor, the column on its row if the row shows one, and the row.
---@param v sqmeow.ErdView
---@param d sqmeow.ErdDrawing
---@return sqmeow.ErdBox|nil box
---@return integer|nil column
---@return integer|nil row Zero for the title.
local function current(v, d)
  local y, x = cursor_cell(v)
  for _, id in ipairs(d.layout.order) do
    local box = d.layout.boxes[id]
    if x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h then
      local row = box.rows[y - box.y]
      return box, row and row.column, y - box.y
    end
  end
end

--- Byte column of a cell, or the line's end for a cell past it.
---@param d sqmeow.ErdDrawing
---@param y integer
---@param x integer
---@return integer
local function byte_of(d, y, x)
  local offsets = d.picture.bytes[y] or {}
  return offsets[x + 1] or offsets[#offsets] or 0
end

--- Put the cursor on a box, scrolled into view.
---@param v sqmeow.ErdView
---@param d sqmeow.ErdDrawing
---@param id integer
---@param row integer|nil Row of the box; its title when nil.
local function show_box(v, d, id, row)
  local box = d.layout.boxes[id]
  if not box then
    return
  end
  local y = box.y + (row or 0)
  local x = box.label and (box.x + vim.api.nvim_strwidth(box.caps.left) + 1)
    or row and (box.x + 2)
    or (box.x + 3)
  vim.api.nvim_win_set_cursor(v.win, { y + 1, byte_of(d, y, x) })
  vim.api.nvim_win_call(v.win, function()
    local height = vim.api.nvim_win_get_height(0)
    local width = vim.api.nvim_win_get_width(0)
    local top = box.h <= height and (box.y - math.floor((height - box.h) / 2)) or box.y
    top = math.max(0, math.min(top, y))
    local left = vim.fn.winsaveview().leftcol
    if box.x < left or box.x + box.w > left + width then
      left = box.w <= width and math.max(0, box.x - math.floor((width - box.w) / 2)) or box.x
    end
    vim.fn.winrestview({ topline = top + 1, leftcol = left })
  end)
end

---@param d sqmeow.ErdDrawing
---@param edge sqmeow.ErdEdge
---@return string
local function describe_edge(d, edge)
  local child, parent = d.graph.nodes[edge.child], d.graph.nodes[edge.parent]
  local names = {}
  for _, index in ipairs(edge.child_columns) do
    table.insert(names, child.columns[index].name)
  end
  local targets = {}
  for _, index in ipairs(edge.parent_columns) do
    table.insert(targets, parent.columns[index].name)
  end
  return ('%s(%s) → %s(%s)%s'):format(
    child.label,
    table.concat(names, ', '),
    parent.label,
    table.concat(targets, ', '),
    edge.name ~= '' and ('  ' .. edge.name) or ''
  )
end

--- The edges through the cell under the cursor.
---@param v sqmeow.ErdView
---@param d sqmeow.ErdDrawing
---@return sqmeow.ErdEdge[]
local function edges_here(v, d)
  local y, x = cursor_cell(v)
  local found = {}
  for _, id in ipairs((d.edge_at[y] or {})[x] or {}) do
    table.insert(found, d.graph.edges[id])
  end
  return found
end

--- What the cursor is on, for the right of the winbar.
---@param v sqmeow.ErdView
---@param d sqmeow.ErdDrawing
---@return string
local function under_cursor(v, d)
  local box, column = current(v, d)
  if box then
    local node = d.graph.nodes[box.node]
    local name = qualified(node.schema, node.relation)
    if not column then
      return ('%s  %d columns'):format(name, #node.columns)
    end
    local info = node.columns[column]
    local text = name .. '.' .. info.name .. '  ' .. info.type
    return info.references and (text .. '  → ' .. info.references) or text
  end
  local edges = edges_here(v, d)
  return edges[1] and describe_edge(d, edges[1]) or ''
end

local function winbar()
  local v = shown()
  if not v then
    return
  end
  local d = v.drawing
  local parts = { '%#SqmeowWinbar# 󰡀 ERD' }
  if d then
    table.insert(parts, ' ' .. escape(d.schema.connection) .. ' › ' .. escape(d.schema.schema))
  end
  local opts = v.opts
  if opts.relation then
    local hops = opts.hops or 1
    table.insert(
      parts,
      (' › %s (%d %s)'):format(escape(opts.relation), hops, hops == 1 and 'hop' or 'hops')
    )
  end
  if d then
    local tables, keys = #d.graph.nodes, #d.graph.edges
    table.insert(
      parts,
      ('%%#Comment#  %d %s · %d %s'):format(
        tables,
        tables == 1 and 'table' or 'tables',
        keys,
        keys == 1 and 'key' or 'keys'
      )
    )
  end
  if v.loading then
    table.insert(parts, '%#Comment#  loading…')
  end
  if v.disconnected then
    table.insert(parts, '%#DiagnosticWarn#  disconnected')
  end
  local right = d and escape(under_cursor(v, d)) or ''
  vim.wo[v.win].winbar = table.concat(parts) .. '%=%#Comment#' .. right .. ' '
end

--- Brighten the table under the cursor and its foreign keys, or the edge under it.
local function focus()
  local v, d = drawn()
  if not (v and d) then
    return
  end
  vim.api.nvim_buf_clear_namespace(v.buf, ns_focus, 0, -1)
  local function paint(y, x1, x2, group)
    vim.api.nvim_buf_set_extmark(v.buf, ns_focus, y, byte_of(d, y, x1), {
      end_col = byte_of(d, y, x2 + 1),
      hl_group = group,
      priority = 200,
    })
  end

  local box = current(v, d)
  local edges = {}
  if box and box.label then
    paint(box.y, box.x, box.x + box.w - 1, 'SqmeowErdFocus')
  elseif box then
    local right = box.x + box.w - 1
    local title_end = box.x + 3 + vim.api.nvim_strwidth(box.title)
    paint(box.y, box.x, box.x + 2, 'SqmeowErdFocus')
    paint(box.y, title_end, right, 'SqmeowErdFocus')
    paint(box.y + box.h - 1, box.x, right, 'SqmeowErdFocus')
    for y = box.y + 1, box.y + box.h - 2 do
      paint(y, box.x, box.x, 'SqmeowErdFocus')
      paint(y, right, right, 'SqmeowErdFocus')
    end
  end
  if box then
    for _, edge in ipairs(d.graph.edges) do
      if edge.child == box.node or edge.parent == box.node then
        table.insert(edges, edge)
      end
    end
  else
    edges = edges_here(v, d)
  end
  for _, edge in ipairs(edges) do
    for _, cell in ipairs(d.edge_cells[edge.id] or {}) do
      paint(cell[1], cell[2], cell[2], 'SqmeowErdEdgeActive')
    end
  end
end

local function refresh_cursor()
  focus()
  winbar()
end

--- Show a message in place of the drawing.
---@param v sqmeow.ErdView
---@param lines string[]
local function message(v, lines)
  v.drawing = nil
  vim.api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(v.buf, ns_focus, 0, -1)
  local indented = { '' }
  for _, line in ipairs(lines) do
    table.insert(indented, '  ' .. line)
  end
  require('sqmeow.ui.buffer').set_lines(v.buf, indented)
  winbar()
end

---@alias sqmeow.ErdPlace { schema: string, relation: string, row: integer|nil }

--- How to read a diagram: `push` keeps the current one for `back`, `keep` is where the cursor
--- stays, and `detail` replaces the chosen detail once the read succeeds (`auto`: the default).
---@class sqmeow.ErdLoad
---@field push boolean|nil
---@field keep sqmeow.ErdPlace|nil
---@field detail sqmeow.ErdDetail|'auto'|nil

--- Draw `schema`, keeping the cursor on `keep` when it is still drawn.
---@param v sqmeow.ErdView
---@param schema sqmeow.Schema
---@param keep sqmeow.ErdPlace|nil
local function draw(v, schema, keep)
  local cfg = config()
  local icons = require('sqmeow.core.icons')
  local graph = require('sqmeow.core.erd.model').graph(schema)
  local expanded = {}
  for _, node in ipairs(graph.nodes) do
    expanded[node.id] = v.expanded[node_key(node)]
  end
  local detail = detail_for(v, schema)
  local glyphs = require('sqmeow.config').get().icons.erd
  local layout = require('sqmeow.core.erd.layout').layout(graph, {
    max_rows = cfg.max_rows,
    max_width = cfg.max_column_width,
    compact = detail == 'keys',
    overview = detail == 'overview',
    caps = { left = glyphs.cap_left, right = glyphs.cap_right },
    dashed = cfg.dashed,
    expanded = expanded,
    icon = function(kind)
      return (icons.get(kind))
    end,
  }, glyphs)
  local picture, canvas = require('sqmeow.core.erd.canvas').draw(layout)

  ---@type sqmeow.ErdDrawing
  local d = {
    schema = schema,
    graph = graph,
    layout = layout,
    picture = picture,
    edge_cells = {},
    edge_at = {},
  }
  for _, edge in ipairs(graph.edges) do
    local cells = canvas.cells['edge:' .. edge.id] or {}
    d.edge_cells[edge.id] = cells
    for _, cell in ipairs(cells) do
      local y, x = cell[1], cell[2]
      d.edge_at[y] = d.edge_at[y] or {}
      d.edge_at[y][x] = d.edge_at[y][x] or {}
      table.insert(d.edge_at[y][x], edge.id)
    end
  end
  v.drawing = d

  require('sqmeow.ui.buffer').set_lines(v.buf, picture.lines)
  vim.api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  for _, span in ipairs(picture.spans) do
    local group = group_of(span.role)
    if group and span.stop > span.start then
      vim.api.nvim_buf_set_extmark(v.buf, ns, span.row, span.start, {
        end_col = span.stop,
        hl_group = group,
      })
    end
  end

  -- The cursor stays on its table, else lands on the focal table, else the first.
  local kept, focal
  for _, node in ipairs(graph.nodes) do
    if keep and node.schema == keep.schema and node.relation == keep.relation then
      kept = node.id
    end
    if v.opts.relation and node.relation == schema.relation then
      focal = focal or node.id
    end
  end
  local target = kept or focal or layout.order[1]
  if target and shown() then
    local row = keep and keep.row
    if row and row > #layout.boxes[target].rows then
      row = nil
    end
    show_box(v, d, target, row)
  end
  refresh_cursor()
end

--- Where the cursor is, to put it back after a redraw.
---@return sqmeow.ErdPlace|nil
local function remember()
  local v, d = drawn()
  if not (v and d) then
    return nil
  end
  local box, _, row = current(v, d)
  if not box then
    return nil
  end
  local node = d.graph.nodes[box.node]
  return { schema = node.schema, relation = node.relation, row = row and row > 0 and row or nil }
end

--- Read and draw `opts`.
---@param v sqmeow.ErdView
---@param opts sqmeow.SchemaOpts
---@param how sqmeow.ErdLoad|nil
---@return boolean started
---@return string|nil err
local function load(v, opts, how)
  how = how or {}
  token = token + 1
  local mine = token
  local early
  local started_reading = false

  local function deliver(schema, err)
    if view ~= v or mine ~= token then
      return
    end
    v.loading = false
    if not schema then
      if v.drawing then
        winbar()
        return notify(('the diagram could not be read: %s'):format(err), vim.log.levels.ERROR)
      end
      return message(v, { 'The diagram could not be read:', err or 'unknown error' })
    end
    local limit = config().max_tables
    if not opts.relation and limit > 0 and #(schema.tables or {}) > limit then
      local text = ('%s has %d tables, more than `ui.erd.max_tables` (%d).'):format(
        schema.schema,
        #schema.tables,
        limit
      )
      if v.drawing then
        winbar()
        return notify(text, vim.log.levels.WARN)
      end
      return message(v, {
        text,
        'Open the diagram from a table in the drawer to see its neighbourhood instead,',
        'or raise the limit.',
      })
    end
    if how.push and v.drawing then
      table.insert(v.history, { opts = v.opts, detail = v.detail })
    end
    local detail = how.detail
    if detail == 'auto' then
      v.detail = nil
    elseif detail then
      v.detail = detail --[[@as sqmeow.ErdDetail]]
    end
    v.opts = opts
    v.conn_id = schema.conn_id
    v.disconnected = false
    draw(v, schema, how.keep)
  end

  -- A read that fails at once answers before `collect` returns; hold that answer until the
  -- request is known to have started.
  local started, err = require('sqmeow.core.schema').collect(opts, function(schema, e)
    if not started_reading then
      early = { schema, e }
      return
    end
    deliver(schema, e)
  end)
  if not started then
    return false, err
  end
  started_reading = true
  v.loading = true
  winbar()
  if early then
    deliver(early[1], early[2])
  end
  return true
end

--- Close the diagram's tab and forget it.
function M.close()
  local closing = view
  if not closing then
    return
  end
  view = nil
  token = token + 1
  if vim.api.nvim_win_is_valid(closing.win) then
    if #vim.api.nvim_list_tabpages() > 1 then
      local tab = vim.api.nvim_win_get_tabpage(closing.win)
      pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tab))
    else
      require('sqmeow.ui.layout').fixbuf(closing.win, false)
      pcall(vim.api.nvim_win_call, closing.win, function()
        vim.cmd.enew()
      end)
    end
  end
  if vim.api.nvim_buf_is_valid(closing.buf) then
    pcall(vim.api.nvim_buf_delete, closing.buf, { force = true })
  end
end

--- Jump along a foreign key from the table or line under the cursor.
---@param toward 'parent'|'child'
local function follow(toward)
  local v, d = drawn()
  if not (v and d) then
    return
  end
  local box, column = current(v, d)
  local choices = {}
  if box then
    local mine = {}
    for _, edge in ipairs(d.graph.edges) do
      if toward == 'parent' and edge.child == box.node then
        table.insert(mine, { edge = edge, columns = edge.child_columns })
      elseif toward == 'child' and edge.parent == box.node then
        table.insert(mine, { edge = edge, columns = edge.parent_columns })
      end
    end
    for _, entry in ipairs(mine) do
      if column == nil or vim.tbl_contains(entry.columns, column) then
        table.insert(choices, entry.edge)
      end
    end
    -- On a column no key uses, `gr` still finds what references the table; `gd` from a
    -- plain column has nothing to follow.
    if #choices == 0 and column and toward == 'child' then
      choices = vim.tbl_map(function(entry)
        return entry.edge
      end, mine)
    end
  else
    choices = edges_here(v, d)
  end

  if #choices == 0 then
    local info = box and column and d.graph.nodes[box.node].columns[column]
    if toward == 'parent' and info and info.references then
      return notify(('%s is not in this diagram'):format(info.references))
    end
    return notify(
      toward == 'parent' and 'no foreign key to follow here' or 'nothing references this here'
    )
  end

  local function go(edge)
    if view ~= v or v.drawing ~= d then
      return
    end
    local target = toward == 'parent' and edge.parent or edge.child
    local columns = toward == 'parent' and edge.parent_columns or edge.child_columns
    local row
    for _, index in ipairs(columns) do
      row = row or d.layout.boxes[target].row_of[index]
    end
    -- Leave a mark that `<C-o>` and ``` `` ``` return to.
    vim.api.nvim_win_call(v.win, function()
      vim.cmd("normal! m'")
    end)
    show_box(v, d, target, row)
    refresh_cursor()
  end
  if #choices == 1 then
    return go(choices[1])
  end
  vim.ui.select(choices, {
    prompt = toward == 'parent' and 'Follow foreign key:' or 'Referenced by:',
    format_item = function(edge)
      return describe_edge(d, edge)
    end,
  }, function(choice)
    if choice then
      go(choice)
    end
  end)
end

--- Move to the table `step` places away in reading order.
---@param step integer
local function cycle(step)
  local v, d = drawn()
  if not (v and d and #d.layout.order > 0) then
    return
  end
  local box = current(v, d)
  local order = d.layout.order
  local index = step > 0 and 0 or 1
  for i, id in ipairs(order) do
    if box and id == box.node then
      index = i
    end
  end
  show_box(v, d, order[(index - 1 + step) % #order + 1])
  refresh_cursor()
end

--- The table under the cursor.
---@return sqmeow.ErdView|nil
---@return sqmeow.ErdNode|nil
local function table_here()
  local v, d = drawn()
  if not (v and d) then
    return nil
  end
  local box = current(v, d)
  if box then
    return v, d.graph.nodes[box.node]
  end
end

---@param v sqmeow.ErdView
---@param opts sqmeow.SchemaOpts
---@param how sqmeow.ErdLoad|nil
---@return boolean started
local function reload(v, opts, how)
  local started, err = load(v, opts, how)
  if not started then
    notify(err or 'the diagram could not be read', vim.log.levels.ERROR)
  end
  return started
end

M.actions = {}

function M.actions.next_table()
  cycle(1)
end

function M.actions.prev_table()
  cycle(-1)
end

function M.actions.goto_parent()
  follow('parent')
end

function M.actions.goto_children()
  follow('child')
end

--- Redraw the diagram around the table under the cursor.
function M.actions.focus()
  local v, node = table_here()
  if not (v and node) then
    return
  end
  reload(v, {
    conn_id = v.conn_id,
    schema = node.schema,
    relation = node.relation,
    hops = v.opts.relation and v.opts.hops or config().hops,
  }, { push = true, keep = { schema = node.schema, relation = node.relation }, detail = 'auto' })
end

function M.actions.back()
  local v = shown()
  if not v or #v.history == 0 then
    return notify('no earlier diagram')
  end
  local previous = table.remove(v.history)
  if not reload(v, previous.opts, { keep = remember(), detail = previous.detail or 'auto' }) then
    table.insert(v.history, previous)
  end
end

---@param delta integer
local function hops(delta)
  local v = shown()
  if not (v and v.opts.relation) then
    return notify('the whole schema is shown; focus a table with <CR> first')
  end
  local now = v.opts.hops or 1
  local next_hops = math.max(0, now + delta)
  if next_hops ~= now then
    reload(v, vim.tbl_extend('force', v.opts, { hops = next_hops }), { keep = remember() })
  end
end

function M.actions.more_hops()
  hops(1)
end

function M.actions.fewer_hops()
  hops(-1)
end

function M.actions.toggle_columns()
  local v, node = table_here()
  if not (v and node and v.drawing) then
    return
  end
  local key = node_key(node)
  v.expanded[key] = not v.expanded[key] or nil
  draw(v, v.drawing.schema, remember())
end

function M.actions.compact()
  local v, d = drawn()
  if not (v and d) then
    return
  end
  v.detail = detail_for(v, d.schema) == 'keys' and 'full' or 'keys'
  draw(v, d.schema, remember())
end

--- Every table of the schema by name only, or back to columns. From a table's neighbourhood,
--- reads the whole schema first.
function M.actions.overview()
  local v, d = drawn()
  if not (v and d) then
    return
  end
  if v.opts.relation then
    reload(
      v,
      { conn_id = v.conn_id, schema = d.schema.schema },
      { push = true, keep = remember(), detail = 'overview' }
    )
    return
  end
  if detail_for(v, d.schema) == 'overview' then
    v.detail = default_detail(d.schema, false)
  else
    v.detail = 'overview'
  end
  draw(v, d.schema, remember())
end

function M.actions.structure()
  local v, node = table_here()
  if v and node then
    require('sqmeow.ui.structure').open(v.conn_id, node.schema, node.relation)
  end
end

function M.actions.relationships()
  local v, node = table_here()
  if v and node then
    require('sqmeow.ui.relationships').open(v.conn_id, node.schema, node.relation)
  end
end

function M.actions.yank_name()
  local v, node = table_here()
  if not (v and node and v.drawing) then
    return
  end
  local parts = node.schema ~= '' and { node.schema, node.relation } or { node.relation }
  local name = require('sqmeow.core.sql').qualify(v.drawing.schema.dialect, parts)
  vim.fn.setreg(vim.v.register or '"', name)
  notify('yanked ' .. name)
end

function M.actions.export()
  local _, d = drawn()
  if d then
    require('sqmeow.api.export').mermaid(d.schema, { clipboard = true })
  end
end

function M.actions.refresh()
  local v = shown()
  if v then
    reload(v, v.opts, { keep = remember() })
  end
end

function M.actions.help()
  require('sqmeow.ui.help').open('erd')
end

M.actions.close = M.close

--- Make the diagram's buffer and tab, or reuse them.
---@return sqmeow.ErdView
local function ensure_window()
  local existing = shown()
  if existing then
    vim.api.nvim_set_current_win(existing.win)
    return existing
  end

  local buf = require('sqmeow.ui.buffer').scratch('sqmeow://erd', 'sqmeow-erd')
  vim.cmd.tabnew()
  local placeholder = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local layout = require('sqmeow.ui.layout')
  layout.set_buffer(win, buf, { release = true })
  if placeholder ~= buf and vim.api.nvim_buf_get_name(placeholder) == '' then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end

  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.colorcolumn = ''
  wo.cursorline = false
  wo.cursorcolumn = false
  wo.list = false
  wo.spell = false
  wo.statuscolumn = ''
  wo.sidescrolloff = 0
  -- The cursor moves over the whole canvas, blank cells included.
  vim.api.nvim_set_option_value('virtualedit', 'all', { scope = 'local', win = win })
  layout.fixbuf(win)

  ---@type sqmeow.ErdView
  local created = {
    buf = buf,
    win = win,
    opts = {},
    history = {},
    expanded = {},
    loading = false,
    disconnected = false,
  }
  view = created

  require('sqmeow.keymap').apply('erd', buf, M.actions)
  local group = vim.api.nvim_create_augroup('sqmeow.erd', { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = buf,
    desc = 'Highlight the table under the cursor',
    callback = refresh_cursor,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    desc = 'Forget the diagram',
    callback = function()
      if view == created then
        view = nil
        token = token + 1
      end
    end,
  })
  return created
end

--- Open the diagram: a whole schema, or a table and its foreign-key neighbours.
---@param opts sqmeow.SchemaOpts|nil
---@return boolean started
---@return string|nil err
function M.open(opts)
  opts = vim.deepcopy(opts or {})
  if (opts.relation or '') == '' then
    opts.relation = nil
    opts.hops = nil
  else
    opts.hops = opts.hops or config().hops
  end
  local fresh = shown() == nil
  local v = ensure_window()
  if fresh then
    require('sqmeow.ui.buffer').set_lines(v.buf, { '', '  Loading the diagram…' })
  end
  local started, err = load(v, opts, { push = true })
  if not started and fresh then
    M.close()
  end
  return started, err
end

--- The diagram's connection closed or the engine went away: keep the drawing, drop pending
--- reads, and say it is out of date.
---@param conn_id integer|nil Every connection when nil.
function M.invalidate(conn_id)
  if view and (conn_id == nil or view.conn_id == conn_id) then
    token = token + 1
    view.loading = false
    view.disconnected = true
    winbar()
  end
end

--- The diagram's buffer, if it is open.
---@return integer|nil
function M.buffer()
  return view and view.buf
end

--- The diagram's state, for tests.
---@return sqmeow.ErdView|nil
function M.state()
  return view
end

return M
