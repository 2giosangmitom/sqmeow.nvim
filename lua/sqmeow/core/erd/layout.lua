--- Place an ERD's tables and route its foreign keys on a character grid. Pure: no editor state.
---
--- Tables are boxes in layers, parents to the left of their children. Each connected group
--- of tables is laid out on its own, groups are stacked, and tables with no foreign keys to
--- or from another table are packed in rows below. Edges run orthogonally: out of the
--- parent's right side at the referenced column, along a vertical track in the gap between
--- layers, into the child's left side at the foreign key column. An edge spanning several
--- layers passes through a one-row slot reserved in each layer between.

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
---@field max_rows integer|nil Columns shown before the rest fold into `… N more`; 0 shows all.
---@field max_width integer|nil Widest a column name or type is drawn.
---@field compact boolean|nil Show only key columns.
---@field dashed boolean|nil Draw non-identifying foreign keys dashed, as Mermaid does.
---@field expanded table<integer, boolean>|nil Node ids whose columns all show, whatever the limits.
---@field icon fun(kind: 'primary_key'|'foreign_key'): string, string|nil Glyph and its role.

---@class sqmeow.ErdPiece
---@field text string
---@field role string What the text is: `pk`, `fk`, `name`, `key_name`, `type`, `more`, `title`.

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

