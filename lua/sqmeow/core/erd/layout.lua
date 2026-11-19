--- Place an ERD's tables and route its foreign keys on a character grid. Pure: no editor state.
---
--- A layered drawing, as Graphviz `dot` and ELK draw graphs, tuned to fill the space:
---
--- - Columns: tables joined by a key sit in different columns, ideally next to each other.
---   Direction is the crow's feet's to show, so a table may sit either side of one it
---   references, and a hub's tables fill the columns both sides of it. A local search moves
---   tables to keep lines short and every column near the height that makes the drawing about
---   three cells wide per row.
--- - Order: barycenter sweeps keep crossings down.
--- - Rows: each table moves toward the rows its neighbours attach at, so lines run straight,
---   but no column grows past the fullest one.
--- - Lines: orthogonal, bundled by the column they reference: one trunk per bundle in each gap
---   between columns, one row through each column a bundle crosses. Trunks share a gap's
---   column when their spans never meet, as wires do in channel routing.
--- - Groups: each connected group is laid out on its own; groups and tables without keys are
---   packed in columns beside the biggest.

local M = {}

local strwidth = vim.api.nvim_strwidth

--- Each UTF-8 character of `text`.
---@param text string
---@return string[]
local function chars(text)
  local found = {}
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    table.insert(found, char)
  end
  return found
end

--- `text` cut to `width` display cells, ending in `…` when it was cut.
---@param text string
---@param width integer
---@return string
function M.fit(text, width)
  if strwidth(text) <= width then
    return text
  end
  if width <= 0 then
    return ''
  end
  local kept, used = {}, 0
  for _, char in ipairs(chars(text)) do
    local w = strwidth(char)
    if used + w > width - 1 then
      break
    end
    table.insert(kept, char)
    used = used + w
  end
  return table.concat(kept) .. '…'
end

---@class sqmeow.ErdLayoutOpts
---@field max_rows integer|nil Columns shown before the rest fold away, counted in the bottom
--- border; 0 shows all.
---@field max_width integer|nil Widest a column name or type is drawn.
---@field compact boolean|nil Show only key columns.
---@field dashed boolean|nil Draw non-identifying foreign keys dashed, as Mermaid does.
---@field expanded table<integer, boolean>|nil Node ids whose columns all show, whatever the limits.
---@field icon fun(kind: string): string Glyph for `primary_key`, `foreign_key`, a type class,
--- or `table`.
---@field overview boolean|nil Draw each table as a one-line label with no columns.
---@field caps { left: string, right: string }|nil Ends of an overview label.
---@field loops table<integer, boolean>|nil Set by `layout`: tables referencing themselves.

---@class sqmeow.ErdPiece
---@field text string
---@field role string What the text is: `icon:<kind>`, `name`, `key_name`, `type`, `more`.

---@class sqmeow.ErdRow
---@field column integer|nil Index into the node's columns; nil for a summary row.
---@field pieces sqmeow.ErdPiece[] Text left to right, starting after the left border's padding.

---@class sqmeow.ErdBox
---@field node integer
---@field x integer Left border, zero-based.
---@field y integer Top border, zero-based.
---@field w integer Including both borders.
---@field h integer Including both borders.
---@field title string
---@field rows sqmeow.ErdRow[] Row `r` is drawn on line `y + r`.
---@field row_of table<integer, integer> Column index to row.
---@field hidden integer Columns folded away.
---@field footer string|nil Drawn in the bottom border: how many columns are folded away.
---@field label boolean|nil A one-line overview label: `y` is its only line, and edges meet its ends.
---@field caps { left: string, right: string }|nil An overview label's ends.

--- The icon a column is drawn with: its key, else what it holds, as the result grid does.
---@param column sqmeow.ErdColumn
---@return string kind
local function icon_kind(column)
  if column.pk then
    return 'primary_key'
  end
  if column.fk then
    return 'foreign_key'
  end
  return column.class or 'unknown'
end

