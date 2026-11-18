-- The diagram's tab, cursor movement and stale replies, with schema reads stubbed out.
---@diagnostic disable: duplicate-set-field
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.helpers')

local erd = require('sqmeow.ui.erd')
local schema = require('sqmeow.core.schema')

local requests

local function pk(name)
  return { name = name, type_name = 'int4', primary_key = true, nullable = false }
end

local function col(name, nullable)
  return { name = name, type_name = 'int4', nullable = nullable == true }
end

local function shop(opts)
  return {
    conn_id = 1,
    connection = 'test',
    dialect = 'postgres',
    schema = 'public',
    relation = opts and opts.relation,
    hops = opts and opts.hops,
    tables = {
      { schema = 'public', relation = 'users', columns = { pk('id'), col('email') } },
      {
        schema = 'public',
        relation = 'orders',
        columns = { pk('id'), col('user_id'), col('coupon_id', true) },
        foreign_keys = {
          { name = 'fk_user', columns = { 'user_id' }, target = 'users', referenced = { 'id' } },
          {
            name = 'fk_coupon',
            columns = { 'coupon_id' },
            target = 'coupons',
            referenced = { 'id' },
          },
        },
      },
      { schema = 'public', relation = 'coupons', columns = { pk('id') } },
    },
  }
end

local original_collect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      requests = {}
      -- Swapped by hand: `helpers.stub` would restore it as soon as this hook returns.
      original_collect = helpers.swap(schema, 'collect', function(opts, callback)
        table.insert(requests, { opts = vim.deepcopy(opts), callback = callback })
        callback(shop(opts))
        return true
      end)
    end,
    post_case = function()
      erd.close()
      schema.collect = original_collect
    end,
  },
})

--- The box and row under the cursor, as `relation` and the column on the row.
local function under_cursor()
  local view = assert(erd.state())
  local line = vim.api.nvim_win_get_cursor(view.win)[1] - 1
  local x = vim.fn.virtcol('.', true)[1] - 1
  for _, id in ipairs(view.drawing.layout.order) do
    local box = view.drawing.layout.boxes[id]
    if x >= box.x and x < box.x + box.w and line >= box.y and line < box.y + box.h then
      local node = view.drawing.graph.nodes[id]
      local row = box.rows[line - box.y]
      return node.relation, row and row.column and node.columns[row.column].name or nil
    end
  end
end

--- Put the cursor on a table's column row, or its title.
local function put(relation, column)
  local view = assert(erd.state())
  for _, node in ipairs(view.drawing.graph.nodes) do
    if node.relation == relation then
      local box = view.drawing.layout.boxes[node.id]
      local row = 0
      for index, info in ipairs(node.columns) do
        if info.name == column then
          row = box.row_of[index]
        end
      end
      local y = box.y + row
      vim.api.nvim_win_set_cursor(view.win, { y + 1, view.drawing.picture.bytes[y][box.x + 4] })
      return
    end
  end
  error('no table ' .. relation)
end

T['opens a tab and draws the schema'] = function()
  local tabs = #vim.api.nvim_list_tabpages()
  local started = erd.open({ conn_id = 1 })
  eq(started, true)
  eq(#vim.api.nvim_list_tabpages(), tabs + 1)
  local view = assert(erd.state())
  eq(vim.api.nvim_get_current_buf(), view.buf)
  eq(vim.bo[view.buf].filetype, 'sqmeow-erd')
  eq(vim.bo[view.buf].modifiable, false)
  eq(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), view.drawing.picture.lines)
  eq(table.concat(view.drawing.picture.lines, '\n'):find('╭─ orders ', 1, true) ~= nil, true)
  eq(vim.wo[view.win].winbar:find('3 tables · 2 keys', 1, true) ~= nil, true)
  eq(requests[1].opts, { conn_id = 1 })
end

T['a table opens its neighbourhood with the configured hops'] = function()
  erd.open({ conn_id = 1, schema = 'public', relation = 'orders' })
  eq(requests[1].opts.hops, require('sqmeow.config').get().ui.erd.hops)
  eq(under_cursor(), 'orders')
end

T['close removes the tab and the buffer'] = function()
  local tabs = #vim.api.nvim_list_tabpages()
  erd.open({ conn_id = 1 })
  local buf = erd.buffer()
  erd.actions.close()
  eq(#vim.api.nvim_list_tabpages(), tabs)
  eq(vim.api.nvim_buf_is_valid(buf), false)
  eq(erd.state(), nil)
end

T['a read that cannot start leaves no tab behind'] = function()
  helpers.stub(schema, 'collect', function()
    return false, 'reading a schema needs an open connection'
  end)
  local tabs = #vim.api.nvim_list_tabpages()
  local started, err = erd.open({ conn_id = 9 })
  eq(started, false)
  eq(err, 'reading a schema needs an open connection')
  eq(#vim.api.nvim_list_tabpages(), tabs)
end

T['a failed read says why in the tab'] = function()
  helpers.stub(schema, 'collect', function(_, callback)
    vim.schedule(function()
      callback(nil, 'table nope not found in public')
    end)
    return true
  end)
  erd.open({ conn_id = 1, relation = 'nope' })
  local view = assert(erd.state())
  helpers.wait_for('the error should show', function()
    return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)):find('nope', 1, true)
      ~= nil
  end)
