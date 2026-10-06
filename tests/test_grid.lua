local MiniTest = require('mini.test')
-- The result grid against a real engine and SQLite.
local helpers = dofile('tests/helpers.lua')

local eq = MiniTest.expect.equality
local state = require('sqmeow.core.state')
local result = require('sqmeow.ui.result')
local edit = require('sqmeow.ui.edit')
local rpc = require('sqmeow.rpc.client')

local wait = helpers.wait_for
local run = helpers.run
local rows = helpers.result_rows

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
      require('sqmeow.api.connection').use(helpers.connect('sqlite::memory:', { name = 'grid' }))
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
      require('sqmeow.api.connection').disconnect()
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
  eq(state.call.capabilities, { query = true, memory = true, filter = true })
  eq(rpc.request('result_capabilities', { call_id = state.call.call_id }), state.call.capabilities)
  require('sqmeow.api.view').view({ filters = { { column = 1, op = 'contains', value = 'O' } } })
  wait('the view should arrive', function()
    return state.call.view_rows == 2
  end)
  eq(#rows(), 2)
  local page = rpc.request('rows', { call_id = state.call.call_id, offset = 0, limit = 10 })
  eq(page.indices, { 1, 2 })
  eq(page.total, 2)

  require('sqmeow.api.view').view({ sort = { { column = 2, descending = true } } })
  wait('the sort should arrive', function()
    return (rows()[1] or ''):match('^%s*2') ~= nil
  end)
  -- bob's age is NULL, which sorts last whichever way, and carol is filtered out by the `o`.
  eq(rows()[1]:match('^%s*(%d)'), '2')

  require('sqmeow.api.view').view({ filters = {}, sort = {} })
  wait('every row should come back', function()
    return state.call.view_rows == nil and #rows() == 3
  end)
end

T['the result view contract keeps the old view request available'] = function()
  local id = state.call.call_id
  eq(
    rpc.request('view', { call_id = id, filters = { { column = 1, op = 'eq', value = 'bob' } } }),
    id
  )
  wait('the legacy view should arrive', function()
    return state.call.view_rows == 1
  end)
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 10 }).indices, { 1 })
end

T['only an explicit refresh requires the original connection'] = function()
  local id = state.call.call_id
  local _, err = rpc.request('result_view', {
    call_id = id,
    refresh = true,
    conn_id = -1,
    sql = state.call.sql,
  })
  helpers.contains(err, 'does not belong')
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 1 }).indices, { 0 })
end

T['all filters use retained rows and only refresh routes to a query'] = function()
  local id = state.call.call_id
  eq(rpc.request('result_view_route', { call_id = id }), 'memory')
  eq(rpc.request('result_view_route', { call_id = id, structured = true }), 'memory')
  eq(rpc.request('result_view_route', { call_id = id, refresh = true }), 'query')
  local memory = rpc.request('result_view', {
    call_id = id,
    structured = true,
    filters = { { column = 1, op = 'eq', value = 'bob' } },
  })
  eq(memory, { route = 'memory', call_id = id })
  wait('the structured view should arrive', function()
    return state.call.view_rows == 1
  end)
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 1 }).indices, { 1 })

  local memory_sql = rpc.request('result_view', {
    call_id = id,
    conn_id = -1,
    sql = 'invalid query that must not be executed',
    where = 'id = 1',
  })
  eq(memory_sql, { route = 'memory', call_id = id })
  wait('the SQL view should use the original rows', function()
    return rpc.request('rows', { call_id = id, offset = 0, limit = 1 }).indices[1] == 0
  end)
end

T['a result that cannot be queried again is filtered with Polars SQL'] = function()
  local id = helpers.connect('sqlite::memory:', { name = 'held-view' })
  run(
    "select 1 as id, 'alice' as name, 30 as age union all select 2, 'bob', null union all select 3, 'carol', 20",
    { conn_id = id }
  )
  require('sqmeow.api.connection').disconnect(id)
  wait('the connection should close', function()
    return state.connections[id] == nil
  end)
  eq(rpc.request('result_view_route', { call_id = state.call.call_id }), 'memory')
  local win = focus_result()

  -- Polars resolves column names while it builds the asynchronous held-row view.
  eq(result.filter('nope = 1', ''), true)
  wait('the invalid filter should be rejected', function()
    return result.spec().where == ''
  end)

  eq(result.filter('age > 20 or age is null', 'id desc'), true)
  wait('the held rows should narrow', function()
    return state.call.view_rows == 2
  end)
  eq(rows()[1]:match('^%s*(%d)'), '2')

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

