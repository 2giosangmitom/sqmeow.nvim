local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local export = require('sqmeow.api.export')

local T = MiniTest.new_set()

local function pk(name)
  return { name = name, type_name = 'int4', primary_key = true, nullable = false }
end

T['mermaid draws cardinality and PK/FK/UK tags'] = function()
  local text = export.mermaid({
    tables = {
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
        columns = {
          pk('id'),
          { name = 'user_id', type_name = 'int4', nullable = false },
          { name = 'coupon_id', type_name = 'int4', nullable = true },
        },
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
    },
  })

  eq(
    text,
    table.concat({
      'erDiagram',
      '  users ||--o{ orders : "user_id -> id"',
      '  coupons |o--|o orders : "coupon_id -> id"',
      '',
      '  users {',
      '    int4 id PK',
      '    varchar(255) email UK "NOT NULL"',
      '  }',
      '  orders {',
      '    int4 id PK',
      '    int4 user_id FK "NOT NULL -> users.id"',
      '    int4 coupon_id FK, UK "-> coupons.id"',
      '  }',
      '  coupons {',
      '    int4 id PK',
      '  }',
    }, '\n')
  )
end

T['mermaid keeps distinct casing and respects qualified targets'] = function()
  local text = export.mermaid({
    tables = {
      {
        schema = 'public',
        relation = 'Foo',
        columns = { pk('id'), { name = 'amount', type_name = 'numeric(10, 2)' } },
        foreign_keys = {
          { columns = { 'id' }, target = 'archive.foo', referenced = { 'id' } },
        },
      },
      { schema = 'public', relation = 'foo', columns = { pk('id') } },
    },
  })

  eq(text:find('--', 1, true), nil)
  eq(text:find('"public.Foo" {', 1, true) ~= nil, true)
  eq(text:find('numeric(10_2) amount', 1, true) ~= nil, true)
end

T['mermaid writes the diagram to a file'] = function()
  local path = vim.fn.tempname() .. '.mmd'
  local text = export.mermaid({ tables = { { relation = 't', columns = { pk('id') } } } }, {
    path = path,
  })
  eq(vim.fn.readfile(path), vim.split(text, '\n'))
  vim.fn.delete(path)
end

return T
