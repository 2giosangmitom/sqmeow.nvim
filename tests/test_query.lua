local MiniTest = require('mini.test')
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
local function connect(url, name)
  local id = assert(api.connect(url, { name = name }), 'the engine should accept the connection')
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
--- Turn a page and answer with where the grid ended up.
---
--- Where a page starts is the window's own business now, not something the engine reports, so it is
--- read back from the grid rather than waited for on the summary.
local function page(action)
  action()
  local current, total = result.pages(state.call)
  return { page = current, pages = total, offset = result.offset() }
end

--- Everything the grid buffer holds: the column names, the rule, and the rows.
local function grid()
  return vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false)
end

--- Apply the configuration this suite runs on.
---
--- Column icons are off by default here, and turned on only by the group that tests them: every
--- other case asserts on exact grid lines, and a glyph before each name would make every one of
--- those expectations harder to read without saying anything about the path under test.
local function setup(opts)
  require('sqmeow').setup(vim.tbl_deep_extend('force', {
    ui = { result = { page_size = 4, column_icons = false } },
  }, opts or {}))
end

--- Every extmark the engine put on one line, as `{ group, from, to }` in column order.
local function marks_on(line)
  local found = vim.api.nvim_buf_get_extmarks(
    result.buffer(),
    vim.api.nvim_create_namespace('sqmeow'),
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )

  local spans = vim.tbl_map(function(mark)
    return { group = mark[4].hl_group, from = mark[3], to = mark[4].end_col }
  end, found)
  table.sort(spans, function(left, right)
    return left.from < right.from
  end)
  return spans
end

--- The column names and the rule under them, which the grid begins with.
--- The column names and the rule under them, which the grid opens with.
local function header()
  return vim.list_slice(grid(), 1, 2)
end

--- The data rows, with the header dropped.
local function lines()
  return vim.list_slice(grid(), 3)
end

-- The connection everything but the last group runs on, and the buffer the suite starts in.
local primary, second, home

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      setup()
      home = vim.api.nvim_get_current_buf()
      primary = connect('sqlite::memory:', 'first')
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
  eq(#summary.columns, 2)
end

T['querying']['writes an aligned grid into the buffer'] = function()
  run('select id, name from people order by id')
  eq(header(), { ' id │ name', '────┼──────' })
  eq(lines(), { '  1 │ alice', '  2 │ bob', '  3 │ NULL' })
end

T['querying']['puts the header and the rows in one buffer'] = function()
  run('select id, name from people order by id')

  -- One window, one buffer: the column names, the rule under them, and then the rows.
  eq(grid(), {
    ' id │ name',
    '────┼──────',
    '  1 │ alice',
    '  2 │ bob',
    '  3 │ NULL',
  })
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
  eq(header()[1], ' id │ name')
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
  local current, total = result.pages(state.call)
  eq(current, 1)
  eq(total, 3)
  eq(result.offset(), 0)
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
  eq(result.offset(), 0)
end

T['paging']['keeps column widths steady across pages'] = function()
  -- The whole reason the engine measures over every row rather than over the page on screen: a
  -- column sized from the first four rows would move when the fifth turned out to be wider.
  local first = header()
  page(api.next_page)
  eq(header(), first)
end

T['limits'] = MiniTest.new_set()

T['limits']['stop at the row cap and say so'] = function()
  setup({ query = { max_rows = 5 } })

  local summary = run([[with recursive n(x) as (select 1 union all select x + 1 from n where x < 50)
                        select x from n]])
  eq(summary.rows, 5)
  eq(summary.truncated, true)

  setup()
end

T['column icons'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- ASCII glyphs, so an expectation can be read and a width can be counted.
      setup({
        ui = { result = { column_icons = true } },
        icons = {
          types = {
            text = 't',
            number = 'n',
            boolean = 'b',
            temporal = 'd',
            json = 'j',
            uuid = 'u',
            binary = 'y',
            unknown = '?',
            primary_key = 'K',
            foreign_key = 'k',
          },
        },
      })
    end,
    post_case = function()
      setup()
    end,
  },
})

T['column icons']['marks each column with what it holds'] = function()
  run('select name, score, avatar from people order by id')
  eq(header()[1], ' t name │ n score │ y avatar')
end

T['column icons']['marks a primary key as a key rather than as a number'] = function()
  run('select id, name from people order by id')
  -- `id` is an integer, and that it is the primary key is the more useful thing to say about it.
  eq(header()[1], ' K id │ t name')
end

T['column icons']['does not call an expression a key'] = function()
  run('select count(*) as total from people')
  -- `count(*)` comes from no table at all, so whatever its type is classified as, it cannot be
  -- anyone's primary or foreign key. This is the case that would break if a column's origin were
  -- guessed from its name rather than read from the statement.
  eq(header()[1]:find('K', 1, true), nil)
  eq(header()[1]:find('k', 1, true), nil)
end

T['column icons']['does not widen a column its values already fill'] = function()
  run('select avatar from people order by id')
  -- "avatar" is six wide and `0xdeadbeef` ten, so the glyph and its space fit inside what the
  -- values had already claimed. An icon is free wherever a column is wider than its own name, which
  -- in a real result is most of them.
  eq(header()[1], ' y avatar')
end

T['column icons']['leaves the rows alone'] = function()
  run('select id, name from people order by id')
  -- Only the header carries a glyph. The rows are padded to the same width and nothing else.
  eq(lines(), { '    1 │ alice', '    2 │ bob', '    3 │ NULL' })
