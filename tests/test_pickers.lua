-- The plugin's own lists, against a real SQLite database, through the real engine.
--
-- Every case captures what is handed to the picker seam, so what is under test is the list each
-- picker builds, how it labels and previews a row, and what choosing one does. No third-party
-- picker is involved, and none needs to be installed.

local eq = MiniTest.expect.equality
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')
local pickers = require('sqmeow.pickers')

local TIMEOUT = 5000

-- The items and options the last picker was opened with.
local shown = nil

local function labels()
  return vim.tbl_map(shown.opts.format, shown.items)
end

local function item_matching(pattern)
  for index, label in ipairs(labels()) do
    if label:find(pattern) then
      return shown.items[index]
    end
  end
  error(('no row matching %q in:\n%s'):format(pattern, table.concat(labels(), '\n')))
end

--- Choose the first row whose label matches, as a user would.
local function choose(pattern)
  return shown.opts.on_choice(item_matching(pattern))
end

--- The preview lines for the first row whose label matches.
local function preview(pattern)
  return shown.opts.preview(item_matching(pattern))
end

--- Run a picker that has to read from the engine first, and wait until it is on screen.
local function await(open)
  shown = nil
  open()
  assert(
    vim.wait(TIMEOUT, function()
      return shown ~= nil
    end, 10),
    'the picker should open'
  )
end

local function run(sql)
  local call_id = assert(api.execute(sql))
  assert(
    vim.wait(TIMEOUT, function()
      return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
    end, 10),
    'the query should settle: ' .. sql
  )
  return state.call
end

local picker = require('sqmeow.integrations.picker')
local builtin = picker.backends.builtin.run

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ integrations = { picker = 'builtin', icons = 'ascii' } })

      picker.backends.builtin.run = function(items, opts)
        shown = { items = items, opts = opts }
      end

      local id = assert(api.connect('sqlite::memory:', { name = 'scratch' }))
      assert(vim.wait(TIMEOUT, function()
        return state.connections[id] ~= nil and state.connections[id].state == 'connected'
      end, 10))

      run('create table people (id integer primary key, name text not null, score real)')
      run('create view adults as select * from people')
      run("insert into people (name, score) values ('ada', 1.5), ('grace', 2.5)")
    end,
    pre_case = function()
      shown = nil
    end,
    post_once = function()
      picker.backends.builtin.run = builtin
      api.close()
      rpc.stop()
      state.reset()
      require('sqmeow.ui.drawer').reset()
    end,
  },
})

T['connections'] = MiniTest.new_set()

T['connections']['lists the open ones with their dialect'] = function()
  pickers.connections()
  eq(labels()[1]:find('^scratch') ~= nil, true)
  eq(labels()[1]:find('sqlite') ~= nil, true)
end

T['connections']['previews the URL with its password hidden'] = function()
  local id = assert(api.connect('postgres://app:hunter2@localhost/app', { name = 'secret' }))
  MiniTest.finally(function()
    api.disconnect(id)
    api.use(1)
  end)

  pickers.connections()
  eq(vim.tbl_contains(preview('^secret'), 'postgres://app:***@localhost/app'), true)
end

T['connections']['makes the chosen one current'] = function()
  local other = assert(api.connect('sqlite::memory:', { name = 'other' }))
  assert(vim.wait(TIMEOUT, function()
    return state.connections[other] ~= nil and state.connections[other].state == 'connected'
  end, 10))

  pickers.connections()
  choose('^scratch')
  eq(state.current_connection().name, 'scratch')

  pickers.connections()
  choose('^other')
  eq(state.current_connection().name, 'other')

  api.disconnect(other)
  eq(state.current_connection().name, 'scratch')
end

T['relations'] = MiniTest.new_set()

T['relations']['finds a table and a view across every schema'] = function()
  await(pickers.relations)

  local text = table.concat(labels(), '\n')
  eq(text:find('main%.people') ~= nil, true)
  eq(text:find('main%.adults%s+view') ~= nil, true)
end

T['relations']['is answered from the mirror the second time'] = function()
  await(pickers.relations)
  eq(state.catalogs[state.current].relations ~= nil, true)

  -- No round trip left to wait for: the list is already there, so it opens in the same tick.
  shown = nil
  pickers.relations()
  eq(shown ~= nil, true)
end

T['relations']['narrows to one schema when asked'] = function()
  await(function()
    pickers.relations({ schema = 'main' })
  end)

  for _, relation in ipairs(shown.items) do
    eq(relation.schema, 'main')
  end

  -- A schema with nothing in it has no list to show, so nothing opens at all.
  shown = nil
  pickers.relations({ schema = 'nowhere' })
  eq(shown, nil)
end

T['relations']['previews the SELECT that choosing a row would run'] = function()
  await(pickers.relations)
  eq(preview('main%.people')[1], 'select * from "main"."people" limit 100')
end

T['relations']['runs a SELECT over the chosen relation'] = function()
  await(pickers.relations)
  choose('main%.people')

  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.state == 'done'
  end, 10))
  eq(state.call.rows, 2)
end

T['history'] = MiniTest.new_set()

T['history']['describes each entry by its outcome and its SQL'] = function()
  run('select 1 as one')
  pickers.history()

  eq(labels()[1]:find('1 rows?') ~= nil, true)
  eq(labels()[1]:find('select 1 as one') ~= nil, true)
end

T['history']['reopens a result without running it again'] = function()
  local first = run('select 41 as answer')
  run('select 1 as other')
  eq(state.call.call_id ~= first.call_id, true)

  pickers.history()
  choose('select 41 as answer')

  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == first.call_id
  end, 10))
end

T['scratchpads'] = MiniTest.new_set()

T['scratchpads']['lists the saved files without their extension'] = function()
  local editor = require('sqmeow.ui.editor')
  vim.fn.mkdir(editor.directory(), 'p')
  vim.fn.writefile({ 'select 1' }, vim.fs.joinpath(editor.directory(), 'sqmeow-test-pad.sql'))
  MiniTest.finally(function()
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'sqmeow-test-pad.sql'))
  end)

  pickers.scratchpads()
  eq(vim.tbl_contains(labels(), 'sqmeow-test-pad'), true)
end

T['columns'] = MiniTest.new_set()

T['columns']['lists the columns of the current result with their types'] = function()
  run('select id, name, score from people order by id')
  pickers.columns()

  eq(#labels(), 3)
  eq(labels()[1]:find('^id') ~= nil, true)
  eq(labels()[2]:find('^name') ~= nil, true)
end

T['columns']['previews the values the grid is showing'] = function()
  run('select id, name from people order by id')
  pickers.columns()

  local lines = preview('^name')
  eq(lines[1], 'name')
  -- Three heading lines, then the column read back out of the painted grid.
  eq(lines[4], 'ada')
  eq(lines[5], 'grace')
end

T['columns']['puts the cursor on the chosen column'] = function()
  run('select id, name, score from people order by id')
  local result = require('sqmeow.ui.result')
  vim.api.nvim_win_set_cursor(result.open(), { 1, 0 })

  pickers.columns()
  choose('^name')

  eq(result.current_cell().name, 'name')
end

T['open'] = MiniTest.new_set()

T['open']['knows every picker by name'] = function()
  eq(pickers.names(), { 'columns', 'connections', 'history', 'relations', 'scratchpads' })
end

T['open']['offers the names when asked for none'] = function()
  pickers.open()
  eq(shown.items, pickers.names())
end

T['open']['says so when a name is not one of them'] = function()
  pickers.open('galaxies')
  eq(shown, nil)
end

return T
