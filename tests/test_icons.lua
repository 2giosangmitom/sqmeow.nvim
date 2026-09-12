local eq = MiniTest.expect.equality
local icons = require('sqmeow.integrations.icons')
local config = require('sqmeow.config')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      icons.reset()
    end,
    post_case = function()
      config.apply({})
      icons.reset()
    end,
  },
})

T['provider'] = MiniTest.new_set()

T['provider']['honours an explicit choice over what is installed'] = function()
  config.apply({ integrations = { icons = 'ascii' } })
  eq(icons.provider(), 'ascii')
  eq(icons.glyphs_available(), false)
end

T['provider']['answers with one of the three it knows'] = function()
  config.apply({})
  eq(vim.tbl_contains({ 'mini', 'devicons', 'ascii' }, icons.provider()), true)
end

T['provider']['is remembered until something resets it'] = function()
  config.apply({ integrations = { icons = 'ascii' } })
  eq(icons.provider(), 'ascii')

  -- The cache is deliberate: this is read once per drawer line, and a `require` per line would
  -- be the drawer's slowest part.
  config.apply({ integrations = { icons = 'mini' } })
  eq(icons.provider(), 'ascii')

  icons.reset()
  eq(icons.provider(), 'mini')
end

T['get'] = MiniTest.new_set()

T['get']['gives every node kind a mark and a highlight'] = function()
  config.apply({ integrations = { icons = 'ascii' } })

  for kind in pairs(icons.glyphs) do
    local icon, group = icons.get(kind)
    eq(icon ~= '' and icon ~= ' ', true)
    eq(group:sub(1, 6), 'Sqmeow')
  end
end

T['get']['covers the same kinds in both sets'] = function()
  local function kinds(set)
    local names = vim.tbl_keys(set)
    table.sort(names)
    return names
  end

  eq(kinds(icons.glyphs), kinds(icons.ascii))
end

T['get']['falls back to a blank for a kind it does not know'] = function()
  local icon, group = icons.get('galaxy')
  eq(icon, ' ')
  eq(group, 'SqmeowText')
end

T['get']['is one display column wide in the ASCII set'] = function()
  config.apply({ integrations = { icons = 'ascii' } })
  for kind in pairs(icons.ascii) do
    eq(vim.api.nvim_strwidth((icons.get(kind))), 1)
  end
end

T['dialect'] = MiniTest.new_set()

T['dialect']['abbreviates the ones the engine supports'] = function()
  eq(icons.dialect('postgres'), 'pg')
  eq(icons.dialect('mysql'), 'my')
  eq(icons.dialect('sqlite'), 'sq')
end

T['dialect']['shows an unknown one by name, and a missing one as a question'] = function()
  eq(icons.dialect('duckdb'), 'duckdb')
  eq(icons.dialect(nil), '?')
end

return T