T['= and s narrow and order held rows, and R restores the snapshot'] = function()
  local id = state.call.call_id
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.goto_column(2)
  result.actions.filter_cell()
  wait('the narrowed view should arrive', function()
    return state.call.view_rows == 1
  end)
  eq(result.spec().where, [["name" = 'alice']])

  result.actions.reset_view()
  wait('every original row should come back', function()
    return state.call.view_rows == nil and #rows() == 3
  end)
  eq(result.spec().where, '')

  vim.api.nvim_win_set_cursor(result.window(), { 3, 0 })
  result.goto_column(3)
  result.actions.sort()
  wait('the ordered view should arrive', function()
    return rows()[1]:match('^%s*(%d)') == '3'
  end)
  eq(result.spec().order_by, '"age" ASC NULLS LAST')
  eq(rows()[3]:match('^%s*(%d)'), '2')
  eq(state.call.call_id, id)
end

T['a filter tells apart columns of one name'] = function()
  run('select p.id, q.id from people p join people q on q.id = p.id order by p.id')
  eq(result.filter_names(state.call), { 'id', 'id_2' })
  eq(result.filter('id_2 > 1', ''), true)
  wait('the duplicate-column view should arrive', function()
    return state.call.view_rows == 2
  end)
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.goto_column(2)
  result.actions.filter_cell()
  wait('the duplicate-column cell should match', function()
    return state.call.view_rows == 1
  end)
  helpers.contains(result.spec().where, '"id_2" = 2')
  eq(state.call.state, 'done')
end

T['an invalid Polars condition keeps the previous view and reports its error'] = function()
  focus_result()
  local id = state.call.call_id
  eq(result.filter('id = 2', ''), true)
  wait('the valid view should arrive', function()
    return state.call.view_rows == 1
  end)
  local messages = {}
  helpers.stub(vim, 'notify', function(message)
    table.insert(messages, message)
  end)
  eq(result.filter('nope > 1', ''), true)
  wait('the invalid view should be rejected', function()
    return #messages > 0
  end)
  helpers.contains(messages[1], 'nope')
  eq(result.spec().where, 'id = 2')
  eq(state.call.call_id, id)
  eq(state.call.state, 'done')
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 10 }).indices, { 1 })
end

T['staged changes are asked about before a new result replaces them'] = function()
  result.open()
  edit.set({ row = 0 }, 1, 'x')
  local asked, answer = false, 'Cancel'
  helpers.stub(vim.ui, 'select', function(_, _, on_choice)
    asked = true
    on_choice(answer)
  end)

  eq(result.rerun(), false)
  eq(asked, true)
  eq(edit.count(), 1)

  answer = 'Discard them'
  local before = state.call.call_id
  require('sqmeow.api.query').execute(
    'select id from people',
    { conn_id = state.call.conn_id, confirmed = true }
  )
  wait('the query should run once the changes are discarded', function()
    return state.call.call_id ~= before and state.call.state == 'done'
  end)
  eq(edit.count(), 0)
end

T['filtering and sorting preserve staged changes without prompting'] = function()
  result.open()
  edit.set({ row = 0 }, 1, 'x')
  helpers.stub(vim.ui, 'select', function()
    error('a local view must not ask to discard edits')
  end)
  local id = state.call.call_id
  result.filter('id = 2', '')
  wait('the local filter should arrive', function()
    return state.call.view_rows == 1
  end)
  eq(state.call.call_id, id)
  eq(edit.count(), 1)
  eq(edit.staged(0, 1), 'x')
  eq(result.spec().where, 'id = 2')
  eq(rows()[1]:match('^%s*(%d)'), '2')
  result.actions.reset_view()
  wait('the original rows should return', function()
    return state.call.view_rows == nil
  end)
  helpers.contains(rows()[1], 'x')
end

T['filters ignore database changes until an explicit refresh reapplies the local view'] = function()
  run('create table view_snapshot (id integer primary key, name text)')
  MiniTest.finally(function()
    run('drop table view_snapshot')
  end)
  run("insert into view_snapshot values (1, 'before'), (2, 'before')")
  run('select id, name from view_snapshot order by id')
  local id = assert(state.call.call_id, 'the snapshot result has an id')
  run("insert into view_snapshot values (3, 'after')")
  require('sqmeow.api.view').reopen(id)
  eq(result.filter('id >= 2', 'id DESC'), true)
  wait('only the original rows should be filtered', function()
    return state.call.view_rows == 1
  end)
  eq(state.call.call_id, id)
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 10 }).indices, { 1 })
  eq(result.rerun(), true)
  wait('refresh should reapply the filter to new data', function()
    return state.call.call_id ~= id and state.call.state == 'done' and state.call.view_rows == 2
  end)
  eq(state.call.rows, 3)
  eq(result.spec().where, 'id >= 2')
  eq(
    rpc.request('rows', { call_id = state.call.call_id, offset = 0, limit = 10 }).indices,
    { 2, 1 }
  )
