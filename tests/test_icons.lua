local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local icons = require('sqmeow.icons')
local config = require('sqmeow.config')
local highlights = require('sqmeow.ui.highlights').links

--- Every case sets what it needs.
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

  -- Two tables of glyphs.
  local configured = names(config.defaults.icons)
  vim.list_extend(configured, names(config.defaults.icons.types))
  table.sort(configured)

  eq(configured, names(icons.highlights))
end

T['get']['draws the glyph for a type class'] = function()
  eq(icons.get('number'), config.defaults.icons.types.number)
  eq(select(2, icons.get('number')), 'SqmeowIconTypeNumber')
end

T['column_kind'] = MiniTest.new_set()

T['column_kind']['prefers a key over a type'] = function()
  eq(icons.column_kind({ class = 'number', primary_key = true }), 'primary_key')
  eq(icons.column_kind({ class = 'number', references = 'people.id' }), 'foreign_key')
  -- A column that is both is the primary key first, which is the stronger statement about the row.
  eq(
    icons.column_kind({ class = 'number', primary_key = true, references = 'people.id' }),
    'primary_key'
  )
end

T['column_kind']['falls back to the class and then to unknown'] = function()
  eq(icons.column_kind({ class = 'temporal' }), 'temporal')
  eq(icons.column_kind({}), 'unknown')
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
  for _, dialect in ipairs({ 'postgres', 'mysql', 'sqlite', 'redis', 'mongodb' }) do
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
  for _, group in pairs(icons.highlights) do
    eq(highlights[group] ~= nil, true)
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
