-- The whole stack, end to end: the plugin asks, the engine queries SQLite, the engine writes the
-- grid into the buffer. This is the test that catches a break anywhere along that path.

local eq = MiniTest.expect.equality
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')
local result = require('sqmeow.ui.result')

local TIMEOUT = 5000

--- Ask for a connection and wait for the engine to say how it went.
---
--- A connection that fails is dropped from the mirrored state, so "settled" means either the entry
--- reports a final state or it is gone.
local function connect(url)
  local id = assert(api.connect(url), 'the engine should accept the connection')
  local settled = vim.wait(TIMEOUT, function()
    local connection = state.connections[id]
    return connection == nil or connection.state ~= 'connecting'
  end, 10)
  assert(settled, 'the connection should settle')
  return id
end

--- Run SQL and wait for the engine to finish with it.
local function run(sql)
  local call_id = api.execute(sql)
  if not call_id then
    return nil
  end

  local settled = vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
  end, 10)
  assert(settled, 'the query should settle: ' .. sql)
  return state.call
end

--- Turn a page and wait for the engine to repaint.
local function page(action)
  local before = state.call.offset
  action()
  vim.wait(TIMEOUT, function()
    return state.call.offset ~= before
  end, 10)
  return state.call
end

--- Everything the grid buffer holds: the column names, the rule, and the rows.
local function grid()
  return vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false)
end

--- The column names and the rule under them, which the grid begins with.
local function header()
  return vim.list_slice(grid(), 1, 2)
end

--- The data rows, with the header dropped.
local function lines()
  return vim.list_slice(grid(), 3)
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ ui = { result = { page_size = 4 } } })
      connect('sqlite::memory:')
      run('create table people (id integer primary key, name text, score real, avatar blob)')
      run([[insert into people (id, name, score, avatar) values
              (1, 'alice', 9.5, x'deadbeef'),
              (2, 'bob', 7.0, null),
              (3, null, null, null)]])
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

T['connecting'] = MiniTest.new_set()

T['connecting']['reports the dialect it found'] = function()
  local connection = state.current_connection()
  eq(connection.state, 'connected')
  eq(connection.dialect, 'sqlite')
end

T['connecting']['reports a url it cannot open'] = function()
  local id = connect('mongodb://localhost/x')
  -- A failed connection is forgotten rather than left in the list as a thing to pick.
  eq(state.connections[id], nil)
end

T['connecting']['leaves the working connection current'] = function()
  eq(state.current_connection().dialect, 'sqlite')
end

T['querying'] = MiniTest.new_set()

T['querying']['returns rows'] = function()
  local summary = run('select id, name from people order by id')
  eq(summary.state, 'done')
  eq(summary.rows, 3)
  eq(summary.columns, 2)
end

T['querying']['writes an aligned grid into the buffer'] = function()
  run('select id, name from people order by id')
  eq(header(), { ' id │ name', '────┼──────' })
  eq(lines(), { '  1 │ alice', '  2 │ bob', '  3 │ NULL' })
end

T['querying']['puts the header and the rows in one buffer'] = function()
  run('select id, name from people order by id')

  -- One window, one buffer, the way nvim-dbee does it. The engine says how many lines come
  -- before the first row, so nothing downstream has to count them.
  eq(grid(), {
    ' id │ name',
    '────┼──────',
    '  1 │ alice',
    '  2 │ bob',
    '  3 │ NULL',
  })
  eq(state.call.header_lines, 2)
end

T['querying']['right-aligns numbers and left-aligns text'] = function()
  run('select id, name from people where id = 1')
  eq(lines()[1], '  1 │ alice')
end

T['querying']['shows a blob as hexadecimal'] = function()
  run('select avatar from people where id = 1')
  eq(lines()[1], ' 0xdeadbeef')
end

T['querying']['keeps the header when nothing matches'] = function()
  local summary = run('select id, name from people where 0')
  eq(summary.rows, 0)
  -- The columns still show, which is what makes "no rows" different from "something broke".
  eq(header(), { ' id │ name', '────┼─────' })
  eq(lines(), {})
end

T['querying']['counts rows a statement changed'] = function()
  local summary = run('update people set score = score where id in (1, 2)')
  eq(summary.rows, 0)
  eq(summary.affected, 2)
