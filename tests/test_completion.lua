local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local completion = require('sqmeow.completion')
local drawer = require('sqmeow.ui.drawer')
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc.client')
local helpers = dofile('tests/helpers.lua')
local connection, calls, buf, target, request

local function cache(path, nodes, id)
  drawer.on_nodes({ conn_id = id or 1, path = path, nodes = nodes })
end

local function fixture(schema)
  cache({}, {
    { name = schema, kind = 'schema' },
    { name = 'Roles', key = '@roles', kind = 'roles' },
  })
  cache({ schema }, {
    { name = 'Tables', key = 'tables', kind = 'tables' },
    { name = 'Views', key = 'views', kind = 'views' },
  })
  cache({ schema, 'tables' }, {
    { name = 'users', kind = 'table', expandable = true },
    { name = 'orders', kind = 'table', expandable = true },
  })
  cache({ schema, 'views' }, { { name = 'summary', kind = 'view', expandable = true } })
end

local function columns(schema, relation)
  cache({ schema, relation == 'summary' and 'views' or 'tables', relation }, {
    { name = relation .. '_id', kind = 'column', type_name = 'integer', primary_key = true },
    { name = 'owner', kind = 'column', type_name = 'integer', references = 'accounts.id' },
  })
end

local function flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(vim.wait(1000, function()
    return done
  end))
end

local function items(sql, col, row)
  local found, incomplete = completion.items(buf, sql, col or #sql, row)
  flush()
  return found, incomplete
end

local function column_labels(found)
  local labels = {}
  for _, item in ipairs(found) do
    if item.kind == 'column' then
      table.insert(labels, item.label)
    end
  end
  return labels
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      drawer.reset()
      calls = {}
      connection = { id = 1 }
      target = helpers.swap(api, 'target', function()
        return connection
      end)
      request = helpers.swap(rpc, 'request', function(method, params)
        eq(method, 'introspect')
        table.insert(calls, vim.deepcopy(params))
        return true
      end)
      buf = vim.api.nvim_create_buf(false, true)
    end,
    post_case = function()
      helpers.swap(api, 'target', target)
      flush()
      helpers.swap(rpc, 'request', request)
      vim.api.nvim_buf_delete(buf, { force = true })
      drawer.reset()
    end,
  },
})

T['no active connection'] = function()
  connection = nil
  eq(items('SELECT '), {})
  eq(calls, {})
end

T['disconnect cancels queued metadata loads'] = function()
  completion.ensure(1)
  drawer.forget(1)
  flush()
  eq(calls, {})
end