end

T['SQL filters search all retained pages but never fetch beyond the row cap'] = function()
  local max_rows = require('sqmeow.config').get().query.max_rows
  MiniTest.finally(function()
    rpc.request('configure', { max_rows = max_rows })
  end)
  rpc.request('configure', { max_rows = 13 })
  run([[WITH RECURSIVE numbers(id) AS (
    SELECT 1 UNION ALL SELECT id + 1 FROM numbers WHERE id < 25
  ) SELECT id FROM numbers ORDER BY id]])
  local id = state.call.call_id
  eq(state.call.rows, 13)
  eq(state.call.truncated, true)
  eq(#rows(), 10)
  eq(result.filter('id > 10', 'id DESC'), true)
  wait('rows from the second retained page should match', function()
    return state.call.view_rows == 3
  end)
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 10 }).indices, { 12, 11, 10 })
  eq(result.filter('id > 20', ''), true)
  wait('unretained rows must not be fetched', function()
    return state.call.view_rows == 0
  end)
  eq(state.call.call_id, id)
  result.actions.reset_view()
  wait('reset restores only retained rows', function()
    return state.call.view_rows == nil
  end)
  eq(rpc.request('rows', { call_id = id, offset = 0, limit = 30 }).total, 13)
end

T['applying edits refreshes original rows then reapplies the local filter and sort'] = function()
  run('create table view_edit (id integer primary key, name text)')
  MiniTest.finally(function()
    run('drop table view_edit')
  end)
  run("insert into view_edit values (1, 'alice'), (2, 'bob'), (3, 'carol')")
  run('select id, name from view_edit order by id')
  local win = focus_result()
  local id = state.call.call_id
  eq(result.filter('id >= 2', 'id DESC'), true)
  wait('the filtered rows should arrive', function()
    return state.call.view_rows == 2
  end)
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  eq(result.current_cell().row, 1)
  edit.set({ row = 1 }, 1, 'changed')
  local statements = rpc.request('plan', { call_id = id, changes = edit.changes() })
  edit.apply(state.call, statements)
  wait('the refreshed local view should arrive', function()
    return state.call.call_id ~= id
      and state.call.state == 'done'
      and state.call.view_rows == 2
      and edit.count() == 0
  end)
  eq(state.call.rows, 3)
  eq(result.spec().where, 'id >= 2')
  eq(result.spec().order_by, 'id DESC')
  eq(
    rpc.request('rows', { call_id = state.call.call_id, offset = 0, limit = 10 }).indices,
    { 2, 1 }
  )
  helpers.contains(rows()[2], 'changed')
end

T['numeric-looking text and large floats can be filtered by cell without changing identity'] = function()
  for _, sql in ipairs({
    "SELECT '001' AS value UNION ALL SELECT '1'",
    'SELECT 1e20 AS value UNION ALL SELECT 2e20',
  }) do
    run(sql)
    local win = focus_result()
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    result.actions.filter_cell()
    wait('only the selected original value should match', function()
      return state.call.view_rows == 1
    end)
    eq(rpc.request('rows', { call_id = state.call.call_id, offset = 0, limit = 10 }).indices, { 0 })
  end
end

T['restored MongoDB history uses SQL filters and sorts without a connection'] = function()
  local archive = vim.fn.tempname()
  MiniTest.finally(function()
    vim.fn.delete(archive)
  end)
  local id = assert(
    require('sqmeow.api.query').execute(
      "select 1 as id, 'alice' as name union all select 2, 'bob'",
      { confirmed = true }
    )
  )
  wait('the result should be archived', function()
    return state.call.call_id == id
      and state.call.state == 'done'
      and state.call.archive ~= nil
      and vim.uv.fs_stat(state.call.archive) ~= nil
  end)
  -- Copy a real typed archive; the origin dialect must not affect local SQL syntax.
  vim.fn.writefile(vim.fn.readfile(state.call.archive, 'b'), archive, 'b')
  local restored = assert(require('sqmeow.api.view').restore({
    result = archive,
    dialect = 'mongodb',
    statement = '{"find":"people"}',
  }))
  wait('the historical rows should restore', function()
    return state.call.state == 'done'
  end)
  eq(state.call.conn_id, 0)
  local win = focus_result()
  eq(result.filter("name ILIKE '%AL%'", 'id DESC'), true)
  wait('the MongoDB snapshot should narrow', function()
    return state.call.view_rows == 1
  end)
  eq(state.call.call_id, restored)
  eq(rpc.request('rows', { call_id = restored, offset = 0, limit = 10 }).indices, { 0 })
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  result.goto_column(2)
  result.actions.filter_cell()
  wait('a MongoDB cell should add a SQL condition', function()
    return result.spec().where:find('"name" = \'alice\'', 1, true) ~= nil
  end)
  helpers.absent(result.spec().where, '$and')
  local _, err = rpc.request(
    'result_view',
    { call_id = restored, refresh = true, conn_id = 0, sql = '{"find":"people"}' }
  )
  helpers.contains(err, 'not open')