end

T['column icons']['colours each glyph by what it stands for'] = function()
  run('select id, name from people order by id')

  local groups = vim.tbl_map(function(span)
    return span.group
  end, marks_on(1))
  -- One group per glyph, and the column names in the header's own group beside them.
  eq(vim.tbl_contains(groups, 'SqmeowHeader'), true)
  eq(vim.tbl_contains(groups, 'SqmeowIconKeyPrimary'), true)
  eq(vim.tbl_contains(groups, 'SqmeowIconTypeText'), true)
end

T['column icons']['covers the glyph and nothing beside it'] = function()
  run('select id from people order by id')

  local glyph
  for _, span in ipairs(marks_on(1)) do
    if span.group == 'SqmeowIconKeyPrimary' then
      glyph = span
    end
  end

  assert(glyph, 'the primary key glyph should be marked')
  eq(header()[1]:sub(glyph.from + 1, glyph.to), 'K')
end

T['column icons']['colours a null apart from a value'] = function()
  run('select name from people order by id')

  local groups = {}
  for line = 3, 5 do
    for _, span in ipairs(marks_on(line)) do
      groups[span.group] = true
    end
  end
  -- The third row's name is NULL, and reads as a null rather than as the text the others are.
  eq(groups['SqmeowNull'], true)
  eq(groups['SqmeowText'], true)
end

T['column icons']['draws every line of its own in one group'] = function()
  run('select id, name from people order by id')

  local function groups(line)
    return vim.tbl_map(function(span)
      return span.group
    end, marks_on(line))
  end

  -- The rule under the names and the separators between the columns are lines the grid draws
  -- itself rather than anything the result said. One group for all of them, so a colourscheme
  -- cannot end up painting the horizontal one differently from the vertical ones.
  eq(groups(2), { 'SqmeowRule' })
  eq(vim.tbl_contains(groups(1), 'SqmeowRule'), true)
  eq(vim.tbl_contains(groups(3), 'SqmeowRule'), true)
end

T['column icons']['colours the separator glyph and not the gap around it'] = function()
  run('select id, name from people order by id')

  local separator
  for _, span in ipairs(marks_on(3)) do
    if span.group == 'SqmeowRule' then
      separator = span
    end
  end

  assert(separator, 'the separator should be marked')
  local line = vim.api.nvim_buf_get_lines(result.buffer(), 2, 3, false)[1]
  -- A colourscheme that gives the group a background should paint the glyph, not the space beside
  -- it, so the mark covers exactly the one character.
  eq(line:sub(separator.from + 1, separator.to), '│')
end

T['column icons']['can be turned off'] = function()
  setup({ ui = { result = { column_icons = false } } })
  run('select id, name from people order by id')
  eq(header()[1], ' id │ name')
  -- The values are still coloured: the glyphs are what was turned off, not the highlighting.
  local groups = vim.tbl_map(function(span)
    return span.group
  end, marks_on(3))
  eq(vim.tbl_contains(groups, 'SqmeowNumber'), true)
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

T['row detail']['opens the row in a popup that q closes'] = function()
  run('select id, name from people order by id')
  local detail = require('sqmeow.ui.detail')
  detail.open(0)
  MiniTest.finally(detail.close)

  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, 'sqmeow-row')
  -- A float. nui places it inside its border window, so it is relative to that window.
  eq(vim.api.nvim_win_get_config(0).relative ~= '', true)
  local shown = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#shown, 2)
  eq(shown[2]:find('^name%s+%S+%s+alice$') ~= nil, true)

  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_buf_is_valid(buf), false)
end

T['choosing a connection'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      second = connect('sqlite::memory:', 'second')
    end,
    post_case = function()
      api.disconnect(second)
      state.current = primary
      -- Back to a buffer that names no connection, so one case cannot decide where the next
      -- one's query goes. Earlier cases may have wiped the one the suite started in.
      if not vim.api.nvim_buf_is_valid(home) then
        home = vim.api.nvim_create_buf(false, true)
      end
      vim.api.nvim_set_current_buf(home)
    end,
  },
})

--- Run SQL from a buffer tied to one connection by name.
---@return table|nil summary
local function run_bound(name, sql)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].sqmeow_connection = name
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { sql })

  local call_id = api.execute_buffer()
  if not call_id then
    return nil
  end

  vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
  end, 10)
  return state.call
end

T['choosing a connection']['falls to the active one when the buffer names none'] = function()
  api.use(second)
  eq(api.target().id, second)

  api.use(primary)
  eq(api.target().id, primary)
end

T['choosing a connection']['prefers what the buffer names'] = function()
  -- The active connection is the first one, and the query still goes to the second.
  api.use(primary)
  local summary = run_bound('second', 'select 1 as one')

  eq(summary.state, 'done')
  eq(summary.conn_id, second)
end

T['choosing a connection']['refuses a buffer tied to something that is not open'] = function()
  local summary = run_bound('gone', 'select 1 as one')
  eq(summary, nil)

  local _, err = api.target()
  eq(err, '`gone` is not open')
end

T['choosing a connection']['names the result after the connection it came from'] = function()
  api.use(second)
  run('select 1 as one')

  -- Switching afterwards must not relabel a grid that came from somewhere else.
  api.use(primary)
  result.update_winbar(state.call)

  local winbar = vim.wo[result.open()].winbar
  eq(winbar:find('second', 1, true) ~= nil, true)
end

return T
