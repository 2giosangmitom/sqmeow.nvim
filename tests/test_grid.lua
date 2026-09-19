local MiniTest = require('mini.test')
-- The result grid against a real engine and SQLite.
local helpers = dofile('tests/helpers.lua')

local eq = MiniTest.expect.equality
local api = require('sqmeow.api')
local state = require('sqmeow.state')
local result = require('sqmeow.ui.result')
local edit = require('sqmeow.ui.edit')
local rpc = require('sqmeow.rpc')

local wait = helpers.wait_for
local run = helpers.run
local rows = helpers.result_rows

--- Every floating window.
---@return integer[]
local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ''
  end, vim.api.nvim_list_wins())
end

--- Open the result and put the cursor in it, the way a case about keys needs.
local function focus_result()
  local win = result.open()
  vim.api.nvim_set_current_win(win)
  return win
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ ui = { result = { page_size = 10, column_icons = false } } })
      api.use(helpers.connect('sqlite::memory:', { name = 'grid' }))
      run('create table people (id integer primary key, name text, age integer)')
      run([[insert into people (id, name, age) values
              (1, 'alice', 30), (2, 'bob', null), (3, 'carol', 9)]])
    end,
    pre_case = function()
      run('select id, name, age from people order by id')
    end,
    post_case = function()
      edit.reset()
      result.close()
    end,
    post_once = function()
      api.disconnect()
    end,
  },
})

T['a selection from one table says it can be edited, and which columns'] = function()
  eq(state.call.source.kind, 'table')
  eq(state.call.source.name:match('people$') ~= nil, true)
  eq(state.call.columns[1].editable, true)
  eq(state.call.columns[2].editable, true)

  run('select count(*) from people')
  eq(state.call.source, nil)
end

T['a join is editable through each table, but takes no new rows'] = function()
  eq(state.call.source.insertable, true)

  run('create table pets (id integer primary key, owner integer, name text)')
  run('select p.id, p.name, t.id, t.name from people p join pets t on t.owner = p.id')
  eq(state.call.source.kind, 'tables')
  eq(state.call.source.insertable, nil)
  eq(state.call.columns[4].editable, true)
  run('drop table pets')
end

