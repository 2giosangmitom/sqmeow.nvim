local MiniTest = require('mini.test')
-- The schema drawer, against a real SQLite database, through the real engine.

local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')
local drawer = require('sqmeow.ui.drawer')
local editor = require('sqmeow.ui.editor')
local file = require('sqmeow.sources.file')
local history = require('sqmeow.history')

local run = helpers.run

local TIMEOUT = 5000

--- Every extmark on a line, as a list of `{ group, from, to }`, in column order.
local function marks_on(number)
  return helpers.marks_on(drawer.buffer(), 'sqmeow.drawer', number)
end

local lines = helpers.drawer_lines
local line_matching = helpers.drawer_line

--- Put the cursor on the line matching `pattern`.
local function goto_line(pattern)
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching(pattern), 0 })
end

--- Put the cursor on a line and make sure what is there is open.
local function expand(pattern)
  local number = line_matching(pattern)
  if lines()[number]:find('^%s*v') then
    return
  end

  vim.api.nvim_win_set_cursor(drawer.open(), { number, 0 })
  drawer.actions.toggle()
end

--- Put the cursor on a line and close what is there.
local function collapse(pattern)
  goto_line(pattern)
  drawer.actions.toggle()
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      -- Pinned to plain characters.
      require('sqmeow').setup({
        -- A directory of its own.
        core = { path = vim.fn.tempname() },
        icons = {
          connection = '#',
          schema = '@',
          table = '=',
          view = '~',
          ['materialized view'] = '~',
          relation = '=',
          column = '-',
          scratchpads = '+',
          scratchpad = '*',
          query = '>',
          history = 'H',
          connected = 'o',
          disconnected = 'x',
          ['function'] = 'f',
          procedure = 'p',
          tables = 'T',
          views = 'V',
          functions = 'F',
          procedures = 'P',
          postgres = 'p',
          mysql = 'm',
          sqlite = 's',
          markers = { open = 'v', closed = '>', leaf = ' ' },
          grid = { vertical = '|', horizontal = '-', cross = '+', ellipsis = '~' },
          -- ASCII, like every other glyph here, so a pattern can match on them.
          types = helpers.ascii_icons(),
        },
      })

      helpers.connect('sqlite::memory:', { name = 'scratch' })

      run('create table people (id integer primary key, name text not null, score real)')
      run('create view adults as select * from people')
      run([[create table posts (
             id integer primary key,
             author_id integer references people(id),
             title text
           )]])
      api.open_drawer()
    end,
    post_once = function()
      drawer.close()
      api.close()
      rpc.stop()
      state.reset()
      drawer.reset()
    end,
  },
})

--- Open a schema and the group a relation sits under, then the relation itself.
local function open_relation(group, name)
  expand('scratch')
  expand('main')
  expand(group)
  expand(name)
end

T['tree'] = MiniTest.new_set()

