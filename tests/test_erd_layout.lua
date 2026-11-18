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
  return kind == 'primary_key' and '#' or '>'
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
  -- `orders` rises so the key from `users.id` runs straight; `coupons` waits below.
  eq(lines, {
    '',
    '                                    ╭─ orders ──────────╮',
    '  ╭─ users ───────────────╮         │ # id         int4 │',
    '  │ # id     int4         ├┼┼─────○<┤ > user_id    int4 │',
    '  │   email  varchar(255) │   ╭───○┼┤ > coupon_id  int4 │',
    '  ╰───────────────────────╯   │     ╰───────────────────╯',
    '                              │',
    '  ╭─ coupons ──╮              │',
    '  │ # id  int4 ├┼○────────────╯',
    '  ╰────────────╯',
    '',
  })
end

T['parents sit left of their children'] = function()
  local tables = shop()
  local placed, _, graph = draw(tables)
  local users, orders = box_of(placed, graph, 'users'), box_of(placed, graph, 'orders')
  local coupons = box_of(placed, graph, 'coupons')
  eq(users.x < orders.x, true)
  eq(coupons.x < orders.x, true)
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
  eq(#wide.rows, 6)
  eq(wide.hidden, 17)
  eq(wide.row_of[22] ~= nil, true)
  eq(lines[wide.y + wide.h - 1]:find('… 17 more', 1, true) ~= nil, true)

  local expanded = draw(tables, { max_rows = 5, expanded = { [2] = true } })
  eq(#box_of(expanded, graph, 'wide').rows, 22)

  local compact = draw(tables, { compact = true })
  eq(#box_of(compact, graph, 'wide').rows, 3)
end

T['tables with no keys are packed below the others'] = function()
  local tables = shop()
  table.insert(tables, { relation = 'settings', columns = { col('key', false, 'text') } })
  local placed, _, graph = draw(tables)
  local settings = box_of(placed, graph, 'settings')
  for _, name in ipairs({ 'users', 'orders', 'coupons' }) do
    local other = box_of(placed, graph, name)
    eq(settings.y >= other.y + other.h, true)
  end
end

T['tracks in a gap never share a column'] = function()
  local tables = { { relation = 'hub', columns = { pk('id'), pk('code') } } }
  for i = 1, 6 do
    table.insert(tables, {
      relation = 'leaf' .. i,
      columns = { pk('id'), col('x'), col('hub_id') },
      foreign_keys = { fk({ 'hub_id' }, 'hub') },
    })
  end
  local placed = draw(tables)
  local seen = {}
  for _, route in ipairs(placed.routes) do
    for _, points in ipairs(route.points) do
      if #points == 4 then
        local x = points[2][1]
        local span = { math.min(points[2][2], points[3][2]), math.max(points[2][2], points[3][2]) }
        for _, other in ipairs(seen[x] or {}) do
          -- A shared track is only the bus out of the same row.
          eq(other[1] > span[2] or other[2] < span[1] or other[3] == points[1][2], true)
        end
        seen[x] = seen[x] or {}
        table.insert(seen[x], { span[1], span[2], points[1][2] })
      end
    end
  end
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
