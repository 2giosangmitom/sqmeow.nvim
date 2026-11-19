local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local model = require('sqmeow.core.erd.model')
local layout = require('sqmeow.core.erd.layout')
local canvas = require('sqmeow.core.erd.canvas')

local T = MiniTest.new_set()

local function pk(name)
  return { name = name, type_name = 'int4', primary_key = true, nullable = false }
end

local function col(name, nullable, type_name)
  return { name = name, type_name = type_name or 'int4', nullable = nullable == true }
end

local function fk(columns, target, referenced)
  return {
    name = 'fk_' .. columns[1],
    columns = columns,
    target = target,
    referenced = referenced or { 'id' },
  }
end

local icons = function(kind)
  if kind == 'primary_key' then
    return '#'
  end
  return kind == 'foreign_key' and '>' or ' '
end

--- Lay out and draw tables, answering the layout and the drawn lines.
local function draw(tables, opts)
  local graph = model.graph({ tables = tables })
  local placed = layout.layout(graph, vim.tbl_extend('keep', opts or {}, { icon = icons }))
  local picture = canvas.draw(placed)
  return placed, picture.lines, graph
end

local function box_of(placed, graph, relation)
  for _, node in ipairs(graph.nodes) do
    if node.relation == relation then
      return placed.boxes[node.id]
    end
  end
end

local function shop()
  return {
    {
      schema = 'public',
      relation = 'users',
      columns = { pk('id'), col('email', false, 'character varying(255)') },
      indexes = { { name = 'users_email_key', columns = { 'email' }, unique = true } },
    },
    {
      schema = 'public',
      relation = 'orders',
      columns = { pk('id'), col('user_id'), col('coupon_id', true) },
      indexes = { { name = 'orders_coupon_uq', columns = { 'coupon_id' }, unique = true } },
      foreign_keys = { fk({ 'user_id' }, 'users'), fk({ 'coupon_id' }, 'coupons') },
    },
    { schema = 'public', relation = 'coupons', columns = { pk('id') } },
  }
end