T['tree']['starts with connections collapsed'] = function()
  local drawn = lines()
  eq(vim.list_slice(drawn, 1, 2), { '> o s scratch  sqlite', '> + scratchpads  none saved' })
  -- The log's contents depend on which cases have run.
  eq(drawn[3]:find('> H history', 1, true), 1)
  eq(#drawn, 3)
end

T['tree']['colours the marker apart from the icon'] = function()
  expand('scratch')
  line_matching('main')

  -- `v o s scratch sqlite`.
  eq(marks_on(1), {
    { group = 'SqmeowMarker', from = 0, to = 1 },
    { group = 'SqmeowConnected', from = 2, to = 3 },
    { group = 'SqmeowIconSqlite', from = 4, to = 5 },
    { group = 'SqmeowNull', from = 15, to = 21 },
  })
end

T['tree']['expands a connection into its schemas'] = function()
  expand('scratch')
  line_matching('main')

  eq(lines()[1], 'v o s scratch  sqlite')
  eq(lines()[2], '  > @ main')
end

T['tree']['expands a schema into groups that count what they hold'] = function()
  expand('scratch')
  expand('main')
  line_matching('Procedures')

  local text = table.concat(lines(), '\n')
  eq(text:find('T Tables%s+%(2%)') ~= nil, true)
  eq(text:find('V Views%s+%(1%)') ~= nil, true)
  -- SQLite has no stored routines at all, which the count says without being opened.
  eq(text:find('F Functions%s+%(0%)') ~= nil, true)
  eq(text:find('P Procedures%s+%(0%)') ~= nil, true)
end

T['tree']['leaves an empty group closed, since it opens onto nothing'] = function()
  expand('scratch')
  expand('main')
  local number = line_matching('Functions')

  -- The marker column is blank, the same as a leaf's, rather than a chevron that does nothing.
  eq(lines()[number]:match('^%s*(%S)'), 'F')
end

T['tree']['expands a group into the relations it holds'] = function()
  expand('scratch')
  expand('main')
  expand('Tables')
  line_matching('people')

  expand('Views')
  line_matching('adults')

  local text = table.concat(lines(), '\n')
  -- No kind beside either name: the group above it already said so.
  eq(text:find('= people') ~= nil, true)
  eq(text:find('~ adults') ~= nil, true)
end

T['tree']['renews the count on a heading it refreshes'] = function()
  expand('scratch')
  expand('main')
  expand('Tables')
  line_matching('people')

  run('create table late (id integer primary key)')
  MiniTest.finally(function()
    run('drop table late')
    goto_line('Tables')
    drawer.actions.refresh()
    line_matching('T Tables%s+%(2%)')
  end)

  goto_line('Tables')
  drawer.actions.refresh()

  -- The new table appearing is only half of it.
  line_matching('= late')
  line_matching('T Tables%s+%(3%)')
end

T['tree']['refreshing a connection reloads every level that is open'] = function()
  open_relation('Tables', 'people')
  line_matching('score')

  run('alter table people add column added text')
  MiniTest.finally(function()
    run('alter table people drop column added')
  end)

  -- Refreshed from the connection, three levels above the columns.
  goto_line('scratch')
  drawer.actions.refresh()

  line_matching('added')
  local text = table.concat(lines(), '\n')
  -- The levels in between are still there rather than having emptied out.
  helpers.contains(text, 'T Tables')
  helpers.contains(text, '= people')
  helpers.contains(text, 'n score')
end

T['tree']['expands a relation into its columns'] = function()
  open_relation('Tables', 'people')
  line_matching('score')

  local text = table.concat(lines(), '\n')
  -- A key says so in two letters beside its type.
  eq(text:find('K id%s+INTEGER %(PK%)') ~= nil, true)
  eq(text:find('t name%s+TEXT%s+not null') ~= nil, true)
  eq(text:find('n score%s+REAL') ~= nil, true)
end

T['tree']['marks a column with what it holds'] = function()
  open_relation('Tables', 'people')
  local number = line_matching('score')

  -- The glyph is coloured by what the column holds rather than by it being a column.
  local groups = vim.tbl_map(function(span)
    return span.group
  end, marks_on(number))
  eq(vim.tbl_contains(groups, 'SqmeowIconTypeNumber'), true)
end

T['tree']['marks a foreign key'] = function()
  open_relation('Tables', 'posts')
  line_matching('author_id')

  local text = table.concat(lines(), '\n')
  eq(text:find('k author_id%s+INTEGER %(FK%)') ~= nil, true)
end

T['tree']['leaves a blank marker unmarked'] = function()
  open_relation('Tables', 'people')
  local number = line_matching('score')

  -- A leaf's marker is a space and gets no extmark.
  for _, span in ipairs(marks_on(number)) do
    eq(span.group ~= 'SqmeowMarker', true)
  end
end

T['tree']['collapses again'] = function()
  open_relation('Tables', 'people')
  local before = #lines()
  collapse('people')
  eq(#lines() < before, true)
  eq(drawer.is_expanded(state.current, { 'main', 'tables', 'people' }), false)
end

T['actions'] = MiniTest.new_set()

T['actions']['yank a qualified name'] = function()
  open_relation('Tables', 'people')
  goto_line('people')
  drawer.actions.yank_name()
  eq(vim.fn.getreg('"'), '"main"."people"')
end

T['actions']['yank a select for a relation'] = function()
  open_relation('Tables', 'people')
  goto_line('people')
  drawer.actions.yank_select()
  eq(vim.fn.getreg('"'), 'select * from "main"."people" limit 100')
end

T['actions']['do nothing on a node that is not a relation'] = function()
  vim.fn.setreg('"', 'untouched')
  goto_line('scratch')
  drawer.actions.yank_select()
  eq(vim.fn.getreg('"'), 'untouched')
end

T['actions']['preview a relation into the result window'] = function()
  open_relation('Tables', 'people')
  goto_line('people')
  drawer.actions.preview()

  helpers.wait_for('the preview should finish', function()
    return state.call ~= nil and state.call.state == 'done'
  end, TIMEOUT)

  -- ASCII rules and ASCII icons.
  eq(helpers.result_lines()[1], ' K id | t name | n score')
end

T['the active connection'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      api.connect('sqlite::memory:', { name = 'other' })
      helpers.wait_for('the connection should be listed', function()
        return state.connection_by_name('other') ~= nil
      end, TIMEOUT)
      drawer.render()
    end,
    post_case = function()
      local other = state.connection_by_name('other')
      if other then
        api.disconnect(other.id)
      end
      drawer.render()
    end,
  },
})

