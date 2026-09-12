local eq = MiniTest.expect.equality
local icons = require('sqmeow.icons')
local config = require('sqmeow.config')

--- Every case sets what it needs, since there is nothing left to detect: the icons a kind draws
--- with are exactly the ones the configuration holds.
local function set(overrides)
  config.apply({ icons = overrides })
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
    end,
  },
})

T['get'] = MiniTest.new_set()

T['get']['gives every kind a mark and a highlight'] = function()
  for kind in pairs(icons.highlights) do
    local icon, group = icons.get(kind)
    eq(icon ~= '' and icon ~= ' ', true)
    eq(group, icons.highlights[kind])
  end
end

T['get']['draws the configured glyph'] = function()
  eq(icons.get('table'), config.defaults.icons.table)
  eq(select(2, icons.get('table')), 'SqmeowIconTable')
end

T['get']['covers every kind the plugin colours'] = function()
  local function names(set_)
    local kinds = {}
    for kind, value in pairs(set_) do
      if type(value) == 'string' then
        table.insert(kinds, kind)
      end
    end
    table.sort(kinds)
    return kinds
  end

  eq(names(config.defaults.icons), names(icons.highlights))
end

T['get']['falls back to a blank for a kind it does not know'] = function()
  local icon, group = icons.get('galaxy')
  eq(icon, ' ')
  eq(group, 'SqmeowText')
end

T['get']['gives a blank rather than a table for a group of icons'] = function()
  -- `markers`, `spinner` and `grid` share the table with the kinds, and a table reaching a line
  -- being built would break the line rather than the setting.
  eq(icons.get('markers'), ' ')
  eq(icons.get('grid'), ' ')
end

T['overrides'] = MiniTest.new_set()

T['overrides']['replace one icon and leave the rest'] = function()
  set({ table = 'T' })
  eq(icons.get('table'), 'T')
  eq(icons.get('view'), config.defaults.icons.view)
end

T['overrides']['leave the highlight group alone'] = function()
  set({ table = 'T' })
  eq(select(2, icons.get('table')), 'SqmeowIconTable')
end

T['overrides']['work on a dialect too'] = function()
  set({ postgres = 'P' })
  eq(icons.get(icons.connection_kind('postgres')), 'P')
end

T['overrides']['are refused when they name a kind that does not exist'] = function()
  eq(config.validate({ icons = { galaxy = 'G' } }), { 'unknown option `icons.galaxy`' })
end

T['overrides']['are refused when they are not a string'] = function()
  eq(config.validate({ icons = { table = 42 } }), { '`icons.table` must be a string, got number' })
end

T['markers'] = MiniTest.new_set()

T['markers']['come from the configuration'] = function()
  eq(icons.markers(), config.defaults.icons.markers)
end

T['markers']['are the users to change'] = function()
  set({ markers = { open = '-', closed = '+' } })
  eq(icons.markers().open, '-')
  eq(icons.markers().closed, '+')
  -- Merged rather than replaced, so setting two of the three keeps the third.
  eq(icons.markers().leaf, config.defaults.icons.markers.leaf)
end

T['markers']['are refused when one is not a string'] = function()
  eq(config.validate({ icons = { markers = { open = true } } }), {
    '`icons.markers.open` must be a string, got boolean',
  })
end

T['connections'] = MiniTest.new_set()

T['connections']['use the glyph of the dialect they speak'] = function()
  for _, dialect in ipairs({ 'postgres', 'mysql', 'sqlite' }) do
    eq(icons.connection_kind(dialect), dialect)
  end
  eq(select(2, icons.get('postgres')), 'SqmeowIconPostgres')
end

T['connections']['fall back to a plain database for one nobody has heard of'] = function()
  eq(icons.connection_kind('duckdb'), 'connection')
  eq(icons.connection_kind(nil), 'connection')
end

T['connections']['have a dot in two colours to say whether they are open'] = function()
  eq(select(2, icons.get('connected')), 'SqmeowConnected')
  eq(select(2, icons.get('disconnected')), 'SqmeowDisconnected')
end

T['highlights'] = MiniTest.new_set()

T['highlights']['are all defined by the plugin'] = function()
  local links = require('sqmeow.ui.highlights').links

  for _, group in pairs(icons.highlights) do
    eq(links[group] ~= nil, true)
  end
end

T['grid'] = MiniTest.new_set()

T['grid']['characters are the users to change'] = function()
  eq(config.validate({ icons = { grid = { vertical = '!' } } }), {})
  config.apply({ icons = { grid = { vertical = '!' } } })
  eq(config.get().icons.grid.vertical, '!')
  eq(config.get().icons.grid.cross, config.defaults.icons.grid.cross)
end

T['grid']['refuses a key it does not draw with'] = function()
  eq(config.validate({ icons = { grid = { corner = '+' } } }), {
    'unknown option `icons.grid.corner`',
  })
end

return T