--- Lay out a box's rows: which columns show, and how each is spelled.
---@param node sqmeow.ErdNode
---@param anchored table<integer, boolean> Columns an edge attaches to; they always show.
---@param opts sqmeow.ErdLayoutOpts
---@return sqmeow.ErdBox
local function measure(node, anchored, opts)
  if opts.overview and not (opts.expanded and opts.expanded[node.id]) then
    local caps = opts.caps or { left = '', right = '' }
    local icon = opts.icon('table')
    local title = M.fit(node.label, math.max(opts.max_width or 32, 12) * 2)
    -- A table referencing itself says so rather than drawing a loop around one line.
    if opts.loops and opts.loops[node.id] then
      title = title .. ' ↻'
    end
    title = (icon ~= ' ' and icon ~= '' and (icon .. ' ') or '') .. title
    return {
      node = node.id,
      x = 0,
      y = 0,
      w = strwidth(caps.left) + strwidth(title) + 2 + strwidth(caps.right),
      h = 1,
      title = title,
      rows = {},
      row_of = {},
      hidden = #node.columns,
      label = true,
      caps = caps,
    }
  end
  local max_width = opts.max_width or 32
  local max_rows = opts.max_rows or 0
  local everything = opts.expanded and opts.expanded[node.id]

  local keep = {}
  local kept = 0
  for index, column in ipairs(node.columns) do
    if column.pk or column.fk or anchored[index] then
      keep[index] = true
      kept = kept + 1
    end
  end
  if everything or (not opts.compact and (max_rows <= 0 or #node.columns <= max_rows)) then
    for index in ipairs(node.columns) do
      keep[index] = true
    end
  elseif not opts.compact then
    -- Fill up to the limit in table order, after the key columns that must show.
    local budget = max_rows - kept
    for index in ipairs(node.columns) do
      if budget <= 0 then
        break
      end
      if not keep[index] then
        keep[index] = true
        budget = budget - 1
      end
    end
  end

  local shown = {}
  local name_width, type_width, icon_width = 0, 0, 0
  for index, column in ipairs(node.columns) do
    if keep[index] then
      local kind = icon_kind(column)
      local icon = opts.icon(kind)
      local name = M.fit(column.name, max_width)
      local type = M.fit(column.type, max_width)
      table.insert(
        shown,
        { index = index, column = column, name = name, type = type, icon = icon, kind = kind }
      )
      name_width = math.max(name_width, strwidth(name))
      type_width = math.max(type_width, strwidth(type))
      icon_width = math.max(icon_width, strwidth(icon))
    end
  end

  local rows, row_of = {}, {}
  for _, entry in ipairs(shown) do
    table.insert(rows, {
      column = entry.index,
      pieces = {
        {
          text = entry.icon .. (' '):rep(icon_width - strwidth(entry.icon)),
          role = 'icon:' .. entry.kind,
        },
        { text = ' ', role = 'name' },
        {
          text = entry.name .. (' '):rep(name_width - strwidth(entry.name)),
          role = entry.column.pk and 'key_name' or 'name',
        },
        { text = '  ', role = 'name' },
        { text = entry.type .. (' '):rep(type_width - strwidth(entry.type)), role = 'type' },
      },
    })
    row_of[entry.index] = #rows
  end

  -- Folded columns are counted in the bottom border, which costs no row; a box with no row
  -- to show keeps the count as its row.
  local hidden = #node.columns - #shown
  local footer
  if hidden > 0 and #rows > 0 then
    footer = ('… %d more'):format(hidden)
  elseif hidden > 0 then
    table.insert(rows, {
      pieces = { { text = ('… %d more'):format(hidden), role = 'more' } },
    })
  elseif #node.columns == 0 then
    table.insert(rows, { pieces = { { text = '(no columns)', role = 'more' } } })
  end

  local title = M.fit(node.label, math.max(max_width, 12) * 2)
  -- `│ ` + content + ` │`, and room for `╭─ title ─╮`.
  local inner = 0
  for _, row in ipairs(rows) do
    local width = 0
    for _, piece in ipairs(row.pieces) do
      width = width + strwidth(piece.text)
    end
    inner = math.max(inner, width)
  end
  local w = math.max(inner + 4, strwidth(title) + 6, footer and (strwidth(footer) + 6) or 0)

  return {
    node = node.id,
    x = 0,
    y = 0,
    w = w,
    h = #rows + 2,
    title = title,
    footer = footer,
    rows = rows,
    row_of = row_of,
    hidden = hidden,
  }
end

--- Where an edge attaches to a box: the row of its first key column that shows, else the
--- first row.
---@param box sqmeow.ErdBox
---@param columns integer[]
---@return integer row
local function anchor_row(box, columns)
  if box.label then
    return 0
  end
  for _, index in ipairs(columns) do
    if box.row_of[index] then
      return box.row_of[index]
    end
  end
  return 1
end

---@class sqmeow.ErdItem
---@field box sqmeow.ErdBox|nil A table, or nil for a bundle's slot through a layer.
---@field layer integer
---@field order number
---@field y integer
---@field h integer

---@class sqmeow.ErdSegment
---@field edge sqmeow.ErdEdge
---@field left sqmeow.ErdItem
---@field right sqmeow.ErdItem
---@field left_row integer Offset from the item's top: its anchor row, or 0 for a slot.
---@field right_row integer
---@field bundle string The referenced table and row the edge belongs to.

--- Connected groups of nodes, by the edges between distinct nodes, in first-seen order.
---@param graph sqmeow.ErdGraph
---@return integer[][]
local function components(graph)
  local parent = {}
  local function root(id)
    while parent[id] ~= id do
      parent[id] = parent[parent[id]]
      id = parent[id]
    end
    return id
  end
  for _, node in ipairs(graph.nodes) do
    parent[node.id] = node.id
  end
  for _, edge in ipairs(graph.edges) do
    if edge.child ~= edge.parent then
      local a, b = root(edge.child), root(edge.parent)
      if a ~= b then
        parent[math.max(a, b)] = math.min(a, b)
      end
    end
  end
  local groups, by_root = {}, {}
  for _, node in ipairs(graph.nodes) do
    local r = root(node.id)
    if not by_root[r] then
      by_root[r] = {}
      table.insert(groups, by_root[r])
    end
    table.insert(by_root[r], node.id)
  end
  return groups
end

--- Starting columns, parents before children, with cycles broken where a depth-first walk
--- meets a node it is still inside. `optimize` improves on them.
---@param ids integer[]
---@param edges sqmeow.ErdEdge[] Edges within the group, self-references excluded.
---@return table<integer, integer> ranks Zero-based layer of each node.
---@return table<integer, integer[]> children Each node's children over the acyclic edges.
local function rank(ids, edges)
  local out = {}
  for _, id in ipairs(ids) do
    out[id] = {}
  end
  for _, edge in ipairs(edges) do
    table.insert(out[edge.parent], edge.child)
  end

  -- A depth-first walk; an edge back into the walk's own path is dropped for ranking.
  local state, order, dag = {}, {}, {}
  for _, id in ipairs(ids) do
    dag[id] = {}
  end
  local function visit(id)
    state[id] = 'open'
    for _, next_id in ipairs(out[id]) do
      if state[next_id] == nil then
        table.insert(dag[id], next_id)
        visit(next_id)
      elseif state[next_id] == 'done' then
        table.insert(dag[id], next_id)
      end
    end
    state[id] = 'done'
    table.insert(order, 1, id)
  end
  -- Start from tables nothing points at, so a chain reads left to right.
  local incoming = {}
  for _, edge in ipairs(edges) do
    incoming[edge.child] = true
  end
  for _, id in ipairs(ids) do
    if not incoming[id] and state[id] == nil then
      visit(id)
    end
  end
  for _, id in ipairs(ids) do
    if state[id] == nil then
      visit(id)
    end
  end

  -- Longest path from a source, over the acyclic edges, in topological order.
  local ranks = {}
  for _, id in ipairs(order) do
    ranks[id] = ranks[id] or 0
    for _, next_id in ipairs(dag[id]) do
      ranks[next_id] = math.max(ranks[next_id] or 0, ranks[id] + 1)
    end
  end
  return ranks, dag
end

--- Improve the columns tables sit in. Direction is the crow's feet's to show, not left and
--- right, so a table may sit on either side of one it references: a hub's tables can fill the
--- columns both sides of it, every line one gap long. A local search moves one table at a
--- time to the column that lowers, in rows of drawing, the lines' extra length (each gap a
--- line crosses beyond its first costs a row and its spacing) plus how far columns run past
--- the height that makes the drawing about three cells wide per row, as a terminal is.
--- Tables joined by a key never share a column. Empty columns are closed up.
---@param ids integer[]
---@param edges sqmeow.ErdEdge[] Edges within the group, self-references excluded.
---@param ranks table<integer, integer> Starting columns; changed in place.
---@param boxes table<integer, sqmeow.ErdBox>
local function optimize(ids, edges, ranks, boxes)
  local neighbours = {}
  for _, id in ipairs(ids) do
    neighbours[id] = {}
  end
  for _, edge in ipairs(edges) do
    table.insert(neighbours[edge.parent], edge.child)
    table.insert(neighbours[edge.child], edge.parent)
  end

  local total, widths, tallest = 0, 0, 0
  local weight = {}
  for _, id in ipairs(ids) do
    weight[id] = boxes[id].h + 1
    total = total + weight[id]
    widths = widths + boxes[id].w
    tallest = math.max(tallest, weight[id])
  end
  -- A column is about a box and a gap wide.
  local column = widths / #ids + 14
  local wanted = math.max(2, math.ceil(math.sqrt(3 * total / column)))
  local limit = math.max(tallest, math.ceil(total / wanted))

  local load = {}
  for _, id in ipairs(ids) do
    load[ranks[id]] = (load[ranks[id]] or 0) + weight[id]
  end
  local function over(amount)
    return math.max(0, amount - limit)
  end
  local function stretch(id, r)
    local extra = 0
    for _, other in ipairs(neighbours[id]) do
      extra = extra + math.max(0, math.abs(r - ranks[other]) - 1)
    end
    return 2 * extra
  end

  -- Leaves first: they move most freely and relieve the most.
  local order = vim.list_slice(ids)
  table.sort(order, function(a, b)
    if #neighbours[a] ~= #neighbours[b] then
      return #neighbours[a] < #neighbours[b]
    end
    return a < b
  end)
  for _ = 1, 12 do
    local moved = false
    for _, id in ipairs(order) do
      local taken, low, high = {}, math.huge, -math.huge
      for _, other in ipairs(neighbours[id]) do
        taken[ranks[other]] = true
        low, high = math.min(low, ranks[other]), math.max(high, ranks[other])
      end
      local here, w = ranks[id], weight[id]
      local base = stretch(id, here)
      local best, best_gain = here, 0
      -- A few columns past the neighbours: a long line can still beat a column overflowing.
      for r = low - 3, high + 3 do
        if r ~= here and not taken[r] then
          local gain = base
            - stretch(id, r)
            + over(load[here])
            + over(load[r] or 0)
            - over(load[here] - w)
            - over((load[r] or 0) + w)
          if gain > best_gain then
            best, best_gain = r, gain
          end
        end
      end
      if best ~= here then
        load[here] = load[here] - w
        load[best] = (load[best] or 0) + w
        ranks[id] = best
        moved = true
      end
    end
    if not moved then
      break
    end
  end

  -- Close up empty columns; a line across one only gets shorter.
  local used = {}
  for _, id in ipairs(ids) do
    used[ranks[id]] = true
  end
  local sorted = vim.tbl_keys(used)
  table.sort(sorted)
  local renumber = {}
  for index, r in ipairs(sorted) do
    renumber[r] = index - 1
  end
  for _, id in ipairs(ids) do
    ranks[id] = renumber[ranks[id]]
  end
end

--- Crossings between the links of one gap, given each item's position in its layer.
---@param links sqmeow.ErdSegment[]
---@return integer
local function crossings(links)
  local count = 0
  for i = 1, #links do
    local a = links[i]
    for j = i + 1, #links do
      local b = links[j]
      if (a.left.order - b.left.order) * (a.right.order - b.right.order) < 0 then
        count = count + 1
      end
    end
  end
  return count
end

--- Positions as close to `wishes` as the order and spacing allow, in the least-squares
--- sense: pool-adjacent-violators over each item's offset from a tight stack. Nothing goes
--- above row 0 or below `height`: a sparse layer spreads to line up with its neighbours, but
--- never makes the drawing taller than its fullest layer already does.
---@param list sqmeow.ErdItem[] In order, top to bottom.
---@param wishes table<sqmeow.ErdItem, { target: number, weight: number }>
---@param gap integer
---@param height integer
local function settle(list, wishes, gap, height)
  local blocks = {}
  local offset = 0
  for index, item in ipairs(list) do
    local wish = wishes[item]
    local target = (wish and wish.target or item.y) - offset
    local weight = wish and wish.weight or 0.01
    table.insert(blocks, { weight = weight, sum = weight * target, first = index, last = index })
    while #blocks > 1 do
      local top, below = blocks[#blocks], blocks[#blocks - 1]
      if below.sum / below.weight < top.sum / top.weight then
        break
      end
      below.weight = below.weight + top.weight
      below.sum = below.sum + top.sum
      below.last = top.last
      table.remove(blocks)
    end
    item.order = index
    item.y = offset
    offset = offset + item.h + gap
  end
  -- Clamping each block keeps the order: every offset shares the same bounds.
  local room = math.max(0, height - (offset - gap))
  for _, block in ipairs(blocks) do
    local shift = math.min(room, math.max(0, math.floor(block.sum / block.weight + 0.5)))
    for index = block.first, block.last do
      list[index].y = list[index].y + shift
    end
  end
end

--- One bundle's vertical line in a gap.
---@class sqmeow.ErdTrunk
---@field lefts table<integer, boolean> Rows it leaves the left side of the gap at.
---@field rights table<integer, boolean> Rows it reaches the right side at.
---@field low integer
---@field high integer
---@field drop integer How far down its lines go in all; negative for up.
---@field down boolean|nil
---@field key number|nil Where it leaves, on average.
---@field track integer|nil
---@field column integer|nil One-based column of its gap, shared with trunks it never meets.
---@field turn integer|nil Row a split trunk steps sideways at, onto `rest`.
---@field rest sqmeow.ErdTrunk|nil The part of a split trunk after its turn.

---@class sqmeow.ErdMarker
---@field x integer
---@field y integer
---@field text string
---@field edge integer
---@field weight integer How loose the end is: 3 many, 2 zero, 1 one. Where ends share a cell,
--- the loosest shows.

---@class sqmeow.ErdRoute
---@field edge sqmeow.ErdEdge
---@field points { [1]: integer, [2]: integer }[][] Polylines, each a list of `{ x, y }` corners.
---@field dotted boolean

---@class sqmeow.ErdAttach
---@field x integer
---@field y integer
---@field edge integer
---@field side 'left'|'right' The side of the border cell the edge arrives from.

--- What one group draws, at its own origin until it is placed.
---@class sqmeow.ErdPart
---@field w integer
---@field h integer
---@field boxes sqmeow.ErdBox[]
---@field routes sqmeow.ErdRoute[]
---@field markers sqmeow.ErdMarker[]
---@field attach sqmeow.ErdAttach[]

---@class sqmeow.ErdLayout
---@field width integer
---@field height integer
---@field boxes table<integer, sqmeow.ErdBox> By node id.
---@field order integer[] Node ids in reading order: layer by layer, each top to bottom.
---@field routes sqmeow.ErdRoute[]
---@field markers sqmeow.ErdMarker[]
---@field attach sqmeow.ErdAttach[]

---@alias sqmeow.ErdGlyphs { one: string, zero: string, many: string, many_reversed: string }

--- Glyphs for an edge's end, outside in: the cell farther from the box, then the nearer one.
---@param edge sqmeow.ErdEdge
---@param parent boolean
---@param box_on_left boolean
---@param glyphs sqmeow.ErdGlyphs
---@return string far
---@return string near
local function end_glyphs(edge, parent, box_on_left, glyphs)
  if parent then
    return edge.optional and glyphs.zero or glyphs.one, glyphs.one
  end
  if edge.unique then
    return glyphs.zero, glyphs.one
  end
  return glyphs.zero, box_on_left and glyphs.many_reversed or glyphs.many
end

--- How loose an end glyph is, so ends sharing a cell show the loosest.
---@param text string
---@param glyphs sqmeow.ErdGlyphs
---@return integer
local function looseness(text, glyphs)
  if text == glyphs.many or text == glyphs.many_reversed then
    return 3
  end
  return text == glyphs.zero and 2 or 1
end

--- Collects what a group draws.
---@param glyphs sqmeow.ErdGlyphs
---@param dashed boolean
---@return sqmeow.ErdPart part
---@return fun(edge: sqmeow.ErdEdge, points: table) line
---@return fun(edge: sqmeow.ErdEdge, box: sqmeow.ErdBox, row: integer, box_on_left: boolean) finish
local function new_part(glyphs, dashed)
  local part = { w = 0, h = 0, boxes = {}, routes = {}, markers = {}, attach = {} }
  local route_of = {}
  local function line(edge, points)
    local route = route_of[edge.id]
    if not route then
      route = { edge = edge, points = {}, dotted = dashed and not edge.identifying }
      route_of[edge.id] = route
      table.insert(part.routes, route)
    end
    table.insert(route.points, points)
  end
  --- Draw an edge's end beside a box's border.
  local function finish(edge, box, row, box_on_left)
    local parent = box.node == edge.parent and row == anchor_row(box, edge.parent_columns)
    if edge.child == edge.parent then
      parent = row == anchor_row(box, edge.parent_columns)
        and row ~= anchor_row(box, edge.child_columns)
    end
    local far, near = end_glyphs(edge, parent, box_on_left, glyphs)
    local y = box.y + row
    local border = box_on_left and (box.x + box.w - 1) or box.x
    local step = box_on_left and 1 or -1
    -- A label's ends are glyphs of their own, not a border to branch from.
    if not box.label then
      table.insert(part.attach, {
        x = border,
        y = y,
        edge = edge.id,
        side = box_on_left and 'right' or 'left',
      })
    end
    for distance, text in ipairs({ near, far }) do
      table.insert(part.markers, {
        x = border + distance * step,
        y = y,
        text = text,
        edge = edge.id,
        weight = looseness(text, glyphs),
      })
    end
  end
  return part, line, finish
end

--- A loop from a table back to itself, on its right side.
---@param edge sqmeow.ErdEdge
---@param box sqmeow.ErdBox
---@param track integer
---@param line fun(edge: sqmeow.ErdEdge, points: table)
---@param finish fun(edge: sqmeow.ErdEdge, box: sqmeow.ErdBox, row: integer, box_on_left: boolean)
local function loop(edge, box, track, line, finish)
  local from_row = anchor_row(box, edge.child_columns)
  local to_row = anchor_row(box, edge.parent_columns)
  if from_row == to_row then
    to_row = from_row == 1 and math.min(2, #box.rows) or from_row - 1
  end
  local out_x = box.x + box.w + 2
  line(edge, {
    { out_x, box.y + from_row },
    { track, box.y + from_row },
    { track, box.y + to_row },
    { out_x, box.y + to_row },
  })
  finish(edge, box, from_row, true)
  if to_row ~= from_row then
    finish(edge, box, to_row, true)
  end
end

--- Lay out one connected group with its top left corner at the origin.
---@param ids integer[]
---@param graph sqmeow.ErdGraph
---@param boxes table<integer, sqmeow.ErdBox>
---@param glyphs sqmeow.ErdGlyphs
---@param dashed boolean
---@return sqmeow.ErdPart
local function layout_group(ids, graph, boxes, glyphs, dashed)
  local inside = {}
  for _, id in ipairs(ids) do
    inside[id] = true
  end
  local edges, loops = {}, {}
  for _, edge in ipairs(graph.edges) do
    if inside[edge.child] then
      if edge.child == edge.parent then
        if not boxes[edge.child].label then
          table.insert(loops, edge)
        end
      else
        table.insert(edges, edge)
      end
    end
  end
  local ranks = rank(ids, edges)
  optimize(ids, edges, ranks, boxes)

  local layers, item_of = {}, {}
  local function add(item)
    layers[item.layer + 1] = layers[item.layer + 1] or {}
    table.insert(layers[item.layer + 1], item)
    item.order = #layers[item.layer + 1]
    return item
  end
  for _, id in ipairs(ids) do
    item_of[id] = add({ box = boxes[id], layer = ranks[id], y = 0, h = boxes[id].h })
  end
  for i = 1, #layers do
    layers[i] = layers[i] or {}
  end

  -- Each edge becomes one segment per gap it crosses. Edges to the same referenced column
  -- form a bundle, on whichever side its tables sit: they share the slots they pass through
  -- and one trunk in each gap, so a bundle is one line until it splits for its tables.
  local segments, links, linked = {}, {}, {}
  local slots = {}
  for _, edge in ipairs(edges) do
    local parent, child = item_of[edge.parent], item_of[edge.child]
    local parent_row = anchor_row(parent.box, edge.parent_columns)
    local child_row = anchor_row(child.box, edge.child_columns)
    local from, to, from_row, to_row = parent, child, parent_row, child_row
    if parent.layer > child.layer then
      from, to, from_row, to_row = child, parent, child_row, parent_row
    end
    local bundle = edge.parent .. ':' .. parent_row
    local previous, previous_row = from, from_row
    for layer = from.layer + 1, to.layer do
      local item, row = to, to_row
      if layer < to.layer then
        local key = bundle .. ':' .. layer
        slots[key] = slots[key] or add({ layer = layer, y = 0, h = 1 })
        item, row = slots[key], 0
      end
      local segment = {
        edge = edge,
        bundle = bundle,
        left = previous,
        right = item,
        left_row = previous_row,
        right_row = row,
      }
      table.insert(segments, segment)
      linked[previous] = linked[previous] or {}
      if not linked[previous][item] then
        linked[previous][item] = true
        table.insert(links, segment)
      end
      previous, previous_row = item, row
    end
  end

  local by_gutter = {}
  for _, link in ipairs(links) do
    local gutter = link.left.layer
    by_gutter[gutter] = by_gutter[gutter] or {}
    table.insert(by_gutter[gutter], link)
  end
  local function total()
    local sum = 0
    for _, list in pairs(by_gutter) do
      sum = sum + crossings(list)
    end
    return sum
  end

  -- Barycenter ordering: each item moves to the mean position of its neighbours in the layer
  -- just ordered, sweeping right then left; the best ordering seen is kept.
  local function sweep(layer, toward_left)
    local sums, counts = {}, {}
    for _, link in ipairs(by_gutter[toward_left and layer - 1 or layer] or {}) do
      local mine = toward_left and link.right or link.left
      local other = toward_left and link.left or link.right
      sums[mine] = (sums[mine] or 0) + other.order
      counts[mine] = (counts[mine] or 0) + 1
    end
    local list = layers[layer + 1]
    local keys = {}
    for _, item in ipairs(list) do
      keys[item] = counts[item] and (sums[item] / counts[item]) or item.order
    end
    table.sort(list, function(a, b)
      if keys[a] ~= keys[b] then
        return keys[a] < keys[b]
      end
      return a.order < b.order
    end)
    for index, item in ipairs(list) do
      item.order = index
    end
  end
  local function snapshot()
    local saved = {}
    for _, list in ipairs(layers) do
      for _, item in ipairs(list) do
        saved[item] = item.order
      end
    end
    return saved
  end

  local best, best_count = snapshot(), total()
  for _ = 1, 8 do
    if best_count == 0 then
      break
    end
    for layer = 1, #layers - 1 do
      sweep(layer, true)
    end
    for layer = #layers - 2, 0, -1 do
      sweep(layer, false)
    end
    local now = total()
    if now < best_count then
      best, best_count = snapshot(), now
    end
  end
  for _, list in ipairs(layers) do
    for _, item in ipairs(list) do
      item.order = best[item]
    end
    table.sort(list, function(a, b)
      return a.order < b.order
    end)
  end

  -- Vertical placement: each item wants the rows its neighbours attach at, so edges run
  -- straight, and gets as near as the order and spacing allow, up or down.
  local gap = 1
  local height = 0
  for _, list in ipairs(layers) do
    local bottom = -gap
    for _, item in ipairs(list) do
      item.y = bottom + gap
      bottom = item.y + item.h
    end
    height = math.max(height, bottom)
  end
  local function align(layer, left, right)
    local found = {}
    local function wish(item, target)
      found[item] = found[item] or {}
      table.insert(found[item], target)
    end
    if left then
      for _, link in ipairs(by_gutter[layer - 1] or {}) do
        wish(link.right, link.left.y + link.left_row - link.right_row)
      end
    end
    if right then
      for _, link in ipairs(by_gutter[layer] or {}) do
        wish(link.left, link.right.y + link.right_row - link.left_row)
      end
    end
    local wishes = {}
    for item, targets in pairs(found) do
      -- A median, never a mean of two: one edge straight beats two bent.
      table.sort(targets)
      local target = targets[math.ceil(#targets / 2)]
      -- A slot is a line: keeping it straight matters more than where a box sits.
      wishes[item] = { target = target, weight = (item.box and 1 or 2) * #targets }
    end
    settle(layers[layer + 1], wishes, gap, height)
  end
  for _ = 1, 3 do
    for layer = 1, #layers - 1 do
      align(layer, true, false)
    end
    for layer = #layers - 2, 0, -1 do
      align(layer, false, true)
    end
  end
  for layer = 0, #layers - 1 do
    align(layer, true, true)
  end

  local top = math.huge
  for _, list in ipairs(layers) do
    for _, item in ipairs(list) do
      top = math.min(top, item.y)
    end
  end
  for _, list in ipairs(layers) do
    for _, item in ipairs(list) do
      item.y = item.y - top
    end
  end

  -- Trunks: one per bundle in each gap, spanning every row the bundle enters or leaves it at.
  ---@type table<integer, table<string, sqmeow.ErdTrunk>>
  local trunks_in = {}
  local trunk_of = {}
  -- Rows some line enters or leaves each gap at; a trunk may only step sideways elsewhere.
  local busy = {}
  for _, segment in ipairs(segments) do
    local ya = segment.left.y + segment.left_row
    local yb = segment.right.y + segment.right_row
    local gutter = segment.left.layer
    busy[gutter] = busy[gutter] or {}
    busy[gutter][ya], busy[gutter][yb] = true, true
    if ya ~= yb then
      trunks_in[gutter] = trunks_in[gutter] or {}
      local trunk = trunks_in[gutter][segment.bundle]
      if not trunk then
        trunk = { lefts = {}, rights = {}, low = ya, high = ya, drop = 0 }
        trunks_in[gutter][segment.bundle] = trunk
      end
      trunk.lefts[ya], trunk.rights[yb] = true, true
      trunk.low = math.min(trunk.low, ya, yb)
      trunk.high = math.max(trunk.high, ya, yb)
      trunk.drop = trunk.drop + (yb - ya)
      trunk_of[segment] = trunk
    end
  end
  local loops_in = {}
  for _, edge in ipairs(loops) do
    local layer = item_of[edge.child].layer
    loops_in[layer] = loops_in[layer] or {}
    table.insert(loops_in[layer], edge)
  end

  --- Whether `a` must run left of `b`: `a` leaves the left side at a row where `b` arrives on
  --- the right, and the two lines along that row would otherwise overlap.
  local function before(a, b)
    for row in pairs(a.lefts) do
      if b.rights[row] then
        return true
      end
    end
    return false
  end
  --- Middle of the rows a trunk leaves at, to order trunks so fewer cross.
  local function leaving(trunk)
    local sum, count = 0, 0
    for row in pairs(trunk.lefts) do
      sum, count = sum + row, count + 1
    end
    return sum / count
  end

  -- Layer columns and gap widths.
  local layer_x, layer_w, spacing, ordered_trunks = {}, {}, {}, {}
  local x = 0
  for index, list in ipairs(layers) do
    local layer = index - 1
    local w = 0
    for _, item in ipairs(list) do
      if item.box then
        w = math.max(w, item.box.w)
      end
    end
    layer_x[layer], layer_w[layer] = x, w

    -- Trunks heading down: the one leaving higher goes farther right; heading up, the one
    -- leaving lower. Those orders cross least.
    local list_trunks = {}
    for _, trunk in pairs(trunks_in[layer] or {}) do
      trunk.down = trunk.drop >= 0
      trunk.key = leaving(trunk)
      table.insert(list_trunks, trunk)
    end
    table.sort(list_trunks, function(a, b)
      if a.down ~= b.down then
        return a.down
      end
      if a.key ~= b.key then
        return (a.down and a.key > b.key) or (not a.down and a.key < b.key)
      end
      return a.low < b.low
    end)
    local placed, ordered = {}, {}
    while #ordered < #list_trunks do
      local chosen
      for _, candidate in ipairs(list_trunks) do
        if not placed[candidate] then
          local ready = true
          for _, other in ipairs(list_trunks) do
            if other ~= candidate and not placed[other] and before(other, candidate) then
              ready = false
              break
            end
          end
          if ready then
            chosen = candidate
            break
          end
        end
      end
      if not chosen then
        -- Every trunk left must run left of another: two of them each leave at a row the
        -- other arrives at. Split one: its departures go along one track to a free row, across,
        -- and on along a second track placed later, right of the trunks it had to clear.
        for _, candidate in ipairs(list_trunks) do
          if not placed[candidate] then
            chosen = candidate
            break
          end
        end
        local origin = math.floor(chosen.key + 0.5)
        local toward = chosen.down and 1 or -1
        local turn
        for distance = 1, chosen.high - chosen.low + 2 do
          for _, row in ipairs({ origin + toward * distance, origin - toward * distance }) do
            if not turn and not (busy[layer] or {})[row] then
              turn = row
            end
          end
          if turn then
            break
          end
        end
        if turn then
          local low, high = turn, turn
          for row in pairs(chosen.rights) do
            low, high = math.min(low, row), math.max(high, row)
          end
          local rest = {
            lefts = { [turn] = true },
            rights = chosen.rights,
            low = low,
            high = high,
            drop = chosen.drop,
            down = chosen.down,
            key = turn,
          }
          low, high = turn, turn
          for row in pairs(chosen.lefts) do
            low, high = math.min(low, row), math.max(high, row)
          end
          chosen.rights = { [turn] = true }
          chosen.low, chosen.high = low, high
          chosen.turn, chosen.rest = turn, rest
          busy[layer] = busy[layer] or {}
          busy[layer][turn] = true
          table.insert(list_trunks, rest)
        end
      end
      placed[chosen] = true
      table.insert(ordered, chosen)
    end
    ordered_trunks[layer] = ordered

    -- Loops sit beside their own boxes, in the first columns of the gap.
    local looped, most = {}, 0
    for _, edge in ipairs(loops_in[layer] or {}) do
      looped[edge.child] = (looped[edge.child] or 0) + 1
      most = math.max(most, looped[edge.child])
    end

    -- Columns: trunks share one when their spans are a row apart, as wires do in channel
    -- routing. In placing order each takes the leftmost column right of every trunk it must
    -- clear.
    local columns, column_of = {}, {}
    for _, trunk in ipairs(ordered) do
      local least = most + 1
      for _, other in ipairs(ordered) do
        if column_of[other] and before(other, trunk) then
          least = math.max(least, column_of[other] + 1)
        end
      end
      local column = least
      while true do
        local free = true
        for _, span in ipairs(columns[column] or {}) do
          if trunk.low <= span[2] + 1 and span[1] <= trunk.high + 1 then
            free = false
            break
          end
        end
        if free then
          break
        end
        column = column + 1
      end
      columns[column] = columns[column] or {}
      table.insert(columns[column], { trunk.low, trunk.high })
      column_of[trunk] = column
      trunk.column = column
    end
    local used = most
    for column in pairs(columns) do
      used = math.max(used, column)
    end

    spacing[layer] = 2
    local gutter = 0
    if index < #layers or used > 0 then
      -- Two marker cells each side, a cell of air each side, then the tracks.
      gutter = 6 + math.max(1, used) * spacing[layer] + 1
    end
    x = x + w + gutter
  end

  local part, line, finish = new_part(glyphs, dashed)
  part.w = x
  for _, list in ipairs(layers) do
    for _, item in ipairs(list) do
      part.h = math.max(part.h, item.y + item.h)
      if item.box then
        item.box.x = layer_x[item.layer]
        item.box.y = item.y
        table.insert(part.boxes, item.box)
      end
    end
  end

  for index = 1, #layers do
    local layer = index - 1
    local start = layer_x[layer] + layer_w[layer] + 3
    -- A loop hugs its own box: nothing else runs beside a box's rows inside its layer.
    local per_box = {}
    for _, edge in ipairs(loops_in[layer] or {}) do
      local box = boxes[edge.child]
      per_box[box] = (per_box[box] or 0) + 1
      loop(edge, box, box.x + box.w + 3 + (per_box[box] - 1) * spacing[layer], line, finish)
    end
    for _, trunk in ipairs(ordered_trunks[layer]) do
      trunk.track = start + (trunk.column - 1) * spacing[layer]
    end
  end

  local function left_x(item)
    if item.box then
      return item.box.x + item.box.w + 2
    end
    return layer_x[item.layer]
  end
  local function right_x(item)
    if item.box then
      return item.box.x - 3
    end
    return layer_x[item.layer] + layer_w[item.layer] - 1
  end

  for _, segment in ipairs(segments) do
    local ya = segment.left.y + segment.left_row
    local yb = segment.right.y + segment.right_row
    local trunk = trunk_of[segment]
    if trunk and trunk.rest then
      line(segment.edge, {
        { left_x(segment.left), ya },
        { trunk.track, ya },
        { trunk.track, trunk.turn },
        { trunk.rest.track, trunk.turn },
        { trunk.rest.track, yb },
        { right_x(segment.right), yb },
      })
    elseif trunk then
      line(segment.edge, {
        { left_x(segment.left), ya },
        { trunk.track, ya },
        { trunk.track, yb },
        { right_x(segment.right), yb },
      })
    else
      line(segment.edge, { { left_x(segment.left), ya }, { right_x(segment.right), yb } })
    end
    if segment.left.box then
      finish(segment.edge, segment.left.box, segment.left_row, true)
    end
    if segment.right.box then
      finish(segment.edge, segment.right.box, segment.right_row, false)
    else
      -- A slot is crossed straight through its layer.
      local item = segment.right
      line(segment.edge, {
        { layer_x[item.layer], item.y },
        { layer_x[item.layer] + layer_w[item.layer] - 1, item.y },
      })
    end
  end
  return part
end

--- A table on its own, with any loops back to itself.
---@param id integer
---@param graph sqmeow.ErdGraph
---@param boxes table<integer, sqmeow.ErdBox>
---@param glyphs sqmeow.ErdGlyphs
---@param dashed boolean
---@return sqmeow.ErdPart
local function layout_alone(id, graph, boxes, glyphs, dashed)
  local part, line, finish = new_part(glyphs, dashed)
  local box = boxes[id]
  box.x, box.y = 0, 0
  table.insert(part.boxes, box)
  local count = 0
  for _, edge in ipairs(graph.edges) do
    if edge.child == id and edge.parent == id and not box.label then
      loop(edge, box, box.x + box.w + 3 + count * 2, line, finish)
      count = count + 1
    end
  end
  part.w = box.w + (count > 0 and (6 + count * 2) or 0)
  part.h = box.h
  return part
end

--- Move a part by `dx`, `dy`.
---@param part sqmeow.ErdPart
---@param dx integer
---@param dy integer
local function shift(part, dx, dy)
  for _, box in ipairs(part.boxes) do
    box.x, box.y = box.x + dx, box.y + dy
  end
  for _, route in ipairs(part.routes) do
    for _, points in ipairs(route.points) do
      for _, point in ipairs(points) do
        point[1], point[2] = point[1] + dx, point[2] + dy
      end
    end
  end
  for _, list in ipairs({ part.markers, part.attach }) do
    for _, entry in ipairs(list) do
      entry.x, entry.y = entry.x + dx, entry.y + dy
    end
  end
end

--- Lay out a graph.
---@param graph sqmeow.ErdGraph
---@param opts sqmeow.ErdLayoutOpts|nil
---@param glyphs sqmeow.ErdGlyphs|nil
---@return sqmeow.ErdLayout
function M.layout(graph, opts, glyphs)
  opts = vim.tbl_extend('keep', opts or {}, {
    icon = function(kind)
      return kind == 'primary_key' and '#' or kind == 'foreign_key' and '>' or ' '
    end,
  })
  glyphs = vim.tbl_extend('keep', glyphs or {}, {
    one = '┼',
    zero = '○',
    many = '<',
    many_reversed = '>',
  })
  local dashed = opts.dashed == true

  local anchored = {}
  for _, node in ipairs(graph.nodes) do
    anchored[node.id] = {}
  end
  for _, edge in ipairs(graph.edges) do
    for _, index in ipairs(edge.parent_columns) do
      anchored[edge.parent][index] = true
    end
  end
  local loops = {}
  for _, edge in ipairs(graph.edges) do
    if edge.child == edge.parent then
      loops[edge.child] = true
    end
  end
  opts.loops = loops
  local boxes = {}
  for _, node in ipairs(graph.nodes) do
    boxes[node.id] = measure(node, anchored[node.id], opts)
  end

  local connected, single = {}, {}
  for _, ids in ipairs(components(graph)) do
    if #ids > 1 then
      table.insert(connected, layout_group(ids, graph, boxes, glyphs, dashed))
    else
      table.insert(single, layout_alone(ids[1], graph, boxes, glyphs, dashed))
    end
  end
  table.sort(connected, function(a, b)
    if a.h ~= b.h then
      return a.h > b.h
    end
    return #a.boxes > #b.boxes
  end)

  -- Parts in columns, tallest first, each column filled top to bottom up to the tallest part
  -- or the height that makes the whole about three cells wide per row. Small groups and lone
  -- tables fill the space beside a big group instead of a row of their own below it.
  local parts = vim.list_extend(vim.list_slice(connected), single)
  local area, tallest, biggest = 0, 0, 0
  for _, part in ipairs(parts) do
    local size = (part.w + 4) * (part.h + 1)
    area = area + size
    tallest = math.max(tallest, part.h)
    biggest = math.max(biggest, size)
  end
  -- A group that is most of the drawing sets the height; the rest stack beside it, not below.
  local height = tallest
  if biggest < area * 0.3 then
    height = math.max(tallest, math.ceil(math.sqrt(area / 3)))
  end
  local margin_x, margin_y = 2, 1
  local x, y, column_width = margin_x, margin_y, 0
  for _, part in ipairs(parts) do
    local gap_y = #part.boxes > 1 and 2 or 1
    if y > margin_y and y + part.h > margin_y + height then
      x = x + column_width + 4
      y, column_width = margin_y, 0
    end
    shift(part, x, y)
    y = y + part.h + gap_y
    column_width = math.max(column_width, part.w)
  end

  local layout = {
    width = 0,
    height = 0,
    boxes = {},
    order = {},
    routes = {},
    markers = {},
    attach = {},
  }
  for _, part in ipairs(parts) do
    for _, box in ipairs(part.boxes) do
      layout.boxes[box.node] = box
      table.insert(layout.order, box.node)
      layout.width = math.max(layout.width, box.x + box.w)
      layout.height = math.max(layout.height, box.y + box.h)
    end
    vim.list_extend(layout.routes, part.routes)
    vim.list_extend(layout.markers, part.markers)
    vim.list_extend(layout.attach, part.attach)
  end
  for _, route in ipairs(layout.routes) do
    for _, points in ipairs(route.points) do
      for _, point in ipairs(points) do
        layout.width = math.max(layout.width, point[1] + 1)
        layout.height = math.max(layout.height, point[2] + 1)
      end
    end
  end
  layout.width = layout.width + margin_x
  layout.height = layout.height + 1

  -- Ends sharing a cell, as edges merging into one row do, show the loosest of them.
  local loosest = {}
  for _, marker in ipairs(layout.markers) do
    local cell = marker.y .. ':' .. marker.x
    if not loosest[cell] or marker.weight > loosest[cell].weight then
      loosest[cell] = marker
    end
  end
  for _, marker in ipairs(layout.markers) do
    marker.text = loosest[marker.y .. ':' .. marker.x].text
  end

  -- Reading order: group by group, then by layer, top to bottom.
  local rank_of = {}
  for index, id in ipairs(layout.order) do
    rank_of[id] = index
  end
  local part_of = {}
  for index, part in ipairs(parts) do
    for _, box in ipairs(part.boxes) do
      part_of[box.node] = index
    end
  end
  table.sort(layout.order, function(a, b)
    local ba, bb = layout.boxes[a], layout.boxes[b]
    if part_of[a] ~= part_of[b] then
      return part_of[a] < part_of[b]
    end
    if ba.x ~= bb.x then
      return ba.x < bb.x
    end
    if ba.y ~= bb.y then
      return ba.y < bb.y
    end
    return rank_of[a] < rank_of[b]
  end)
  return layout
end

return M