end

T['querying']['runs several statements and shows the last'] = function()
  local summary = run('select 1 as first; select 2 as second')
  eq(summary.rows, 1)
  eq(header()[1], ' second')
end

T['querying']['does not split on a semicolon inside a string'] = function()
  local summary = run([[select 'a;b' as v]])
  eq(summary.rows, 1)
  eq(lines()[1], ' a;b')
end

T['querying']['refuses an empty query'] = function()
  eq(api.execute('   \n  '), nil)
  eq(api.execute('-- just a comment'), nil)
end

T['querying']['leaves the buffer unmodifiable between paints'] = function()
  run('select id from people')
  eq(vim.bo[result.buffer()].modifiable, false)
end

T['errors'] = MiniTest.new_set()

T['errors']['report the database message'] = function()
  local summary = run('select nope from people')
  eq(summary.state, 'error')
  eq(summary.error:find('nope', 1, true) ~= nil, true)
end

T['errors']['carry the line the statement started on'] = function()
  local summary = run('select 1;\nselect nope from people')
  eq(summary.state, 'error')
  eq(summary.start_line, 1)
end

T['errors']['leave the connection usable'] = function()
  run('select nope from people')
  eq(run('select id from people').state, 'done')
end

T['paging'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      run([[with recursive n(x) as (select 1 union all select x + 1 from n where x < 10)
            select x from n]])
    end,
  },
})

T['paging']['starts on the first page'] = function()
  eq(state.call.page, 1)
  eq(state.call.pages, 3)
  eq(state.call.offset, 0)
end

T['paging']['shows only a page of rows at a time'] = function()
  eq(#lines(), 4)
end

T['paging']['moves forward'] = function()
  local summary = page(api.next_page)
  eq(summary.page, 2)
  eq(lines()[1], '  5')
end

T['paging']['moves back'] = function()
  page(api.next_page)
  local summary = page(api.prev_page)
  eq(summary.page, 1)
  eq(lines()[1], '  1')
end

T['paging']['stops at the last page rather than emptying the view'] = function()
  local summary = page(api.last_page)
  eq(summary.page, 3)
  -- Ten rows over pages of four leaves two on the last page.
  eq(#lines(), 2)
end

T['paging']['stops at the first page going back'] = function()
  api.prev_page()
  vim.wait(200, function()
    return false
  end, 10)
  eq(state.call.offset, 0)
end

T['paging']['keeps column widths steady across pages'] = function()
  local first = header()[2]
  page(api.next_page)
  eq(header()[2], first)
end

T['limits'] = MiniTest.new_set()

T['limits']['stop at the row cap and say so'] = function()
  require('sqmeow').setup({ query = { max_rows = 5 }, ui = { result = { page_size = 4 } } })

  local summary = run([[with recursive n(x) as (select 1 union all select x + 1 from n where x < 50)
                        select x from n]])
  eq(summary.rows, 5)
  eq(summary.truncated, true)

  require('sqmeow').setup({ ui = { result = { page_size = 4 } } })
end

T['statement under the cursor'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- A buffer of several statements, so choosing the right one is observable.
      vim.cmd('enew')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        'select 1 as first;',
        '',
        'select 2 as second,',
        '       3 as third;',
        '',
        "select 'a;b' as fourth;",
      })
    end,
    post_case = function()
      vim.cmd('bwipeout!')
    end,
  },
})

--- Put the cursor on a line, run what it is in, and answer with the column that came back.
local function statement_at(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  local call_id = assert(api.execute_statement())
  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
  end, 10))
  return header()[1]
end

T['statement under the cursor']['runs the one the cursor is in'] = function()
  eq(statement_at(1), ' first')
  eq(statement_at(6), ' fourth')
end

T['statement under the cursor']['runs a statement spanning several lines'] = function()
  eq(statement_at(3), ' second │ third')
  eq(statement_at(4), ' second │ third')
end

T['statement under the cursor']['picks the statement above a blank line'] = function()
  eq(statement_at(2), ' first')
end

T['statement under the cursor']['runs one statement, not the whole buffer'] = function()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local call_id = assert(api.execute_statement())
  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
  end, 10))
  eq(state.call.rows, 1)