T['loads metadata in stages and deduplicates pending requests'] = function()
  local _, incomplete = items('SELECT * FROM users WHERE ')
  eq(incomplete, true)
  items('SELECT * FROM users WHERE ')
  eq(#calls, 1)
  eq(calls[1].path, {})
  cache({}, { { name = 'main', kind = 'schema' } })
  items('SELECT * FROM users WHERE ')
  eq(calls[2].path, { 'main' })
  fixture('main')
  items('SELECT * FROM users WHERE ')
  items('SELECT * FROM users WHERE ')
  eq(#calls, 3)
  eq(calls[3].path, { 'main', 'tables', 'users' })
  columns('main', 'users')
  local found
  found, incomplete = items('SELECT * FROM users WHERE ')
  eq(column_labels(found), { 'users_id', 'owner' })
  eq(incomplete, false)
end

T['unqualified columns in SQL clauses'] = MiniTest.new_set({
  parametrize = {
    { 'SELECT * FROM users WHERE ' },
    { 'SELECT * FROM users GROUP BY ' },
    { 'SELECT * FROM users ORDER BY ' },
    { 'SELECT * FROM users HAVING ' },
    { 'UPDATE users SET ' },
    { 'INSERT INTO users (' },
    { 'DELETE FROM users WHERE ' },
  },
})
T['unqualified columns in SQL clauses']['loads only the referenced relation'] = function(sql)
  fixture('main')
  items(sql)
  eq(#calls, 1)
  eq(calls[1].path, { 'main', 'tables', 'users' })
  columns('main', 'users')
  eq(column_labels(items(sql)), { 'users_id', 'owner' })
end

T['aliases and quoted identifiers across adapters'] = MiniTest.new_set({
  parametrize = {
    { 'public', 'SELECT * FROM "public"."users" AS "u" WHERE "u".' },
    { 'app', 'SELECT * FROM `app`.`users` u GROUP BY u.' },
    { 'dbo', 'SELECT * FROM [dbo].[users] AS [u] ORDER BY [u].' },
    { 'main', 'select * from users u where u.us' },
    { 'APP', 'SELECT * FROM APP.USERS U WHERE U.' },
  },
})
T['aliases and quoted identifiers across adapters']['returns the aliased columns'] = function(
  schema,
  sql
)
  fixture(schema)
  columns(schema, 'users')
  columns(schema, 'orders')
  eq(column_labels(items(sql)), { 'users_id', 'owner' })
  eq(#items(sql), 2)
end

T['multiline SELECT sees FROM after cursor'] = function()
  fixture('main')
  columns('main', 'users')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'SELECT us', 'FROM users', 'WHERE owner = 1' })
  eq(column_labels(items('SELECT us', 9, 1)), { 'users_id', 'owner' })
  eq(column_labels(items('WHERE ', 6, 3)), { 'users_id', 'owner' })
end

T['buffer parser tracks edits without retaining old aliases'] = function()
  fixture('main')
  columns('main', 'users')
  columns('main', 'orders')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'SELECT * FROM users u', 'WHERE u.' })
  eq(column_labels(items('WHERE u.', 8, 2)), { 'users_id', 'owner' })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'SELECT * FROM orders o', 'WHERE o.' })
  eq(column_labels(items('WHERE o.', 8, 2)), { 'orders_id', 'owner' })
  eq(column_labels(items('WHERE u.', 8, 2)), {})
end

