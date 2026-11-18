local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.helpers')

local export = require('sqmeow.api.export')

local T = MiniTest.new_set()

local function pk(name)
  return { name = name, type_name = 'int4', primary_key = true, nullable = false }
end

local function col(name, nullable)
  return { name = name, type_name = 'int4', nullable = nullable == true }
end

local function render(tables)
  return export.mermaid({ tables = tables })
end

--- The relationship lines of a diagram.
local function edges(text)
  local found = {}
  for line in vim.gsplit(text, '\n') do
    if line:find(' : "', 1, true) then
      table.insert(found, vim.trim(line))
    end
  end
  return found
end

T['mermaid draws cardinality and PK/FK/UK tags'] = function()
  local text = render({
    {
      schema = 'public',
      relation = 'users',
      columns = {
        pk('id'),
        { name = 'email', type_name = 'character varying(255)', nullable = false },
      },
      indexes = { { name = 'users_email_key', columns = { 'email' }, unique = true } },
      foreign_keys = {},
    },
    {
      schema = 'public',
      relation = 'orders',
      columns = { pk('id'), col('user_id'), col('coupon_id', true) },
      indexes = { { name = 'orders_coupon_uq', columns = { 'coupon_id' }, unique = true } },
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
  })

  eq(
    text,
    table.concat({
      'erDiagram',
      '  "users" ||..o{ "orders" : "user_id -> id"',
      '  "coupons" |o..|o "orders" : "coupon_id -> id"',
      '',
      '  "users" {',
      '    int4 id PK',
      '    varchar(255) email UK "NOT NULL"',
      '  }',
      '  "orders" {',
      '    int4 id PK',
      '    int4 user_id FK "NOT NULL -> users.id"',
      '    int4 coupon_id FK, UK "-> coupons.id"',
      '  }',
      '  "coupons" {',
      '    int4 id PK',
      '  }',
    }, '\n')
  )
end

T['mermaid draws a key inside the child primary key as identifying'] = function()
  local text = render({
    { relation = 'orders', columns = { pk('id') } },
    {
      relation = 'order_lines',
      columns = { pk('order_id'), pk('line') },
      foreign_keys = { { columns = { 'order_id' }, target = 'orders', referenced = { 'id' } } },
    },
  })
  eq(edges(text), { '"orders" ||--o{ "order_lines" : "order_id -> id"' })
end

T['mermaid tags UK only for single-column unique keys'] = function()
  local text = render({
    {
      relation = 'members',
      columns = { pk('id'), col('tenant_id'), col('email') },
      indexes = { { name = 'members_uq', columns = { 'tenant_id', 'email' }, unique = true } },
    },
  })
  helpers.absent(text, 'UK')
end

T['mermaid ignores partial unique indexes reported as not unique'] = function()
  local text = render({
    { relation = 'parents', columns = { pk('id') } },
    {
      relation = 'children',
      columns = { pk('id'), col('parent_id') },
      indexes = { { name = 'active_uq', columns = { 'parent_id' }, unique = false } },
      foreign_keys = { { columns = { 'parent_id' }, target = 'parents', referenced = { 'id' } } },
    },
  })
  eq(edges(text), { '"parents" ||..o{ "children" : "parent_id -> id"' })
end

T['mermaid matches quoted index columns and exact column names'] = function()
  local text = render({
    { relation = 'parents', columns = { pk('id') } },
    {
      relation = 'quoted',
      columns = { pk('id'), col('ParentId') },
      indexes = { { name = 'quoted_uq', columns = { '"ParentId"' }, unique = true } },
      foreign_keys = { { columns = { 'ParentId' }, target = 'parents', referenced = { 'id' } } },
    },
    {
      relation = 'cased',
      columns = { pk('Parent_id'), col('parent_id', false), col('other') },
      foreign_keys = { { columns = { 'parent_id' }, target = 'parents', referenced = { 'id' } } },
    },
  })
  eq(edges(text), {
    '"parents" ||..|o "quoted" : "ParentId -> id"',
    '"parents" ||..o{ "cased" : "parent_id -> id"',
  })
  helpers.contains(text, 'int4 ParentId FK, UK')
end

T['mermaid keeps distinct casing and respects qualified targets'] = function()
  local text = render({
    {
      schema = 'public',
      relation = 'Foo',
      columns = { pk('id'), { name = 'amount', type_name = 'numeric(10, 2)' } },
      foreign_keys = {
        { columns = { 'id' }, target = 'archive.foo', referenced = { 'id' } },
        { columns = { 'amount' }, target = 'foo', referenced = { 'id' } },
      },
    },
    { schema = 'public', relation = 'foo', columns = { pk('id') } },
  })

  eq(edges(text), { '"public.foo" |o..o{ "public.Foo" : "amount -> id"' })
  helpers.contains(text, '"public.Foo" {')
  helpers.contains(text, '"public.foo" {')
  helpers.contains(text, 'numeric(10_2) amount')
end

T['mermaid matches schema-less and dotted table names exactly'] = function()
  local text = render({
    { relation = 'Foo', columns = { pk('id') } },
    { relation = 'foo', columns = { pk('id') } },
    { schema = 'main', relation = 'sales.eu', columns = { pk('id') } },
    {
      schema = 'main',
      relation = 'child',
      columns = { pk('id'), col('eu_id') },
      foreign_keys = { { columns = { 'eu_id' }, target = 'sales.eu', referenced = { 'id' } } },
    },
    {
      relation = 'bar',
      columns = { pk('id'), col('foo_id') },
      foreign_keys = { { columns = { 'foo_id' }, target = 'foo', referenced = { 'id' } } },
    },
  })
  eq(edges(text), {
    '"main.sales.eu" ||..o{ "main.child" : "eu_id -> id"',
    '"foo" ||..o{ "bar" : "foo_id -> id"',
  })
end

T['mermaid escapes names Mermaid would misread'] = function()
  local text = render({
    {
      relation = 'end',
      columns = {
        pk('fk'),
        col('line item'),
        col('line_item'),
        col('ref'),
      },
      foreign_keys = { { columns = { 'ref' }, target = 'my"parent', referenced = { 'id' } } },
    },
    { relation = 'ab', columns = { pk('id') } },
    { relation = 'a"b', columns = { pk('id') } },
  })
  helpers.contains(text, '  "end" {')
  helpers.contains(text, '    int4 fk_ PK')
  helpers.contains(text, '    int4 line_item "NOT NULL"')
  helpers.contains(text, '    int4 line_item_2 "NOT NULL"')
  helpers.contains(text, [["NOT NULL -> my'parent.id"]])
  helpers.contains(text, '  "ab" {')
  helpers.contains(text, [[  "a'b" {]])
end

T['mermaid writes the diagram to a file'] = function()
  local path = vim.fn.tempname() .. '.mmd'
  local text = export.mermaid({ tables = { { relation = 't', columns = { pk('id') } } } }, {
    path = path,
  })
  eq(vim.fn.readfile(path), vim.split(text, '\n'))
  vim.fn.delete(path)
end

T['mermaid says where a copy went without a clipboard provider'] = function()
  local messages = {}
  helpers.stub(vim, 'notify', function(message, level)
    table.insert(messages, { message, level })
  end)
  local has = vim.fn.has
  helpers.stub(vim.fn, 'has', function(feature)
    if feature == 'clipboard' then
      return 0
    end
    return has(feature)
  end)
  local text = export.mermaid({ tables = { { relation = 't', columns = { pk('id') } } } }, {
    clipboard = true,
  })
  eq(vim.fn.getreg('"'), text)
  eq(messages[1][2], vim.log.levels.WARN)
  helpers.contains(messages[1][1], 'unnamed register')
end

return T
