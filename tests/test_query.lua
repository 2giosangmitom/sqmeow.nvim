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

local function lines()
  return vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false)
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
  eq(lines(), {
    ' id │ name',
    '────┼──────',
    '  1 │ alice',
    '  2 │ bob',
    '  3 │ NULL',
  })
end

T['querying']['right-aligns numbers and left-aligns text'] = function()
  run('select id, name from people where id = 1')
  local row = lines()[3]
  eq(row, '  1 │ alice')
end

T['querying']['shows a blob as hexadecimal'] = function()
  run('select avatar from people where id = 1')
  eq(lines()[3], ' 0xdeadbeef')
end

T['querying']['keeps the header when nothing matches'] = function()
  local summary = run('select id, name from people where 0')
  eq(summary.rows, 0)
  eq(lines(), { ' id │ name', '────┼─────' })
end

T['querying']['counts rows a statement changed'] = function()
  local summary = run('update people set score = score where id in (1, 2)')
  eq(summary.rows, 0)
  eq(summary.affected, 2)
end

T['querying']['runs several statements and shows the last'] = function()
  local summary = run('select 1 as first; select 2 as second')
  eq(summary.rows, 1)
  eq(lines()[1], ' second')
end

T['querying']['does not split on a semicolon inside a string'] = function()
  local summary = run([[select 'a;b' as v]])
  eq(summary.rows, 1)
  eq(lines()[3], ' a;b')
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
  -- Two lines of header plus the page size.
  eq(#lines(), 2 + 4)
end

T['paging']['moves forward'] = function()
  local summary = page(api.next_page)
  eq(summary.page, 2)
  eq(lines()[3], '  5')
end

T['paging']['moves back'] = function()
  page(api.next_page)
  local summary = page(api.prev_page)
  eq(summary.page, 1)
  eq(lines()[3], '  1')
end

T['paging']['stops at the last page rather than emptying the view'] = function()
  local summary = page(api.last_page)
  eq(summary.page, 3)
  -- Ten rows over pages of four leaves two on the last page.
  eq(#lines(), 2 + 2)
end

T['paging']['stops at the first page going back'] = function()
  api.prev_page()
  vim.wait(200, function()
    return false
  end, 10)
  eq(state.call.offset, 0)
end

T['paging']['keeps column widths steady across pages'] = function()
  local first = lines()[2]
  page(api.next_page)
  eq(lines()[2], first)
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

T['status'] = MiniTest.new_set()

T['status']['describes the session for a statusline'] = function()
  run('select id from people')
  local status = api.status()

  eq(status.dialect, 'sqlite')
  eq(status.state, 'done')
  eq(status.rows, 3)
  eq(type(status.connection), 'string')
end

return T