T['Tree-sitter statement boundaries work on the same line'] = function()
  fixture('main')
  columns('main', 'users')
  columns('main', 'orders')
  local first = 'SELECT * FROM users WHERE users_id = 1'
  local sql = first .. '; SELECT * FROM orders WHERE '
  eq(column_labels(items(sql, #first)), { 'users_id', 'owner' })
  eq(column_labels(items(sql)), { 'orders_id', 'owner' })
end

T['missing SQL parser keeps metadata and explicit table completion usable'] = function()
  fixture('main')
  columns('main', 'users')
  helpers.stub(vim.treesitter, 'get_parser', function()
    return nil
  end)
  eq(column_labels(items('SELECT * FROM users WHERE ', 26, 1)), {})
  eq(#items('SELECT ', 7, 1), 4)
  eq(column_labels(items('users.', 6, 1)), { 'users_id', 'owner' })
end

T['joins and comma lists offer both tables but qualifiers narrow them'] = function()
  fixture('main')
  columns('main', 'users')
  columns('main', 'orders')
  for _, from in ipairs({ 'users u JOIN orders o ON u.users_id = o.owner', 'users u, orders o' }) do
    eq(
      column_labels(items('SELECT * FROM ' .. from .. ' WHERE ')),
      { 'users_id', 'owner', 'orders_id', 'owner' }
    )
    eq(column_labels(items('SELECT * FROM ' .. from .. ' WHERE o.')), { 'orders_id', 'owner' })
  end
end

T['comments strings and other statements do not leak relations'] = function()
  fixture('main')
  columns('main', 'users')
  columns('main', 'orders')
  local sql = "SELECT * FROM orders; SELECT 'FROM orders; ' FROM users /* JOIN orders */ WHERE "
  eq(column_labels(items(sql)), { 'users_id', 'owner' })
  eq(column_labels(items('SELECT * FROM users -- JOIN orders\nWHERE ')), { 'users_id', 'owner' })
end

T['views carry column types and key documentation'] = function()
  fixture('main')
  columns('main', 'summary')
  local found = items('summary.')
  eq(found[1].detail, 'integer')
  eq(found[1].documentation, 'Primary Key')
  eq(found[2].documentation, 'Foreign Key: accounts.id')
end

T['schema qualifier lists relations'] = function()
  fixture('main')
  local found = items('SELECT * FROM main.')
  eq(
    vim.tbl_map(function(item)
      return item.label
    end, found),
    { 'users', 'orders', 'summary' }
  )
  eq(calls, {})
end

T['explicit schemas disambiguate identically named tables'] = function()
  fixture('main')
  columns('main', 'users')
  cache({}, { { name = 'main', kind = 'schema' }, { name = 'other', kind = 'schema' } })
  cache({ 'other' }, { { key = 'tables', kind = 'tables' } })
  cache({ 'other', 'tables' }, { { name = 'users', kind = 'table' } })
  cache({ 'other', 'tables', 'users' }, { { name = 'other_id', kind = 'column' } })
  eq(column_labels(items('SELECT * FROM other.users WHERE users.')), { 'other_id' })
  eq(column_labels(items('SELECT * FROM other.users u WHERE u.')), { 'other_id' })
  eq(column_labels(items('other.users.')), { 'other_id' })
end

T['non SQL metadata uses adapter group keys and skips leaf columns'] = function()
  cache({}, { { name = '0', kind = 'schema' } })
  cache({ '0' }, { { name = 'Hashes', key = 'hashes', kind = 'keys' } })
  cache({ '0', 'hashes' }, { { name = 'users', kind = 'key', expandable = false } })
  eq(items('HGET '), {
    { label = '0', kind = 'schema', detail = 'schema' },
    { label = 'users', kind = 'key', detail = 'key', schema = '0' },
  })
  eq(items('users.'), {})
  eq(calls, {})
end

T['cluster roots and role headings are not introspected as schemas'] = function()
  cache({}, { { name = 'db', kind = 'database' }, { name = 'Roles', kind = 'roles' } })
  eq(items(''), {})
  eq(calls, {})
end

T['empty caches stay loaded and connections are isolated'] = function()
  fixture('main')
  columns('main', 'users')
  cache({ 'main', 'tables', 'users' }, {})
  eq(column_labels(items('users.')), {})
  eq(calls, {})
  connection = { id = 2 }
  eq(items('users.'), {})
  eq(calls[1].conn_id, 2)
  drawer.forget(1)
  connection = { id = 1 }
  eq(items('users.'), {})
  eq(calls[2].path, {})
end

T['providers'] = MiniTest.new_set({ parametrize = { { 'cmp' }, { 'blink' } } })
T['providers']['normalize cursors and expose pending metadata'] = function(provider)
  local module = provider == 'cmp' and 'cmp.types' or 'blink.cmp.types'
  local saved = package.loaded[module]
  local kinds = { Module = 9, Class = 7, Interface = 8, Field = 5, Property = 10 }
  package.loaded[module] = provider == 'cmp' and { lsp = { CompletionItemKind = kinds } }
    or { CompletionItemKind = kinds }
  local ok, err = pcall(function()
    fixture('main')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'SELECT * FROM users u', 'WHERE u.owner' })
    local source = require('sqmeow.completion.' .. provider).new()
    local response
    local function run()
      local callback = function(result)
        response = result
      end
      if provider == 'cmp' then
        source:complete({
          context = { bufnr = buf, cursor_line = 'WHERE u.owner', cursor = { row = 2, col = 9 } },
        }, callback)
      else
        source:get_completions({ bufnr = buf, line = 'WHERE u.owner', cursor = { 2, 8 } }, callback)
      end
    end
    run()
    eq(provider == 'cmp' and response.isIncomplete or response.is_incomplete_forward, true)
    columns('main', 'users')
    run()
    eq(#response.items, 2)
    eq(response.items[1].kind, kinds.Field)
    eq(response.items[1].documentation, { kind = 'markdown', value = 'Primary Key' })
    if provider == 'cmp' then
      eq(response.isIncomplete, false)
    else
      eq(response.is_incomplete_forward, false)
      eq(response.is_incomplete_backward, false)
    end
  end)
  package.loaded[module] = saved
  assert(ok, err)
end

return T
