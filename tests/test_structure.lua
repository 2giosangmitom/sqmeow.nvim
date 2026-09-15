local MiniTest = require('mini.test')
-- How a relation's structure is laid out, without an engine.

local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local structure = require('sqmeow.ui.structure')

local T = MiniTest.new_set()

--- The text of each line.
local function text(payload)
  return vim.tbl_map(function(line)
    return line:content()
  end, structure.lines(payload))
end

T['lays out every section it was given, and leaves out the empty ones'] = function()
  local lines = text({
    properties = { { 'comment', 'people we know' } },
    columns = {
      { name = 'id', type_name = 'integer', nullable = false, primary_key = true },
      { name = 'team', type_name = 'integer', nullable = true, references = 'public.teams.id' },
    },
    comments = { { 'team', 'where they work' } },
    indexes = {},
    foreign_keys = {
      { name = 'people_team', columns = { 'team' }, target = 'teams', referenced = { 'id' } },
    },
    checks = { { 'positive', 'CHECK (id > 0)' } },
    triggers = {},
    definition = 'CREATE TABLE people (\n  id integer\n);',
  })

  eq(lines[1], 'About')
  helpers.contains(lines[2], 'comment  people we know')
  eq(vim.tbl_contains(lines, 'Columns'), true)
  helpers.contains(table.concat(lines, '\n'), '→ public.teams.id  -- where they work')
  eq(vim.tbl_contains(lines, 'Indexes'), false)
  eq(vim.tbl_contains(lines, 'Triggers'), false)
  helpers.contains(table.concat(lines, '\n'), 'people_team  (team)  → teams (id)')
  helpers.contains(table.concat(lines, '\n'), 'positive  CHECK (id > 0)')
  eq(lines[#lines], '  );')
end

T['a Redis key is its facts alone'] = function()
  eq(text({ properties = { { 'type', 'hash' }, { 'ttl', 'none' } } }), {
    'About',
    '  type  hash',
    '  ttl   none',
  })
end

return T