end

T['next and previous table cycle in reading order'] = function()
  erd.open({ conn_id = 1 })
  local view = assert(erd.state())
  local seen = {}
  for _ = 1, #view.drawing.layout.order do
    erd.actions.next_table()
    table.insert(seen, (under_cursor()))
  end
  table.sort(seen)
  eq(seen, { 'coupons', 'orders', 'users' })
  local here = under_cursor()
  erd.actions.next_table()
  erd.actions.prev_table()
  eq(under_cursor(), here)
end

T['gd follows a foreign key to its parent column'] = function()
  erd.open({ conn_id = 1 })
  put('orders', 'user_id')
  erd.actions.goto_parent()
  eq({ under_cursor() }, { 'users', 'id' })
  -- The jump left a mark to return to.
  vim.cmd('normal! ``')
  eq({ under_cursor() }, { 'orders', 'user_id' })
end

T['gr goes to the table referencing this one'] = function()
  erd.open({ conn_id = 1 })
  put('coupons')
  erd.actions.goto_children()
  eq({ under_cursor() }, { 'orders', 'coupon_id' })
end

T['gd off any key says so'] = function()
  erd.open({ conn_id = 1 })
  put('users', 'email')
  local said
  helpers.stub(vim, 'notify', function(message)
    said = message
  end)
  erd.actions.goto_parent()
  eq(said:find('no foreign key', 1, true) ~= nil, true)
  eq({ under_cursor() }, { 'users', 'email' })
end

T['focus redraws around a table, and back returns'] = function()
  erd.open({ conn_id = 1 })
  put('users')
  erd.actions.focus()
  eq(requests[2].opts, { conn_id = 1, schema = 'public', relation = 'users', hops = 1 })
  eq(erd.state().opts.relation, 'users')
  eq(under_cursor(), 'users')

  erd.actions.more_hops()
  eq(requests[3].opts.hops, 2)
  erd.actions.fewer_hops()
  eq(requests[4].opts.hops, 1)

  erd.actions.back()
  eq(requests[5].opts, { conn_id = 1 })
  eq(erd.state().opts.relation, nil)
end

T['an answer for an older read is dropped'] = function()
  local pending = {}
  erd.open({ conn_id = 1 })
  helpers.stub(schema, 'collect', function(opts, callback)
    table.insert(pending, { opts = opts, callback = callback })
    return true
  end)
  put('users')
  erd.actions.focus()
  erd.actions.refresh()
  eq(#pending, 2)
  -- The later read answers first; the earlier one arriving after must not replace it.
  pending[2].callback(shop({ relation = 'users', hops = 1 }))
  local lines = vim.deepcopy(erd.state().drawing.picture.lines)
  local stale = shop()
  table.remove(stale.tables, 3)
  pending[1].callback(stale)
  eq(erd.state().drawing.picture.lines, lines)
end

T['za and C change which columns show'] = function()
  helpers.stub(require('sqmeow.config').get().ui.erd, 'max_rows', 1)
  erd.open({ conn_id = 1 })
  local view = assert(erd.state())
  local function rows(relation)
    for _, node in ipairs(view.drawing.graph.nodes) do
      if node.relation == relation then
        return #view.drawing.layout.boxes[node.id].rows
      end
    end
  end
  -- `id` is a key and shows; `email` folds into `… 1 more`.
  eq(rows('users'), 2)
  put('users')
  erd.actions.toggle_columns()
  eq(rows('users'), 2)
  eq(view.drawing.layout.boxes[1].hidden, 0)
  eq(under_cursor(), 'users')
  erd.actions.compact()
  eq(view.compact, true)
end

T['a closed connection marks the diagram out of date'] = function()
  erd.open({ conn_id = 1 })
  local view = assert(erd.state())
  erd.invalidate(2)
  eq(view.disconnected, false)
  erd.invalidate(1)
  eq(view.disconnected, true)
  eq(vim.wo[view.win].winbar:find('disconnected', 1, true) ~= nil, true)
end

T['the drawer opens the diagram for the node under the cursor'] = function()
  local drawer = require('sqmeow.ui.drawer')
  local opened = {}
  helpers.stub(erd, 'open', function(opts)
    table.insert(opened, opts)
    return true
  end)
  local node
  helpers.stub(drawer, 'current_node', function()
    return node
  end)

  node = { kind = 'table', conn_id = 3, path = { 'public', 'tables', 'orders' } }
  drawer.actions.diagram()
  node = { kind = 'schema', conn_id = 3, path = { 'public' } }
  drawer.actions.diagram()
  node = { kind = 'tables', conn_id = 3, path = { 'public', 'tables' } }
  drawer.actions.diagram()
  node = { kind = 'connection', conn_id = 3, path = {} }
  drawer.actions.diagram()
  eq(opened, {
    { conn_id = 3, schema = 'public', relation = 'orders' },
    { conn_id = 3, schema = 'public' },
    { conn_id = 3, schema = 'public' },
    { conn_id = 3 },
  })
end

return T
