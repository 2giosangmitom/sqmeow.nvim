local eq = MiniTest.expect.equality
local icons = require('sqmeow.integrations.icons')
local config = require('sqmeow.config')

--- Most cases pin the ASCII set, so what they assert does not depend on which icon plugin the
--- machine running the suite happens to have installed.
local function ascii(overrides)
  config.apply({ integrations = { icons = 'ascii', icon_overrides = overrides } })
  icons.reset()
end

local function glyphs(overrides)
  config.apply({ integrations = { icons = 'mini', icon_overrides = overrides } })
  icons.reset()
end

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
  ascii()
  eq(icons.provider(), 'ascii')
  eq(icons.glyphs_available(), false)
end

T['provider']['answers with one of the three it knows'] = function()
  config.apply({})
  eq(vim.tbl_contains({ 'mini', 'devicons', 'ascii' }, icons.provider()), true)
end

T['provider']['is remembered until something resets it'] = function()
  ascii()
  eq(icons.provider(), 'ascii')

  -- The cache is deliberate: this is read once per drawer line, and a `require` per line would
  -- be the drawer's slowest part.
  config.apply({ integrations = { icons = 'mini' } })
  eq(icons.provider(), 'ascii')

  icons.reset()
  eq(icons.provider(), 'mini')
end

T['get'] = MiniTest.new_set()

T['get']['gives every kind a mark and a highlight'] = function()
  ascii()

  for kind in pairs(icons.highlights) do
    local icon, group = icons.get(kind)
    eq(icon ~= '' and icon ~= ' ', true)
    eq(group, icons.highlights[kind])
  end
end

T['get']['covers the same kinds in the glyph set and the ASCII one'] = function()
  local function names(set)
    local kinds = vim.tbl_keys(set)
    table.sort(kinds)
    return kinds
  end

  eq(names(icons.nerd), names(icons.highlights))
  eq(names(icons.ascii), names(icons.highlights))
end

T['get']['falls back to a blank for a kind it does not know'] = function()
  local icon, group = icons.get('galaxy')
  eq(icon, ' ')
  eq(group, 'SqmeowText')
end

T['get']['is one display column wide in the ASCII set'] = function()
  ascii()
  for kind in pairs(icons.ascii) do
    eq(vim.api.nvim_strwidth((icons.get(kind))), 1)
  end
end

T['get']['uses nerd font glyphs when a font for them is present'] = function()
  glyphs()
  eq(icons.get('table'), icons.nerd.table)
  eq(select(2, icons.get('table')), 'SqmeowIconTable')
end

T['overrides'] = MiniTest.new_set()

T['overrides']['replace one icon and leave the rest'] = function()
  ascii({ table = 'T' })
  eq(icons.get('table'), 'T')
  eq(icons.get('view'), icons.ascii.view)
end

T['overrides']['apply whichever set is in use'] = function()
  -- Someone who writes an override has decided what they want to see, and is not asking to be
  -- second-guessed about their font.
  glyphs({ table = 'T' })
  eq(icons.get('table'), 'T')
end

T['overrides']['leave the highlight group alone'] = function()
  ascii({ table = 'T' })
  eq(select(2, icons.get('table')), 'SqmeowIconTable')
end

T['overrides']['work on a dialect too'] = function()
  ascii({ postgres = 'P' })
  eq(icons.dialect('postgres'), 'P')
end

T['overrides']['are reported when they name a kind that does not exist'] = function()
  ascii({ galaxy = 'G' })
  eq(icons.problems(), { 'there is no `galaxy` icon to override' })
end

T['overrides']['are reported when they are not a string'] = function()
  config.apply({ integrations = { icon_overrides = { table = 42 } } })
  eq(icons.problems(), { 'the `table` icon must be a string, got number' })
end

T['overrides']['are reported by config validation as well'] = function()
  eq(config.validate({ integrations = { icon_overrides = { table = 42 } } }), {
    '`integrations.icon_overrides.table` must be a string, got number',
  })
end

T['dialect'] = MiniTest.new_set()

T['dialect']['abbreviates the ones the engine supports without a font'] = function()
  ascii()
  eq(icons.dialect('postgres'), 'pg')
  eq(icons.dialect('mysql'), 'my')
  eq(icons.dialect('sqlite'), 'sq')
end

T['dialect']['uses its glyph where there is a font for one'] = function()
  glyphs()
  eq(icons.dialect('postgres'), icons.nerd.postgres)
  eq(select(2, icons.dialect('postgres')), 'SqmeowIconPostgres')
end

T['dialect']['shows an unknown one by name, and a missing one as a question'] = function()
  ascii()
  eq(icons.dialect('duckdb'), 'duckdb')
  eq(icons.dialect(nil), '?')
end

T['highlights'] = MiniTest.new_set()

T['highlights']['are all defined by the plugin'] = function()
  local links = require('sqmeow.ui.highlights').links

  for _, group in pairs(icons.highlights) do
    eq(links[group] ~= nil, true)
  end
end

return T