end

T['errors in a buffer'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.cmd('bwipeout!')
    end,
  },
})

T['errors in a buffer']['become a diagnostic on the failing statement'] = function()
  local diagnostics = require('sqmeow.diagnostics')

  vim.cmd('enew')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'select 1;', 'select nope_at_all;' })

  local call_id = assert(api.execute_buffer())
  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state == 'error'
  end, 10))

  local found = vim.diagnostic.get(buf, { namespace = diagnostics.namespace })
  eq(#found, 1)
  eq(found[1].lnum, 1)
  eq(found[1].message:find('nope_at_all', 1, true) ~= nil, true)

  -- A query that works clears the error it replaced.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'select 1;' })
  local ok_id = assert(api.execute_buffer())
  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == ok_id and state.call.state == 'done'
  end, 10))
  eq(#vim.diagnostic.get(buf, { namespace = diagnostics.namespace }), 0)
end

T['exporting'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      run('select id, name from people order by id')
      vim.fn.setreg('"', 'untouched')
    end,
  },
})

--- Wait for the engine to finish an export and put the register's contents back.
local function exported()
  assert(
    vim.wait(TIMEOUT, function()
      return vim.fn.getreg('"') ~= 'untouched'
    end, 10),
    'the export should reach the register'
  )
  return vim.fn.getreg('"')
end

T['exporting']['yanks one cell exactly as it is'] = function()
  -- Line three, because the grid opens with the column names and the rule under them.
  vim.api.nvim_win_set_cursor(result.open(), { 3, 6 })
  result.actions.yank_cell()
  eq(exported(), 'alice')
end

T['exporting']['yanks a row as csv'] = function()
  vim.api.nvim_win_set_cursor(result.open(), { 3, 0 })
  result.actions.yank_row()
  eq(exported(), 'id,name\n1,alice\n')
end

T['exporting']['yanks nothing when the cursor is on the header'] = function()
  vim.api.nvim_win_set_cursor(result.open(), { 1, 0 })
  eq(result.current_cell(), nil)

  result.actions.yank_cell()
  eq(vim.fn.getreg('"'), 'untouched')
end

T['exporting']['yanks the page as csv'] = function()
  result.actions.yank_page()

  local text = exported()
  eq(text:find('id,name', 1, true), 1)
  -- NULL becomes an empty field, which is the only thing CSV can say.
  eq(text:find('3,\n', 1, true) ~= nil, true)
end

T['exporting']['writes the whole result to a file'] = function()
  local path = vim.fn.tempname() .. '.json'
  api.export({ format = 'json', path = path })

  assert(
    vim.wait(TIMEOUT, function()
      return vim.uv.fs_stat(path) ~= nil
    end, 10),
    'the file should be written'
  )

  local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  eq(#decoded, 3)
  eq(decoded[1].name, 'alice')
  -- JSON can say null, so it does.
  eq(decoded[3].name, vim.NIL)
  vim.fn.delete(path)
end

T['exporting']['reports a path it cannot write'] = function()
  api.export({ format = 'csv', path = '/nonexistent/dir/out.csv' })
  -- Nothing is written and nothing crashes; the failure arrives as a notification.
  vim.wait(300, function()
    return false
  end, 10)
end

T['row detail'] = MiniTest.new_set()

T['row detail']['reads one row from the engine'] = function()
  run('select id, name from people order by id')

  local columns = require('sqmeow.rpc').request('row', { call_id = state.call.call_id, row = 0 })
  eq(#columns, 2)
  eq(columns[1].name, 'id')
  eq(columns[1].value, '1')
  eq(columns[2].value, 'alice')
  eq(columns[2].is_null, false)
end

T['row detail']['says a null is a null'] = function()
  run('select name from people where id = 3')

  local columns = require('sqmeow.rpc').request('row', { call_id = state.call.call_id, row = 0 })
  eq(columns[1].is_null, true)
end

T['row detail']['refuses a row past the end'] = function()
  run('select id from people')

  local columns, err = require('sqmeow.rpc').request('row', {
    call_id = state.call.call_id,
    row = 99,
  })
  eq(columns, nil)
  eq(err ~= nil, true)
end

return T