T['the active connection']['moves when another is chosen'] = function()
  goto_line('other')
  drawer.actions.use()

  eq(state.current, state.connection_by_name('other').id)
end

T['the active connection']['does not move when a row is only opened'] = function()
  api.use(state.connection_by_name('scratch').id)
  drawer.render()

  goto_line('other')
  drawer.actions.toggle()

  -- Expanding a connection does not make it the active one.
  eq(state.current, state.connection_by_name('scratch').id)
end

T['the active connection']['is left alone from a row that is not a connection'] = function()
  local before = state.current
  goto_line('scratchpads')
  drawer.actions.use()

  eq(state.current, before)
end

T['saved connections'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      file.add({ name = 'ledger', url = 'postgres://localhost/ledger' })
      drawer.render()
    end,
    post_case = function()
      vim.fn.delete(file.default_path())
      drawer.render()
    end,
  },
})

T['saved connections']['are listed even though nothing is open'] = function()
  eq(lines()[line_matching('ledger')], '> x p ledger  postgres')
end

T['saved connections']['show a dot in the colour of their state'] = function()
  local number = line_matching('ledger')
  eq(marks_on(number)[2], { group = 'SqmeowDisconnected', from = 2, to = 3 })

  -- The one that is open carries the other colour, on the same column.
  eq(marks_on(line_matching('scratch'))[2], { group = 'SqmeowConnected', from = 2, to = 3 })
end

T['saved connections']['open when chosen'] = function()
  local opened
  helpers.stub(api, 'connect_named', function(name)
    opened = name
  end)

  goto_line('ledger')
  drawer.actions.toggle()
  eq(opened, 'ledger')
end

T['saved connections']['say they are connecting while they do'] = function()
  state.add_connection({
    id = 999,
    name = 'ledger',
    url = 'postgres://localhost/ledger',
    state = 'connecting',
  })
  MiniTest.finally(function()
    state.remove_connection(999)
    drawer.render()
  end)
  drawer.render()

  local number = line_matching('ledger')
  eq(lines()[number]:find('connecting$') ~= nil, true)
  eq(marks_on(number)[2].group, 'SqmeowConnecting')
end

T['saved connections']['can be tried again after failing to open'] = function()
  file.add({ name = 'broken', url = 'oracle://localhost/broken' })
  drawer.render()

  goto_line('broken')
  drawer.actions.toggle()
  helpers.wait_for('the failed connection should be forgotten', function()
    return state.connection_by_name('broken') == nil
  end, TIMEOUT)
  -- Back to a saved row that says it failed, rather than left drawn as the connection that did.
  local number = line_matching('broken')
  eq(lines()[number]:find('error$') ~= nil, true)
  eq(marks_on(number)[2].group, 'SqmeowConnectionError')

  local opened
  helpers.stub(api, 'connect_named', function(name)
    opened = name
  end)

  goto_line('broken')
  drawer.actions.toggle()
  eq(opened, 'broken')
end

T['history'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      history.clear()
      drawer.render()
    end,
    post_case = function()
      history.clear()
      drawer.render()
    end,
  },
})

T['history']['counts what has been run, without being asked to redraw'] = function()
  run('select 1 as one')
  eq(lines()[line_matching('history')], '> H history  1')
end

T['history']['expands into the statements themselves'] = function()
  run('select 2 as two')
  drawer.render()
  expand('history')
  eq(lines()[line_matching('select 2')], '    > select 2 as two  just now')
end

T['history']['puts a query back on screen when chosen'] = function()
  local summary = run('select 3 as three')
  drawer.render()
  expand('history')

  goto_line('select 3')
  drawer.actions.toggle()

  eq(assert(state.call).call_id, summary.call_id)
end