T['a view filters and sorts in the engine, and pages count what it holds'] = function()
  api.view({ filters = { { column = 1, op = 'contains', value = 'O' } } })
  wait('the view should arrive', function()
    return state.call.view_rows == 2
  end)
  eq(#rows(), 2)

  api.view({ sort = { { column = 2, descending = true } } })
  wait('the sort should arrive', function()
    return (rows()[1] or ''):match('^%s*2') ~= nil
  end)
  -- bob's age is NULL, which sorts last whichever way, and carol is filtered out by the `o`.
  eq(rows()[1]:match('^%s*(%d)'), '2')

  api.view({ filters = {}, sort = {} })
  wait('every row should come back', function()
    return state.call.view_rows == nil and #rows() == 3
  end)
end

--- Wait for the result that replaces the current one.
local function next_result(what, condition)
  local before = state.call.call_id
  return function()
    wait(what, function()
      return state.call.call_id ~= before and state.call.state ~= 'executing' and condition()
    end)
  end
end

T['the filter bar docks above the grid and filters in the database'] = function()
  focus_result()
  result.actions.filter()
  local bar = vim.api.nvim_get_current_win()
  eq(vim.bo[vim.api.nvim_win_get_buf(bar)].filetype, 'sqmeow-filter')
  eq(vim.api.nvim_win_get_height(bar), 2)
  eq(#floats(), 0)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'age > 20 or age is null', 'id desc' })
  local arrived = next_result('the filtered result should arrive', function()
    return #rows() == 2
  end)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'mx', false)
  arrived()

  eq(vim.api.nvim_win_is_valid(bar), false)
  eq(rows()[1]:match('^%s*(%d)'), '2')
  eq(result.spec().where, 'age > 20 or age is null')
  helpers.contains(vim.wo[result.window()].winbar, 'where age > 20')
end

T['a result that cannot be queried again is filtered on the rows held with the same SQL'] = function()
  helpers.stub(result, 'queried', function()
    return false
  end)
  local win = focus_result()

  eq(result.filter('nope = 1', ''), false)
  eq(result.spec().where, '')

  eq(result.filter('age > 20 or age is null', 'id desc'), true)
  wait('the held rows should narrow', function()
    return state.call.view_rows == 2
  end)
  eq(rows()[1]:match('^%s*(%d)'), '2')
  helpers.contains(vim.wo[win].winbar, 'where age > 20')

  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.goto_column(2)
  result.actions.filter_cell()
  wait('the cell should narrow them further', function()
    return state.call.view_rows == 1
  end)
  eq(result.spec().where, [[(age > 20 or age is null) AND "name" = 'bob']])

  result.actions.reset_view()
  wait('every row should come back', function()
    return state.call.view_rows == nil and #rows() == 3
  end)
end

T['= and s narrow and order in the database, and R runs the query as written'] = function()
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.goto_column(2)
  local arrived = next_result('the narrowed result should arrive', function()
    return #rows() == 1
  end)
  result.actions.filter_cell()
  arrived()
  eq(result.spec().where, [["name" = 'alice']])

  arrived = next_result('every row should come back', function()
    return #rows() == 3
  end)
  result.actions.reset_view()
  arrived()
  eq(result.spec().where, '')

  vim.api.nvim_win_set_cursor(result.window(), { 3, 0 })
  result.goto_column(3)
  arrived = next_result('the ordered result should arrive', function()
    return #rows() == 3
  end)
  result.actions.sort()
  arrived()
  eq(result.spec().order_by, '"age"')
  -- SQLite puts NULL first when ascending.
  eq(rows()[1]:match('^%s*(%d)'), '2')
end

T['a filter tells apart columns of one name'] = function()
  run('select p.id, q.id from people p join people q on q.id = p.id order by p.id')
  eq(result.filter_names(state.call), { 'id', 'id_2' })
  local arrived = next_result('the filtered result should arrive', function()
    return true
  end)
  eq(result.filter('id_2 > 1', ''), true)
  arrived()
  eq(state.call.state, 'done')
end

T['a condition the database refuses shows its error, and the bar opens with it'] = function()
  focus_result()
  local arrived = next_result('the error should arrive', function()
    return state.call.state == 'error'
  end)
  eq(result.filter('nope > 1', ''), true)
  arrived()
  helpers.contains(table.concat(helpers.result_lines(), '\n'), 'nope')

  result.actions.filter()
  eq(vim.api.nvim_get_current_line(), 'nope > 1')
  require('sqmeow.ui.filter').close()
end

T['staged changes are asked about before a new result replaces them'] = function()
  result.open()
  edit.set({ row = 0 }, 1, 'x')
  local asked, answer = nil, 'Cancel'
  helpers.stub(vim.ui, 'select', function(_, opts, on_choice)
    asked = opts.prompt
    on_choice(answer)
  end)

  eq(result.filter('age > 1', ''), false)
  helpers.contains(asked, '1 staged change would be lost')
  eq(edit.count(), 1)

  answer = 'Discard them'
  local before = state.call.call_id
  api.execute('select id from people', { conn_id = state.call.conn_id, confirmed = true })
  wait('the query should run once the changes are discarded', function()
    return state.call.call_id ~= before and state.call.state == 'done'
  end)
  eq(edit.count(), 0)
end

T['editing applies through a review'] = function()
  result.open()

  edit.set({ row = 0 }, 1, "o'alice")
  edit.toggle_delete({ { row = 1 } })
  edit.add_row()
  edit.set({ insert = 1 }, 1, 'dave')

  local statements = rpc.request('plan', {
    call_id = state.call.call_id,
    changes = edit.changes(),
  })
  eq(#statements, 3)
  -- Deletes, then inserts, then updates, the order DBeaver saves in.
  eq(statements[1]:match('^DELETE') ~= nil, true)
  eq(statements[3]:match('^UPDATE') ~= nil, true)

  local before = state.call.call_id
  edit.apply(state.call, statements)
  wait('the result should be read again after applying', function()
    return state.call.call_id ~= before and state.call.state == 'done' and edit.count() == 0
  end)

  run('select name from people order by id')
  local names = table.concat(rows(), '\n')
  helpers.contains(names, "o'alice")
  helpers.absent(names, 'bob')
  helpers.contains(names, 'dave')
end

T['a cell is changed straight from the split, and q leaves the editor'] = function()
  local win = focus_result()
  -- Line three is the first row, and column zero of it is `id`.
  vim.api.nvim_win_set_cursor(win, { 3, 0 })

  -- Pressed as a user presses it, in one go.
  local value = tostring(result.current_cell().value)
  vim.api.nvim_feedkeys(vim.keycode('i9<Esc><CR>'), 'mx', false)
  eq(edit.staged(0, 0), value .. '9')
  eq(#floats(), 0)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode('i<Esc>q'), 'mx', false)
  eq(#floats(), 0)
  eq(edit.staged(0, 0), value .. '9')
end

T['the cell editor is as tall as the value it holds'] = function()
  local win = focus_result()
  edit.set({ row = 0 }, 1, 'first\nsecond')
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.goto_column(2)

  result.actions.edit_cell()
  local editor = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_height(editor), 2)

  -- Grows with the lines typed in.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
  eq(vim.api.nvim_win_get_height(editor), 3)

  -- And with a line too long for its width, which wraps.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { ('x'):rep(vim.o.columns * 2) })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
  eq(vim.api.nvim_win_get_height(editor) >= 2, true)

  vim.api.nvim_feedkeys(vim.keycode('<Esc>q'), 'mx', false)
  eq(vim.api.nvim_win_is_valid(editor), false)
end

T['a failed apply keeps what was staged'] = function()
  result.open()
  edit.set({ row = 0 }, 0, '3')
  local statements = rpc.request('plan', {
    call_id = state.call.call_id,
    changes = edit.changes(),
  })

  local messages = {}
  helpers.stub(vim, 'notify', function(message)
    table.insert(messages, message)
  end)

  edit.apply(state.call, statements)
  wait('the failure should be reported', function()
    return #messages > 0
  end)
  helpers.contains(messages[1], 'nothing was applied')
  eq(edit.count(), 1)
end

T['the grid moves between its split and its float, keeping its buffer'] = function()
  result.open()
  local buffer = result.buffer()
  result.toggle_float()
  eq(result.is_float(), true)
  eq(vim.api.nvim_get_current_buf(), buffer)
  -- Just a bigger view: nothing on it speaks of editing.
  helpers.absent(vim.wo.winbar, 'edit')
  -- It has a border, drawn in a window of its own around the grid, as every dialog's is.
  eq(#floats(), 2)
  result.toggle_float()
  eq(result.is_float(), false)
  eq(result.is_open(), true)
  eq(vim.api.nvim_buf_is_valid(buffer), true)
end

T['an export without a file goes to the clipboard, as the grid shows it'] = function()
  vim.fn.setreg('"', '')
  result.spec().hidden = { [2] = true }
  api.export({ clipboard = true, format = 'csv' })
  wait('the export should be copied', function()
    return vim.fn.getreg('"') ~= ''
  end)
  eq(vim.split(vim.fn.getreg('"'), '\n')[1], 'id,name')
end

T['the export dialog previews what it writes, scrolls it, and gives focus back'] = function()
  local win = focus_result()
  api.export()

  local function preview()
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buffer = vim.api.nvim_win_get_buf(window)
      if vim.tbl_contains({ 'csv', 'json' }, vim.bo[buffer].filetype) then
        return window, vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
      end
    end
  end

  -- The header and a line per row, whatever the cases before this one left in the table.
  local _, preview_lines = preview()
  eq(preview_lines[1], 'id,name,age')
  eq(#preview_lines, state.call.rows + 1)

  -- The format is the first field, and choosing JSON renders the rows as JSON instead.
  vim.api.nvim_feedkeys(vim.keycode('gg<CR>'), 'mx', false)
  local window
  window, preview_lines = preview()
  eq(preview_lines[1], '[')
  eq(vim.bo[vim.api.nvim_win_get_buf(window)].filetype, 'json')

  vim.api.nvim_feedkeys(vim.keycode('<C-d>'), 'mx', false)
  eq(vim.fn.getwininfo(window)[1].topline > 1, true)
  vim.api.nvim_feedkeys(vim.keycode('<C-u>'), 'mx', false)
  eq(vim.fn.getwininfo(window)[1].topline, 1)

  vim.api.nvim_feedkeys('q', 'mx', false)
  eq(vim.api.nvim_get_current_win(), win)
end

T['an EXPLAIN that is run shows its plan as lines rather than a grid'] = function()
  run([[explain query plan
        select * from people where id in (select id from people where name = 'x')]])

  local lines = helpers.result_lines()
  local text = table.concat(lines, '\n')
  helpers.contains(text, 'SCAN')
  -- Nested under the step it belongs to, and not drawn as a grid of columns.
  eq(
    vim.iter(lines):any(function(line)
      return line:match('^  %S') ~= nil
    end),
    true
  )
  helpers.absent(text, '│')
end

T['D stages a copy of the row without its primary key'] = function()
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  local row = rpc.request('row', { call_id = state.call.call_id, row = 0 })

  result.actions.duplicate_row()
  eq(edit.inserts()[1], { [1] = row[2].value, [2] = row[3].is_null and vim.NIL or row[3].value })
  eq(vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_buf_line_count(result.buffer()))
end

T['applying opens the new result at the same page and cursor'] = function()
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  edit.set({ row = 1 }, 2, '44')
  local statements = rpc.request('plan', { call_id = state.call.call_id, changes = edit.changes() })

  local before = state.call.call_id
  edit.apply(state.call, statements)
  wait('the result should be read again after applying', function()
    return state.call.call_id ~= before and state.call.state == 'done' and edit.count() == 0
  end)
  eq(vim.api.nvim_win_get_cursor(result.window())[1], 4)
end

T['an export as SQL writes an INSERT per row into the table'] = function()
  vim.fn.setreg('"', '')
  api.export({ clipboard = true, format = 'sql', limit = 1 })
  wait('the export should be copied', function()
    return vim.fn.getreg('"') ~= ''
  end)
  helpers.contains(vim.fn.getreg('"'), 'INSERT INTO "people" ("id", "name", "age") VALUES (1, ')
end

T['an export as SQL can batch rows, create the table, and ignore the view'] = function()
  api.view({ filters = { { column = 1, op = 'contains', value = 'O' } } })
  wait('the view should arrive', function()
    return state.call.view_rows == 2
  end)

  local function copied(opts)
    vim.fn.setreg('"', '')
    api.export(vim.tbl_extend('force', { clipboard = true, format = 'sql' }, opts))
    wait('the export should be copied', function()
      return vim.fn.getreg('"') ~= ''
    end)
    return vim.fn.getreg('"')
  end

  local text = copied({ batch = true, create = true })
  helpers.contains(text, 'CREATE TABLE "people" (')
  eq(select(2, text:gsub('INSERT INTO', '')), 1)
  eq(select(2, text:gsub('%),\n', '')), 1)

  text = copied({ all = true })
  eq(select(2, text:gsub('INSERT INTO', '')), 3)

  api.view({ filters = {}, sort = {} })
  wait('every row should come back', function()
    return state.call.view_rows == nil
  end)
end

T['g= stages a SQL expression that the plan writes as is'] = function()
  focus_result()
  edit.set({ row = 0 }, 1, { sql = "upper('ann')" })
  helpers.contains(
    table.concat(vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false), '\n'),
    '= upp'
  )

  local statements = rpc.request('plan', { call_id = state.call.call_id, changes = edit.changes() })
  helpers.contains(statements[1], 'SET "name" = upper(\'ann\')')
  edit.reset()
end

T['a row added outside the query is still shown after applying'] = function()
  run("select id, name, age from people where name <> 'zed' order by id")
  result.open()
  edit.add_row({ [1] = 'zed' })
  local statements = rpc.request('plan', { call_id = state.call.call_id, changes = edit.changes() })

  local before = state.call.call_id
  edit.apply(state.call, statements)
  wait('the result should be read again after applying', function()
    return state.call.call_id ~= before and state.call.state == 'done' and edit.count() == 0
  end)
  eq(state.call.appended, 1)
  helpers.contains(rows()[#rows()], 'zed')
  run("delete from people where name = 'zed'")
end

T[']r and [r move between the results of several statements'] = function()
  focus_result()
  run('select 1 as first; update people set age = age where id = 0; select 2 as second')
  eq(#state.call.results, 3)
  helpers.contains(vim.wo[result.window()].winbar, 'result 3/3')
  helpers.contains(helpers.result_header()[1], 'second')

  result.actions.next_result()
  helpers.contains(helpers.result_header()[1], 'first')
  helpers.contains(vim.wo[result.window()].winbar, 'result 1/3')
  -- The update between them is a result of its own, which says how many rows it changed.
  result.actions.next_result()
  helpers.contains(vim.wo[result.window()].winbar, '0 rows affected')
  result.actions.prev_result()
  result.actions.prev_result()
  helpers.contains(helpers.result_header()[1], 'second')
end

T['gK on a result with no table to trace shows the one its query reads from'] = function()
  run('select count(*) as n from people')
  eq(select(2, result.read_from(state.call)), 'people')
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.actions.structure()
  local popup
  wait('the structure should open', function()
    popup = helpers.find_win(function(_, buf)
      return vim.bo[buf].filetype == 'sqmeow-structure'
    end)
    return popup ~= nil
  end)
  local text =
    table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false), '\n')
  helpers.contains(text, 'CREATE TABLE people')
  require('sqmeow.ui.structure').close()
end

T['gK shows the structure of the table the column is from'] = function()
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.actions.structure()

  local popup
  wait('the structure should open', function()
    popup = helpers.find_win(function(_, buf)
      return vim.bo[buf].filetype == 'sqmeow-structure'
    end)
    return popup ~= nil
  end)
  local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false)
  helpers.contains(table.concat(text, '\n'), 'age')
  helpers.contains(table.concat(text, '\n'), 'primary key')
  require('sqmeow.ui.structure').close()
end

T['a DuckDB EXPLAIN shows its plan as lines'] = function()
  local id = helpers.connect('duckdb::memory:', { name = 'plans' })
  MiniTest.finally(function()
    api.disconnect(id)
  end)
  run('explain select 42', { conn_id = id })
  local text = table.concat(helpers.result_lines(), '\n')
  helpers.absent(text, 'explain_value')
  helpers.contains(text, 'PROJECTION')
end

T['a DELETE without WHERE asks first, and runs only when told to'] = function()
  run('create table doomed (id integer)')
  run('insert into doomed values (1)')
  local asked, answer = nil, 'Cancel'
  helpers.stub(vim.ui, 'select', function(_, opts, on_choice)
    asked = opts.prompt
    on_choice(answer)
  end)

  eq(api.execute('delete from doomed'), nil)
  helpers.contains(asked, 'DELETE without WHERE')

  answer = 'Run it'
  local before = state.call.call_id
  api.execute('delete from doomed')
  wait('the delete should run', function()
    return state.call.call_id ~= before and state.call.state == 'done'
  end)
  eq(state.call.affected, 1)
  run('drop table doomed')
end

T['a read-only connection reads, and refuses writes and edits'] = function()
  local id = helpers.connect('sqlite::memory:', { name = 'locked', read_only = true })
  MiniTest.finally(function()
    api.disconnect(id)
  end)
  helpers.contains(state.label(state.connections[id]), 'read-only')
  eq(run('select 1 as one', { conn_id = id }).state, 'done')

  local messages = {}
  helpers.stub(vim, 'notify', function(message)
    table.insert(messages, message)
  end)
  eq(api.execute('create table nope (id integer)', { conn_id = id, confirmed = true }), nil)
  helpers.contains(messages[1], 'read-only')
  result.actions.add_row()
  helpers.contains(messages[2], 'read-only')
end

return T