end

T['unavailable result capabilities prevent filtering'] = function()
  focus_result()
  local request = rpc.request
  helpers.stub(rpc, 'request', function(method, args)
    if method == 'result_capabilities' then
      return nil, 'result 999 is no longer held'
    end
    return request(method, args)
  end)
  local messages = {}
  helpers.stub(vim, 'notify', function(message)
    table.insert(messages, message)
  end)
  eq(result.filter('id = 1', ''), false)
  eq(#messages, 1)
  result.actions.filter()
  eq(#messages, 2)
  eq(require('sqmeow.ui.filter').is_open(), false)
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
  -- Apply deletes, then inserts, then updates.
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
  eq(state.call.state, 'done')
  eq(edit.staged(0, 0), '3')
  eq(edit.count(), 1)
end

T['an export without a file goes to the clipboard, as the grid shows it'] = function()
  vim.fn.setreg('"', '')
  result.spec().hidden = { [2] = true }
  require('sqmeow.api.export').export({ clipboard = true, format = 'csv' })
  wait('the export should be copied', function()
    return vim.fn.getreg('"') ~= ''
  end)
  eq(vim.split(vim.fn.getreg('"'), '\n')[1], 'id,name')
end

T['D stages a copy of the row without its primary key'] = function()
  local win = focus_result()
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  local row = rpc.request('row', { call_id = state.call.call_id, row = 0 })

  result.actions.duplicate_row()
  eq(edit.inserts()[1], { [1] = row[2].value, [2] = row[3].is_null and vim.NIL or row[3].value })
end

T['an export as SQL can batch rows, create the table, and ignore the view'] = function()
  require('sqmeow.api.view').view({ filters = { { column = 1, op = 'contains', value = 'O' } } })
  wait('the view should arrive', function()
    return state.call.view_rows == 2
  end)

  local function copied(opts)
    vim.fn.setreg('"', '')
    require('sqmeow.api.export').export(
      vim.tbl_extend('force', { clipboard = true, format = 'sql' }, opts)
    )
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

  require('sqmeow.api.view').view({ filters = {}, sort = {} })
  wait('every row should come back', function()
    return state.call.view_rows == nil
  end)
end

T['g= stages a SQL expression that the plan writes as is'] = function()
  focus_result()
  edit.set({ row = 0 }, 1, { sql = "upper('ann')" })
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
  eq(state.call.columns[1].name, 'second')

  result.actions.next_result()
  eq(state.call.columns[1].name, 'first')
  -- The update between them is a result of its own, which says how many rows it changed.
  result.actions.next_result()
  eq(state.call.affected, 0)
  result.actions.prev_result()
  result.actions.prev_result()
  eq(state.call.columns[1].name, 'second')
end

T['a DELETE without WHERE asks first, and runs only when told to'] = function()
  run('create table doomed (id integer)')
  run('insert into doomed values (1)')
  local asked, answer = false, 'Cancel'
  helpers.stub(vim.ui, 'select', function(_, _, on_choice)
    asked = true
    on_choice(answer)
  end)

  eq(require('sqmeow.api.query').execute('delete from doomed'), nil)
  eq(asked, true)

  answer = 'Run it'
  local before = state.call.call_id
  require('sqmeow.api.query').execute('delete from doomed')
  wait('the delete should run', function()
    return state.call.call_id ~= before and state.call.state == 'done'
  end)
  eq(state.call.affected, 1)
  run('drop table doomed')
end

T['a read-only connection reads, and refuses writes and edits'] = function()
  local id = helpers.connect('sqlite::memory:', { name = 'locked', read_only = true })
  MiniTest.finally(function()
    require('sqmeow.api.connection').disconnect(id)
  end)
  eq(run('select 1 as one', { conn_id = id }).state, 'done')

  local messages = {}
  helpers.stub(vim, 'notify', function(message)
    table.insert(messages, message)
  end)
  eq(
    require('sqmeow.api.query').execute(
      'create table nope (id integer)',
      { conn_id = id, confirmed = true }
    ),
    nil
  )
  helpers.contains(messages[1], 'read-only')
  result.actions.add_row()
  helpers.contains(messages[2], 'read-only')
end

return T