T['history']['shows a saved result once the engine no longer holds it'] = function()
  local summary = run('select 5 as five')
  local entry = history.entries()[1]
  helpers.wait_for('the engine should save the result', function()
    return history.saved(entry)
  end, TIMEOUT)

  -- As if Neovim had restarted: the call ids the last session handed out mean nothing now.
  local session = history.session
  history.session = 'a later one'
  MiniTest.finally(function()
    history.session = session
  end)

  drawer.render()
  expand('history')
  goto_line('select 5')
  drawer.actions.toggle()

  helpers.wait_for('the saved result should be read back', function()
    return state.call ~= nil
      and state.call.call_id ~= summary.call_id
      and state.call.state == 'done'
  end, TIMEOUT)

  eq(state.call.rows, 1)
  eq(state.call.ran_at, entry.at)
  eq(vim.trim(helpers.result_lines()[3]), '5')
  -- Showing it again is not running it again.
  eq(#history.entries(), 1)
end

T['history']['shows the error a failed query had'] = function()
  run('select nope_at_all from nowhere_at_all')
  local entry = history.entries()[1]
  eq(entry.state, 'error')

  local session = history.session
  history.session = 'a later one'
  MiniTest.finally(function()
    history.session = session
  end)

  drawer.render()
  expand('history')
  goto_line('nope_at_all')
  drawer.actions.toggle()

  eq(state.call.state, 'error')
  eq(state.call.error, entry.error)
  eq(state.call.call_id, nil)
end

T['history']['leaves out a preview the drawer ran'] = function()
  open_relation('Tables', 'people')
  goto_line('people')
  drawer.actions.preview()

  helpers.wait_for('the preview should finish', function()
    return state.call ~= nil and state.call.state == 'done'
  end, TIMEOUT)
  eq(history.entries(), {})
end

T['history']['empties on request'] = function()
  run('select 4 as four')
  drawer.render()

  goto_line('history')
  local answered = false
  helpers.stub(vim.ui, 'select', function(_, _, on_choice)
    answered = true
    on_choice('yes')
  end)

  drawer.actions.delete()
  eq(answered, true)
  eq(history.entries(), {})
end

T['scratchpads'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.writefile(vim.fs.joinpath(editor.directory(), 'notes.sql'), { 'select 1' })
      drawer.render()
    end,
    post_case = function()
      vim.fn.delete(vim.fs.joinpath(editor.directory(), 'notes.sql'))
      drawer.render()
    end,
  },
})

T['scratchpads']['are listed under a heading of their own'] = function()
  local heading = line_matching('scratchpads')
  eq(lines()[heading], '> + scratchpads  1')
end

T['scratchpads']['expand into the saved files'] = function()
  expand('scratchpads')
  -- The icon sits in the same column as one on a branch, so a leaf lines up with its siblings.
  eq(lines()[line_matching('notes')], '    * notes')
end

T['scratchpads']['open the file when chosen'] = function()
  expand('scratchpads')
  goto_line('notes')
  drawer.actions.toggle()

  local opened = vim.api.nvim_buf_get_name(0)
  eq(vim.fs.basename(opened), 'notes.sql')
  eq(vim.bo.filetype, 'sql')

  -- Back to the drawer, so the next case starts where this one did.
  vim.cmd.bwipeout()
  drawer.open()
end

T['scratchpads']['open somewhere other than the drawer'] = function()
  expand('scratchpads')
  local sidebar = drawer.open()
  vim.api.nvim_win_set_cursor(sidebar, { line_matching('notes'), 0 })
  vim.api.nvim_set_current_win(sidebar)

  drawer.actions.toggle()

  -- A plain `:edit` would have opened the file in the window the key was pressed in.
  eq(vim.api.nvim_get_current_win() ~= sidebar, true)
  eq(vim.bo[vim.api.nvim_win_get_buf(sidebar)].filetype, 'sqmeow-drawer')
  eq(drawer.is_open(), true)

  vim.cmd.bwipeout()
  drawer.open()
end

T['scratchpads']['are renamed once a new name is given'] = function()
  helpers.stub(vim.ui, 'input', function(_, on_confirm)
    on_confirm('renamed')
  end)
  MiniTest.finally(function()
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'renamed.sql'))
  end)

  expand('scratchpads')
  goto_line('notes')
  drawer.actions.rename()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')), nil)
  eq(lines()[line_matching('renamed')], '    * renamed')
end

T['scratchpads']['offer the current name to edit'] = function()
  local offered = nil
  helpers.stub(vim.ui, 'input', function(opts)
    offered = opts.default
  end)

  expand('scratchpads')
  goto_line('notes')
  drawer.actions.rename()

  eq(offered, 'notes')
end