--- Lay out a box's rows: which columns show, and how each is spelled.
---@param node sqmeow.ErdNode
---@param anchored table<integer, boolean> Columns an edge attaches to; they always show.
---@param opts sqmeow.ErdLayoutOpts
---@return sqmeow.ErdBox
local function measure(node, anchored, opts)
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

  local pk_icon = opts.icon('primary_key')
  local fk_icon = opts.icon('foreign_key')
  local icon_width = math.max(strwidth(pk_icon), strwidth(fk_icon))

  local shown = {}
  local name_width, type_width = 0, 0
  for index, column in ipairs(node.columns) do
    if keep[index] then
      local name = M.fit(column.name, max_width)
      local type = M.fit(column.type, max_width)
      table.insert(shown, { index = index, column = column, name = name, type = type })
      name_width = math.max(name_width, strwidth(name))
      type_width = math.max(type_width, strwidth(type))
    end
  end

  local rows, row_of = {}, {}
  for _, entry in ipairs(shown) do
    local column = entry.column
    local icon, role = ' ', 'name'
    if column.pk then
      icon, role = pk_icon, 'pk'
    elseif column.fk then
      icon, role = fk_icon, 'fk'
    end
    icon = icon .. (' '):rep(icon_width - strwidth(icon))
    table.insert(rows, {
      column = entry.index,
      pieces = {
        { text = icon, role = role },
        { text = ' ', role = 'name' },
        {
          text = entry.name .. (' '):rep(name_width - strwidth(entry.name)),
          role = column.pk and 'key_name' or 'name',
        },
        { text = '  ', role = 'name' },
        { text = entry.type .. (' '):rep(type_width - strwidth(entry.type)), role = 'type' },
      },
    })
    row_of[entry.index] = #rows
  end

  local hidden = #node.columns - #shown
  if hidden > 0 then
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
  local w = math.max(inner + 4, strwidth(title) + 6)

  return {
    node = node.id,
    x = 0,
    y = 0,
    w = w,
    h = #rows + 2,
    title = title,
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
  for _, index in ipairs(columns) do
    if box.row_of[index] then
      return box.row_of[index]
    end
  end
  return 1
end

---@class sqmeow.ErdItem
---@field box sqmeow.ErdBox|nil A table, or nil for an edge's slot through a layer.
---@field edge integer|nil The edge a slot belongs to.
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
---@field gutter integer The gap after layer `left.layer`.

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

--- Layer numbers, parents before children, with cycles broken where a depth-first walk
--- meets a node it is still inside.
---@param ids integer[]
---@param edges sqmeow.ErdEdge[] Edges within the group, self-references excluded.
---@return table<integer, integer> rank Zero-based layer of each node.
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
  return ranks
end

--- Crossings between the segments of one gap, given each item's position in its layer.
---@param segments sqmeow.ErdSegment[]
---@return integer
local function crossings(segments)
  local count = 0
  for i = 1, #segments do
    local a = segments[i]
    for j = i + 1, #segments do
      local b = segments[j]
      if (a.left.order - b.left.order) * (a.right.order - b.right.order) < 0 then
        count = count + 1
      end
    end
  end
  return count
end

--- Lay out one connected group at the origin.
---@param ids integer[]
---@param graph sqmeow.ErdGraph
---@param boxes table<integer, sqmeow.ErdBox>
---@return { layers: sqmeow.ErdItem[][], segments: sqmeow.ErdSegment[], loops: sqmeow.ErdEdge[] }
local function layer_group(ids, graph, boxes)
  local inside = {}
  for _, id in ipairs(ids) do
    inside[id] = true
  end
  local edges, loops = {}, {}
  for _, edge in ipairs(graph.edges) do
    if inside[edge.child] then
      if edge.child == edge.parent then
        table.insert(loops, edge)
      else
        table.insert(edges, edge)
      end
    end
  end
  local ranks = rank(ids, edges)

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

  -- Each edge becomes one segment per gap it crosses, through a slot in each layer between.
  local segments = {}
  for _, edge in ipairs(edges) do
    local parent, child = item_of[edge.parent], item_of[edge.child]
    local parent_row = anchor_row(parent.box, edge.parent_columns)
    local child_row = anchor_row(child.box, edge.child_columns)
    local from, to, from_row, to_row = parent, child, parent_row, child_row
    if parent.layer > child.layer then
      from, to, from_row, to_row = child, parent, child_row, parent_row
    end
    local previous, previous_row = from, from_row
    for layer = from.layer + 1, to.layer do
      local item, row = to, to_row
      if layer < to.layer then
        item, row = add({ edge = edge.id, layer = layer, y = 0, h = 1 }), 0
      end
      table.insert(segments, {
        edge = edge,
        left = previous,
        right = item,
        left_row = previous_row,
        right_row = row,
        gutter = previous.layer,
      })
      previous, previous_row = item, row
    end
  end

  local by_gutter = {}
  for _, segment in ipairs(segments) do
    by_gutter[segment.gutter] = by_gutter[segment.gutter] or {}
    table.insert(by_gutter[segment.gutter], segment)
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
    for _, segment in ipairs(by_gutter[toward_left and layer - 1 or layer] or {}) do
      local mine = toward_left and segment.right or segment.left
      local other = toward_left and segment.left or segment.right
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
  for _ = 1, 6 do
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

  -- Vertical placement: each item is pulled toward the rows its neighbours attach at, so
  -- edges run straight wherever the order allows, and pushed down only to clear the item
  -- above it.
  local gap = 1
  for _, list in ipairs(layers) do
    local bottom = -gap
    for _, item in ipairs(list) do
      item.y = bottom + gap
      bottom = item.y + item.h
    end
  end
  local function align(layer, toward_left)
    local wishes = {}
    for _, segment in ipairs(by_gutter[toward_left and layer - 1 or layer] or {}) do
      local mine = toward_left and segment.right or segment.left
      local other = toward_left and segment.left or segment.right
      local my_row = toward_left and segment.right_row or segment.left_row
      local other_row = toward_left and segment.left_row or segment.right_row
      wishes[mine] = wishes[mine] or {}
      table.insert(wishes[mine], other.y + other_row - my_row)
    end
    local bottom = -math.huge
    for _, item in ipairs(layers[layer + 1]) do
      local wish = item.y
      if wishes[item] then
        table.sort(wishes[item])
        wish = wishes[item][math.ceil(#wishes[item] / 2)]
      end
      item.y = math.max(wish, bottom + gap)
      bottom = item.y + item.h
    end
  end
  for _ = 1, 2 do
    for layer = 1, #layers - 1 do
      align(layer, true)
    end
    for layer = #layers - 2, 0, -1 do
      align(layer, false)
    end
  end
  for layer = 1, #layers - 1 do
    align(layer, true)
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

  return { layers = layers, segments = segments, loops = loops }
end

---@class sqmeow.ErdMarker
---@field x integer
---@field y integer
---@field text string
---@field edge integer

---@class sqmeow.ErdRoute
---@field edge sqmeow.ErdEdge
---@field points { [1]: integer, [2]: integer }[][] Polylines, each a list of `{ x, y }` corners.
---@field dotted boolean

---@class sqmeow.ErdLayout
---@field width integer
---@field height integer
---@field boxes table<integer, sqmeow.ErdBox> By node id.
---@field order integer[] Node ids in reading order: layer by layer, each top to bottom.
---@field routes sqmeow.ErdRoute[]
---@field markers sqmeow.ErdMarker[]
---@field attach { x: integer, y: integer, edge: integer, side: 'left'|'right' }[] Border
--- cells an edge joins, and the side the edge arrives from.

--- Glyphs for an edge's end, outside in: the cell farther from the box, then the nearer one.
---@param edge sqmeow.ErdEdge
---@param parent boolean
---@param box_on_left boolean
---@param glyphs { one: string, zero: string, many: string, many_reversed: string }
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

--- Lay out a graph.
---@param graph sqmeow.ErdGraph
---@param opts sqmeow.ErdLayoutOpts|nil
---@param glyphs { one: string, zero: string, many: string, many_reversed: string }|nil
---@return sqmeow.ErdLayout
function M.layout(graph, opts, glyphs)
  opts = vim.tbl_extend('keep', opts or {}, {
    icon = function(kind)
      return kind == 'primary_key' and '#' or '>'
    end,
  })
  glyphs = vim.tbl_extend('keep', glyphs or {}, {
    one = '┼',
    zero = '○',
    many = '<',
    many_reversed = '>',
  })

  local anchored = {}
  for _, node in ipairs(graph.nodes) do
    anchored[node.id] = {}
  end
  for _, edge in ipairs(graph.edges) do
    for _, index in ipairs(edge.parent_columns) do
      anchored[edge.parent][index] = true
    end
  end
  local boxes = {}
  for _, node in ipairs(graph.nodes) do
    boxes[node.id] = measure(node, anchored[node.id], opts)
  end

  local routes, markers, attach = {}, {}, {}
  local route_of = {}
  local function route(edge)
    if not route_of[edge.id] then
      route_of[edge.id] =
        { edge = edge, points = {}, dotted = opts.dashed == true and not edge.identifying }
      table.insert(routes, route_of[edge.id])
    end
    return route_of[edge.id]
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
    table.insert(
      attach,
      { x = border, y = y, edge = edge.id, side = box_on_left and 'right' or 'left' }
    )
    table.insert(markers, { x = border + step, y = y, text = near, edge = edge.id })
    table.insert(markers, { x = border + 2 * step, y = y, text = far, edge = edge.id })
  end

  local groups = components(graph)
  local connected, single = {}, {}
  for _, ids in ipairs(groups) do
    table.insert(#ids > 1 and connected or single, ids)
  end
  table.sort(connected, function(a, b)
    return #a > #b
  end)

  local margin_x, margin_y = 2, 1
  local cursor_y = margin_y
  local widest = 0

  -- A loop leaves the right side, so it needs a track in the gap after its layer.
  local function place_group(ids)
    local group = layer_group(ids, graph, boxes)
    local layers = group.layers

    local tracks_in = {}
    for _, segment in ipairs(group.segments) do
      local ya = segment.left.y + segment.left_row
      local yb = segment.right.y + segment.right_row
      if ya ~= yb then
        tracks_in[segment.gutter] = tracks_in[segment.gutter] or {}
        table.insert(tracks_in[segment.gutter], segment)
      end
    end
    local loops_in = {}
    for _, loop in ipairs(group.loops) do
      local layer = 0
      for index, list in ipairs(layers) do
        for _, item in ipairs(list) do
          if item.box and item.box.node == loop.child then
            layer = index - 1
          end
        end
      end
      loops_in[layer] = loops_in[layer] or {}
      table.insert(loops_in[layer], loop)
    end

    -- Layer columns and gap widths.
    local layer_x, layer_w, gutter_w, spacing = {}, {}, {}, {}
    local x = margin_x
    for index, list in ipairs(layers) do
      local layer = index - 1
      local w = 0
      for _, item in ipairs(list) do
        if item.box then
          w = math.max(w, item.box.w)
        end
      end
      layer_x[layer], layer_w[layer] = x, w
      local tracks = #(tracks_in[layer] or {}) + #(loops_in[layer] or {})
      spacing[layer] = tracks > 8 and 1 or 2
      if index < #layers or tracks > 0 then
        -- Two marker cells each side, a cell of air each side, then the tracks.
        gutter_w[layer] = 6 + math.max(1, tracks) * spacing[layer] + 1
      else
        gutter_w[layer] = 0
      end
      x = x + w + gutter_w[layer]
    end
    widest = math.max(widest, x)

    local height = 0
    for _, list in ipairs(layers) do
      for _, item in ipairs(list) do
        item.y = item.y + cursor_y
        height = math.max(height, item.y + item.h)
        if item.box then
          item.box.x = layer_x[item.layer]
          item.box.y = item.y
        end
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

    -- Tracks: loops nearest the layer; then edges heading down, the ones starting higher
    -- farther right, then edges heading up, the ones starting lower farther right. An edge
    -- that leaves at the row another enters goes left of it, so the two never share a row.
    for index = 1, #layers do
      local layer = index - 1
      local list = tracks_in[layer] or {}
      local function key(segment)
        local ya = segment.left.y + segment.left_row
        local yb = segment.right.y + segment.right_row
        if ya < yb then
          return 0, -ya
        end
        return 1, ya
      end
      table.sort(list, function(a, b)
        local ga, ka = key(a)
        local gb, kb = key(b)
        if ga ~= gb then
          return ga < gb
        end
        if ka ~= kb then
          return ka < kb
        end
        return a.edge.id < b.edge.id
      end)
      local placed, ordered = {}, {}
      while #ordered < #list do
        local chosen
        for _, candidate in ipairs(list) do
          if not placed[candidate] then
            local ready = true
            local enters = candidate.right.y + candidate.right_row
            for _, other in ipairs(list) do
              if
                other ~= candidate
                and not placed[other]
                and other.left.y + other.left_row == enters
              then
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
          for _, candidate in ipairs(list) do
            if not placed[candidate] then
              chosen = candidate
              break
            end
          end
        end
        placed[chosen] = true
        table.insert(ordered, chosen)
      end

      local start = layer_x[layer] + layer_w[layer] + 3
      local slot = 0
      -- A loop hugs its own box: nothing else runs beside a box's rows inside its layer.
      local per_box = {}
      for _, loop in ipairs(loops_in[layer] or {}) do
        local box = boxes[loop.child]
        per_box[box] = (per_box[box] or 0) + 1
        local track = box.x + box.w + 3 + (per_box[box] - 1) * spacing[layer]
        slot = slot + 1
        local from_row = anchor_row(box, loop.child_columns)
        local to_row = anchor_row(box, loop.parent_columns)
        if from_row == to_row then
          to_row = from_row == 1 and math.min(2, #box.rows) or from_row - 1
        end
        local out_x = box.x + box.w + 2
        table.insert(route(loop).points, {
          { out_x, box.y + from_row },
          { track, box.y + from_row },
          { track, box.y + to_row },
          { out_x, box.y + to_row },
        })
        finish(loop, box, from_row, true)
        if to_row ~= from_row then
          finish(loop, box, to_row, true)
        end
      end
      for _, segment in ipairs(ordered) do
        local track = start + slot * spacing[layer]
        slot = slot + 1
        local ya = segment.left.y + segment.left_row
        local yb = segment.right.y + segment.right_row
        table.insert(route(segment.edge).points, {
          { left_x(segment.left), ya },
          { track, ya },
          { track, yb },
          { right_x(segment.right), yb },
        })
      end
    end

    for _, segment in ipairs(group.segments) do
      local ya = segment.left.y + segment.left_row
      local yb = segment.right.y + segment.right_row
      if ya == yb then
        table.insert(route(segment.edge).points, {
          { left_x(segment.left), ya },
          { right_x(segment.right), yb },
        })
      end
      if segment.left.box then
        finish(segment.edge, segment.left.box, segment.left_row, true)
      end
      if segment.right.box then
        finish(segment.edge, segment.right.box, segment.right_row, false)
      end
      -- A slot is crossed straight through its layer.
      if not segment.right.box then
        local item = segment.right
        table.insert(route(segment.edge).points, {
          { layer_x[item.layer], item.y },
          { layer_x[item.layer] + layer_w[item.layer] - 1, item.y },
        })
      end
    end

    cursor_y = height + 2
  end

  for _, ids in ipairs(connected) do
    place_group(ids)
  end

  -- Lone tables, packed in rows as wide as the widest group, or a comfortable width.
  local row_width = math.max(widest, 100)
  local x, row_height = margin_x, 0
  for _, ids in ipairs(single) do
    local id = ids[1]
    local box = boxes[id]
    local loops = 0
    for _, edge in ipairs(graph.edges) do
      if edge.child == id and edge.parent == id then
        loops = loops + 1
      end
    end
    local span = box.w + (loops > 0 and (6 + loops * 2) or 0)
    if x > margin_x and x + span > row_width then
      x = margin_x
      cursor_y = cursor_y + row_height + 1
      row_height = 0
    end
    box.x, box.y = x, cursor_y
    local slot = 0
    for _, edge in ipairs(graph.edges) do
      if edge.child == id and edge.parent == id then
        local track = box.x + box.w + 3 + slot * 2
        slot = slot + 1
        local from_row = anchor_row(box, edge.child_columns)
        local to_row = anchor_row(box, edge.parent_columns)
        if from_row == to_row then
          to_row = from_row == 1 and math.min(2, #box.rows) or from_row - 1
        end
        local out_x = box.x + box.w + 2
        table.insert(route(edge).points, {
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
    end
    x = x + span + 3
    widest = math.max(widest, x)
    row_height = math.max(row_height, box.h)
  end
  if #single > 0 then
    cursor_y = cursor_y + row_height + 1
  end

  local order = {}
  for _, node in ipairs(graph.nodes) do
    table.insert(order, node.id)
  end
  table.sort(order, function(a, b)
    local ba, bb = boxes[a], boxes[b]
    if ba.x ~= bb.x then
      return ba.x < bb.x
    end
    if ba.y ~= bb.y then
      return ba.y < bb.y
    end
    return a < b
  end)

  local width, height = 0, 0
  for _, box in pairs(boxes) do
    width = math.max(width, box.x + box.w)
    height = math.max(height, box.y + box.h)
  end
  for _, r in ipairs(routes) do
    for _, line in ipairs(r.points) do
      for _, point in ipairs(line) do
        width = math.max(width, point[1] + 1)
        height = math.max(height, point[2] + 1)
      end
    end
  end

  return {
    width = width + margin_x,
    height = height + 1,
    boxes = boxes,
    order = order,
    routes = routes,
    markers = markers,
    attach = attach,
  }
end

return M