T['the graph keeps keys, short types and cardinality'] = function()
  local graph = model.graph({ tables = shop() })
  eq(#graph.nodes, 3)
  eq(graph.nodes[1].columns[2].type, 'varchar(255)')
  eq(graph.nodes[1].columns[2].uk, true)
  eq(graph.nodes[2].columns[2].fk, true)
  eq(graph.nodes[2].columns[2].references, 'users.id')
  eq(#graph.edges, 2)
  local to_users, to_coupons = graph.edges[1], graph.edges[2]
  eq({ to_users.child, to_users.parent, to_users.child_columns, to_users.parent_columns }, {
    2,
    1,
    { 2 },
    { 1 },
  })
  eq({ to_users.optional, to_users.unique, to_users.identifying }, { false, false, false })
  eq({ to_coupons.optional, to_coupons.unique }, { true, true })
end

T['short types keep their arguments and case'] = function()
  eq(model.short_type('character varying(64)'), 'varchar(64)')
  eq(model.short_type('TIMESTAMP WITH TIME ZONE'), 'timestamptz')
  eq(model.short_type('numeric(10,2)'), 'numeric(10,2)')
  eq(model.short_type(nil), '')
end

T['a small schema draws as expected'] = function()
  local _, lines = draw(shop())
  -- `orders` sits between the two tables it references, both lines straight.
  eq(lines, {
    '',
    '                         ╭─ orders ──────────╮',
    '                         │ # id         int4 │         ╭─ users ───────────────╮',
    '  ╭─ coupons ──╮         │ > user_id    int4 ├>○─────┼┼┤ # id     int4         │',
    '  │ # id  int4 ├┼○─────○┼┤ > coupon_id  int4 │         │   email  varchar(255) │',
    '  ╰────────────╯         ╰───────────────────╯         ╰───────────────────────╯',
    '',
  })
end

T['tables joined by a key sit in neighbouring columns'] = function()
  local placed, _, graph = draw(shop())
  local columns = {}
  for _, box in pairs(placed.boxes) do
    columns[box.x] = true
  end
  local xs = vim.tbl_keys(columns)
  table.sort(xs)
  local index = {}
  for i, x in ipairs(xs) do
    index[x] = i
  end
  for _, edge in ipairs(graph.edges) do
    local a, b = placed.boxes[edge.parent], placed.boxes[edge.child]
    eq(math.abs(index[a.x] - index[b.x]), 1)
  end
end

T['a cycle still lays out, one table per column'] = function()
  local placed, lines, graph = draw({
    { relation = 'a', columns = { pk('id'), col('b_id') }, foreign_keys = { fk({ 'b_id' }, 'b') } },
    { relation = 'b', columns = { pk('id'), col('a_id') }, foreign_keys = { fk({ 'a_id' }, 'a') } },
  })
  local a, b = box_of(placed, graph, 'a'), box_of(placed, graph, 'b')
  eq(a.x ~= b.x, true)
  -- Both keys are drawn: two `<` ends, one on each side.
  local text = table.concat(lines, '\n')
  eq(select(2, text:gsub('<', '')) + select(2, text:gsub('>', '')) >= 2, true)
end

T['a self-reference loops beside its own table'] = function()
  local placed, lines, graph = draw({
    {
      relation = 'categories',
      columns = { pk('id'), col('parent_id', true), col('name', false, 'text') },
      foreign_keys = { fk({ 'parent_id' }, 'categories') },
    },
  })
  local box = box_of(placed, graph, 'categories')
  local right = box.x + box.w
  -- The loop leaves the id row and returns to the parent_id row on the right.
  eq(vim.fn.strcharpart(lines[box.y + 2], right - 1, 4), '├┼○─')
  eq(vim.fn.strcharpart(lines[box.y + 3], right - 1, 4), '├>○─')
  eq(#graph.edges, 1)
end

T['an edge across two layers passes through the layer between'] = function()
  local placed, lines, graph = draw({
    { relation = 'a', columns = { pk('id') } },
    { relation = 'b', columns = { pk('id'), col('a_id') }, foreign_keys = { fk({ 'a_id' }, 'a') } },
    {
      relation = 'c',
      columns = { pk('id'), col('b_id'), col('a_id') },
      foreign_keys = { fk({ 'b_id' }, 'b'), fk({ 'a_id' }, 'a') },
    },
  })
  local a, b, c = box_of(placed, graph, 'a'), box_of(placed, graph, 'b'), box_of(placed, graph, 'c')
  eq(a.x < b.x and b.x < c.x, true)
  -- Nothing is drawn over the middle table's interior.
  for y = b.y + 1, b.y + b.h - 2 do
    local inside = vim.fn.strcharpart(lines[y + 1], b.x + 1, b.w - 2)
    eq(inside:find('[─│┼]') == nil, true)
  end
end

T['folded columns keep the keys an edge needs'] = function()
  local columns = { pk('id') }
  for i = 1, 20 do
    table.insert(columns, col('c' .. i))
  end
  table.insert(columns, col('owner_id'))
  local tables = {
    { relation = 'owners', columns = { pk('id') } },
    { relation = 'wide', columns = columns, foreign_keys = { fk({ 'owner_id' }, 'owners') } },
  }
  local placed, lines, graph = draw(tables, { max_rows = 5 })
  local wide = box_of(placed, graph, 'wide')
  eq(#wide.rows, 5)
  eq(wide.hidden, 17)
  eq(wide.row_of[22] ~= nil, true)
  -- The count sits in the bottom border, costing no row.
  eq(wide.footer, '… 17 more')
  eq(lines[wide.y + wide.h]:find('╰─ … 17 more ─', 1, true) ~= nil, true)

  local expanded = draw(tables, { max_rows = 5, expanded = { [2] = true } })
  eq(#box_of(expanded, graph, 'wide').rows, 22)

  local compact = draw(tables, { compact = true })
  eq(#box_of(compact, graph, 'wide').rows, 2)
end

T['tables with no keys fill space beside the others'] = function()
  local tables = shop()
  local alone = draw(tables)
  table.insert(tables, { relation = 'settings', columns = { col('key', false, 'text') } })
  local placed, _, graph = draw(tables)
  local settings = box_of(placed, graph, 'settings')
  -- Beside the group, not in a row of its own below it.
  eq(placed.height, alone.height)
  for _, name in ipairs({ 'users', 'orders', 'coupons' }) do
    eq(settings.x >= box_of(placed, graph, name).x + box_of(placed, graph, name).w, true)
  end
end

T['bundles share a track only where they never meet'] = function()
  local tables = { { relation = 'hub', columns = { pk('id'), pk('code') } } }
  for i = 1, 6 do
    table.insert(tables, {
      relation = 'leaf' .. i,
      columns = { pk('id'), col('x'), col('hub_id') },
      foreign_keys = { fk({ 'hub_id' }, 'hub') },
    })
    table.insert(tables, {
      relation = 'twig' .. i,
      columns = { pk('id'), col('leaf_id') },
      foreign_keys = { fk({ 'leaf_id' }, 'leaf' .. i) },
    })
  end
  local placed = draw(tables)
  local seen = {}
  for _, route in ipairs(placed.routes) do
    for _, points in ipairs(route.points) do
      if #points == 4 then
        local x = points[2][1]
        local low = math.min(points[2][2], points[3][2])
        local high = math.max(points[2][2], points[3][2])
        for _, other in ipairs(seen[x] or {}) do
          -- One bundle's lines share its trunk; another bundle's keep a row apart.
          eq(
            other.parent == route.edge.parent or other.low > high + 1 or other.high < low - 1,
            true
          )
        end
        seen[x] = seen[x] or {}
        table.insert(seen[x], { low = low, high = high, parent = route.edge.parent })
      end
    end
  end
end

T['keys from one column share a single track'] = function()
  local tables = { { relation = 'hub', columns = { pk('id') } } }
  for i = 1, 6 do
    table.insert(tables, {
      relation = 'leaf' .. i,
      columns = { pk('id'), col('hub_id') },
      foreign_keys = { fk({ 'hub_id' }, 'hub') },
    })
  end
  local placed, lines, graph = draw(tables)
  local hub = box_of(placed, graph, 'hub')
  -- At most one trunk on each side of the hub.
  local right, left = {}, {}
  for _, route in ipairs(placed.routes) do
    for _, points in ipairs(route.points) do
      if #points == 4 and points[1][1] == hub.x + hub.w + 2 then
        right[points[2][1]] = true
      elseif #points == 4 and points[4][1] == hub.x - 3 then
        left[points[2][1]] = true
      end
    end
  end
  eq(vim.tbl_count(right) <= 1 and vim.tbl_count(left) <= 1, true)
  -- No comb of parallel lines beside the hub.
  eq(table.concat(lines, '\n'):find('┬┬', 1, true), nil)
end

T["a hub's tables spread over columns both sides of it"] = function()
  local tables = { { relation = 'hub', columns = { pk('id') } } }
  for i = 1, 30 do
    table.insert(tables, {
      relation = 'leaf' .. i,
      columns = { pk('id'), col('hub_id'), col('a'), col('b'), col('c') },
      foreign_keys = { fk({ 'hub_id' }, 'hub') },
    })
  end
  local placed, _, graph = draw(tables)
  local hub = box_of(placed, graph, 'hub')
  local columns, left, right = {}, 0, 0
  for i = 1, 30 do
    local leaf = box_of(placed, graph, 'leaf' .. i)
    columns[leaf.x] = true
    if leaf.x < hub.x then
      left = left + 1
    else
      right = right + 1
    end
  end
  eq(vim.tbl_count(columns) >= 4, true)
  eq(left > 0 and right > 0, true)
  -- Wider than tall, in terminal cells.
  eq(placed.width > 2 * placed.height, true)
end

T['columns take the icon of their key or type class'] = function()
  local graph = model.graph({
    tables = {
      {
        relation = 't',
        columns = {
          { name = 'id', type_name = 'int4', class = 'number', primary_key = true },
          { name = 'name', type_name = 'text', class = 'text' },
          { name = 'other', type_name = 'mystery' },
        },
      },
    },
  })
  local placed = layout.layout(graph, {
    icon = function(kind)
      return ({ primary_key = 'P', text = 'T', unknown = 'U' })[kind] or '?'
    end,
  })
  local box = placed.boxes[1]
  local drawn = vim.tbl_map(function(row)
    return { row.pieces[1].text, row.pieces[1].role }
  end, box.rows)
  eq(drawn, { { 'P', 'icon:primary_key' }, { 'T', 'icon:text' }, { 'U', 'icon:unknown' } })
end

T['the overview draws each table as one line'] = function()
  local _, lines = draw(shop(), { overview = true, caps = { left = '(', right = ')' } })
  eq(lines, {
    '',
    '  ( coupons )┼○─────○┼( orders )>○─────┼┼( users )',
    '',
  })
end

T['the overview marks a self-reference instead of looping'] = function()
  local placed, lines = draw({
    {
      relation = 'categories',
      columns = { pk('id'), col('parent_id', true) },
      foreign_keys = { fk({ 'parent_id' }, 'categories') },
    },
  }, { overview = true })
  eq(placed.boxes[1].h, 1)
  eq(vim.trim(lines[2]), 'categories ↻')
  eq(#placed.routes, 0)
end

T['a table opened with za keeps its columns in the overview'] = function()
  local placed = draw(shop(), { overview = true, expanded = { [2] = true } })
  eq(placed.boxes[1].label, true)
  eq(placed.boxes[2].label, nil)
  eq(#placed.boxes[2].rows, 3)
end

--- Pairs of edges sharing a stretch of line without sharing a table: a reader could not tell
--- which table such a line leads to. Crossings share a single cell and are fine, as do lines
--- that meet at a table both reach.
local function ambiguous(tables, opts)
  local graph = model.graph({ tables = tables })
  local placed = layout.layout(graph, vim.tbl_extend('keep', opts or {}, { icon = icons }))
  local _, drawn = canvas.draw(placed)
  local owners = {}
  for _, edge in ipairs(graph.edges) do
    for _, cell in ipairs(drawn.cells['edge:' .. edge.id] or {}) do
      local key = cell[1] .. ':' .. cell[2]
      owners[key] = owners[key] or {}
      owners[key][edge.id] = true
    end
  end
  local found = {}
  for key, here in pairs(owners) do
    local y, x = key:match('(%d+):(%d+)')
    local next_cell = owners[y .. ':' .. (tonumber(x) + 1)] or {}
    for a in pairs(here) do
      for b in pairs(here) do
        local ea, eb = graph.edges[a], graph.edges[b]
        if
          a < b
          and next_cell[a]
          and next_cell[b]
          and ea.parent ~= eb.parent
          and ea.child ~= eb.child
          and ea.parent ~= eb.child
          and ea.child ~= eb.parent
        then
          table.insert(found, ea.label .. ' / ' .. eb.label)
        end
      end
    end
  end
  return found
end

T['lines that must cross each other twice step aside instead of merging'] = function()
  -- In this order `orders` lines up with `categories` and `products` with `users`: each
  -- bundle leaves at the row the other arrives at.
  local tables = {
    {
      relation = 'categories',
      columns = { pk('id'), col('parent_id', true) },
      foreign_keys = { fk({ 'parent_id' }, 'categories') },
    },
    { relation = 'coupons', columns = { pk('id'), col('code') } },
    {
      relation = 'order_items',
      columns = { pk('order_id'), pk('product_id') },
      foreign_keys = { fk({ 'order_id' }, 'orders'), fk({ 'product_id' }, 'products') },
    },
    {
      relation = 'orders',
      columns = { pk('id'), col('user_id'), col('coupon_id', true) },
      foreign_keys = { fk({ 'user_id' }, 'users'), fk({ 'coupon_id' }, 'coupons') },
    },
    {
      relation = 'products',
      columns = { pk('id'), col('category_id') },
      foreign_keys = { fk({ 'category_id' }, 'categories') },
    },
    {
      relation = 'reviews',
      columns = { pk('id'), col('user_id'), col('product_id') },
      foreign_keys = { fk({ 'user_id' }, 'users'), fk({ 'product_id' }, 'products') },
    },
    { relation = 'users', columns = { pk('id'), col('email') } },
  }
  eq(ambiguous(tables, { overview = true }), {})
  eq(ambiguous(tables), {})
  eq(ambiguous(tables, { compact = true }), {})
end

T['canvas joins lines into the right glyphs'] = function()
  local c = canvas.new(5, 5)
  c:line(0, 2, 4, 2)
  c:line(2, 0, 2, 4)
  c:line(0, 0, 0, 4)
  c:line(4, 2, 4, 4)
  local lines = c:render().lines
  eq(lines, { '│ │', '│ │', '├─┼─╮', '│ │ │', '│ │ │' })
  -- Corners are rounded.
  local corner = canvas.new(3, 3)
  corner:line(0, 0, 2, 0)
  corner:line(2, 0, 2, 2)
  eq(corner:render().lines, { '──╮', '  │', '  │' })
end

T['canvas keeps wide characters to their width'] = function()
  local c = canvas.new(0, 0)
  c:box(0, 0, 10, 3, '表名', 'box')
  local picture = c:render()
  eq(picture.lines[1], '╭─ 表名 ─╮')
  eq(vim.api.nvim_strwidth(picture.lines[1]), 10)
  -- The cell after a wide character starts where the character ends.
  eq(picture.bytes[0][5], picture.bytes[0][4] + #'表')
end

T['dashed lines only when asked'] = function()
  local _, solid = draw(shop())
  eq(table.concat(solid):find('┄', 1, true), nil)
  local _, dashed = draw(shop(), { dashed = true })
  eq(table.concat(dashed):find('┄', 1, true) ~= nil, true)
end

T['fit cuts by display width'] = function()
  eq(layout.fit('abcdef', 4), 'abc…')
  eq(layout.fit('abc', 4), 'abc')
  eq(vim.api.nvim_strwidth(layout.fit('表表表表', 5)), 5)
end

return T
