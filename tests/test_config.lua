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
end

T['defaults']['survive a partial override'] = function()
  config.apply({ ui = { drawer = { width = 50 } } })
  eq(config.get().ui.drawer.width, 50)
  eq(config.get().ui.drawer.position, 'left')
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
  eq(config.validate({ connections = { { name = 'dev', url = 'sqlite://:memory:' } } }), {})
end

T['validation']['still checks that a freeform option is a table'] = function()
  eq(config.validate({ keymaps = 'none' }), { '`keymaps` must be a table, got string' })
end

T['validation']['accepts a nullable option with no default'] = function()
  eq(config.validate({ core = { path = '/usr/bin/sqmeow-core' } }), {})
  eq(config.validate({ core = { path = 7 } }), { '`core.path` must be a string, got number' })
end

return T
