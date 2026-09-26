local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local config = require('sqmeow.config')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
    end,
  },
})

T['defaults'] = MiniTest.new_set()

T['defaults']['are applied when setup is not called'] = function()
  eq(config.get().ui.drawer.width, config.defaults.ui.drawer.width)
  eq(config.get().ui.drawer.position, 'left')
  eq(config.get().ui.result.sticky_header, true)
  eq(config.get().ui.result.winbar_column_info, true)
end

T['defaults']['survive a partial override'] = function()
  config.apply({ ui = { drawer = { width = 50 } } })
  eq(config.get().ui.drawer.width, 50)
  eq(config.get().ui.result.page_size, 100)
end

T['defaults']['are not mutated by apply'] = function()
  config.apply({ query = { max_rows = 5 } })
  eq(config.defaults.query.max_rows, 100000)
end

T['validation'] = MiniTest.new_set()

T['validation']['accepts an empty table'] = function()
  eq(config.validate({}), {})
end

T['validation']['names an unknown top level option'] = function()
  eq(config.validate({ nope = 1 }), { 'unknown option `nope`' })
end

T['validation']['names an unknown nested option'] = function()
  eq(config.validate({ ui = { drawerr = {} } }), { 'unknown option `ui.drawerr`' })
end

T['validation']['reports a wrong type with the expected one'] = function()
  eq(config.validate({ query = { max_rows = 'lots' } }), {
    '`query.max_rows` must be a number, got string',
  })
end

T['validation']['reports every problem at once'] = function()
  eq(#config.validate({ nope = 1, ui = { border = 2 } }), 2)
end

T['validation']['leaves freeform options alone'] = function()
  eq(config.validate({ keymaps = { result = { next_page = '<C-n>' } } }), {})
  eq(config.validate({ sources = { { type = 'file', path = '/tmp/connections.json' } } }), {})
end

T['validation']['refuses connections declared in setup'] = function()
  eq(config.validate({ connections = { { name = 'dev', url = 'sqlite://:memory:' } } }), {
    'unknown option `connections`',
  })
end

T['validation']['still checks that a freeform option is a table'] = function()
  eq(config.validate({ keymaps = 'none' }), { '`keymaps` must be a table, got string' })
end

T['validation']['takes a directory for core.path'] = function()
  eq(config.validate({ core = { path = '~/.local/share/sqmeow' } }), {})
  eq(config.validate({ core = { path = 7 } }), { '`core.path` must be a string, got number' })
end

T['validation']['accepts left or right for ui.drawer.position'] = function()
  eq(config.validate({ ui = { drawer = { position = 'right' } } }), {})
  eq(config.validate({ ui = { drawer = { position = 'left' } } }), {})
  eq(config.validate({ ui = { drawer = { position = 'top' } } }), {
    "`ui.drawer.position` must be 'left' or 'right'",
  })
end

T['validation']['checks boolean type for ui.result.sticky_header'] = function()
  eq(config.validate({ ui = { result = { sticky_header = 'yes' } } }), {
    '`ui.result.sticky_header` must be a boolean, got string',
  })
  eq(config.validate({ ui = { result = { sticky_header = false } } }), {})
end

T['validation']['checks boolean type for ui.result.winbar_column_info'] = function()
  eq(config.validate({ ui = { result = { winbar_column_info = 123 } } }), {
    '`ui.result.winbar_column_info` must be a boolean, got number',
  })
  eq(config.validate({ ui = { result = { winbar_column_info = false } } }), {})
end

T['border'] = MiniTest.new_set()

T['border']['follows winborder unless one is set'] = function()
  local before = vim.o.winborder
  MiniTest.finally(function()
    vim.o.winborder = before
    config.apply({})
  end)

  config.apply({})
  vim.o.winborder = 'double'
  eq(config.border(), 'double')

  -- The custom form, which nui only takes as a list.
  vim.o.winborder = '+,-,+,|,+,-,+,|'
  eq(config.border(), { '+', '-', '+', '|', '+', '-', '+', '|' })

  config.apply({ ui = { border = 'rounded' } })
  eq(config.border(), 'rounded')
end

return T