T['scratchpads']['are left alone when the rename is abandoned'] = function()
  helpers.stub(vim.ui, 'input', function(_, on_confirm)
    on_confirm(nil)
  end)

  expand('scratchpads')
  goto_line('notes')
  drawer.actions.rename()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')) ~= nil, true)
end

T['scratchpads']['are not renamed from a row that is not one'] = function()
  local called = false
  helpers.stub(vim.ui, 'input', function()
    called = true
  end)

  -- A schema is neither a scratchpad nor a connection, so there is no name of its own to change.
  expand('scratch')
  goto_line('@ main')
  drawer.actions.rename()
  eq(called, false)
end

T['connections'] = MiniTest.new_set()

T['connections']['are renamed from the row that shows them'] = function()
  helpers.stub(vim.ui, 'input', function(opts, on_confirm)
    -- The current name is the default, so the prompt is somewhere to edit rather than to retype.
    eq(opts.default, 'scratch')
    on_confirm('local sqlite')
  end)
  MiniTest.finally(function()
    api.rename(state.current, 'scratch')
    drawer.render()
  end)

  goto_line('scratch  sqlite')
  drawer.actions.rename()

  eq(state.connections[state.current].name, 'local sqlite')
  helpers.contains(lines()[1], 'local sqlite')
end

T['connections']['keep their name when the prompt is dismissed'] = function()
  helpers.stub(vim.ui, 'input', function(_, on_confirm)
    on_confirm(nil)
  end)

  goto_line('scratch  sqlite')
  drawer.actions.rename()
  eq(state.connections[state.current].name, 'scratch')
end

T['scratchpads']['are deleted once the question is answered'] = function()
  local answer = 'yes'
  helpers.stub(vim.ui, 'select', function(_, _, on_choice)
    on_choice(answer)
  end)

  expand('scratchpads')
  goto_line('notes')
  drawer.actions.delete()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')), nil)
  eq(lines()[line_matching('scratchpads')]:find('none saved') ~= nil, true)
end

T['scratchpads']['are left alone when the question is declined'] = function()
  helpers.stub(vim.ui, 'select', function(_, _, on_choice)
    on_choice('no')
  end)

  expand('scratchpads')
  goto_line('notes')
  drawer.actions.delete()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')) ~= nil, true)
end

T['scratchpads']['are not deleted from a row that is not one'] = function()
  local called = false
  helpers.stub(vim.ui, 'select', function()
    called = true
  end)

  goto_line('scratch  sqlite')
  drawer.actions.delete()
  eq(called, false)
end

T['scratchpads']['are created for the connection under the cursor'] = function()
  helpers.stub(vim.ui, 'input', function(opts, on_confirm)
    helpers.contains(opts.prompt, 'scratch')
    on_confirm('report')
  end)
  MiniTest.finally(function()
    vim.cmd('silent! bwipeout!')
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'scratch'), 'rf')
    drawer.open()
    drawer.render()
  end)

  goto_line('scratch  sqlite')
  vim.api.nvim_set_current_win(drawer.open())
  drawer.actions.new_scratchpad()

  -- Opened beside the drawer, as a SQL file in the connection's folder, and listed under its name.
  eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), 'report.sql')
  eq(vim.bo.filetype, 'sql')
  eq(vim.b.sqmeow_connection, 'scratch')
  expand('scratchpads')
  eq(lines()[line_matching('report')], '    * report  scratch')
end

T['scratchpads']['are not created from a row outside every connection'] = function()
  local called = false
  helpers.stub(vim.ui, 'input', function()
    called = true
  end)

  goto_line('scratchpads')
  drawer.actions.new_scratchpad()
  eq(called, false)
end

T['scratchpads']['say so when there are none'] = function()
  vim.fn.delete(vim.fs.joinpath(editor.directory(), 'notes.sql'))
  drawer.render()

  eq(lines()[line_matching('scratchpads')]:find('none saved') ~= nil, true)
end

T['window'] = MiniTest.new_set()

T['window']['is open, and its buffer cannot be typed into'] = function()
  eq(drawer.is_open(), true)
  eq(vim.bo[drawer.buffer()].modifiable, false)
  eq(vim.bo[drawer.buffer()].buftype, 'nofile')
end

T['window']['maps its keys buffer-locally with descriptions'] = function()
  local seen = helpers.buf_maps(drawer.buffer())

  for _, key in ipairs({ '<CR>', 'o', 'r', 'y', 's', 'a', '?', 'q' }) do
    eq(type(seen[key]), 'string')
  end
end

return T
