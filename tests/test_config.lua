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

T['partial query overrides preserve defaults without mutating them'] = function()
  local defaults = vim.deepcopy(config.defaults)
  config.apply({ query = { max_rows = 5 } })
  eq(config.get().query.max_rows, 5)
  eq(config.get().query.history_size, defaults.query.history_size)
  eq(config.defaults, defaults)
  config.apply({})
  eq(config.get().query, defaults.query)
end

T['validation accepts query options and rejects unknown or mistyped options'] = function()
  eq(config.validate({ query = { max_rows = 5, timeout_ms = 50 } }), {})
  eq(#config.validate({ nope = 1, query = { max_rows = 'lots' } }), 2)
end

return T
