local MiniTest = require('mini.test')
-- The result grid against a real engine and SQLite: filtering and sorting in the engine, editing
-- through a review, copying to the clipboard, and showing a query plan.

local eq = MiniTest.expect.equality
local api = require('sqmeow.api')
local state = require('sqmeow.state')
local result = require('sqmeow.ui.result')
local edit = require('sqmeow.ui.edit')

local TIMEOUT = 5000

local function wait(what, condition)
  assert(vim.wait(TIMEOUT, condition, 10), what)
end

--- Run SQL and wait for the engine to finish with it.
local function run(sql, opts)
  local call_id = assert(api.execute(sql, opts), 'the query should be accepted: ' .. sql)
  wait('the query should settle: ' .. sql, function()
    return state.call and state.call.call_id == call_id and state.call.state ~= 'executing'
  end)
  return state.call
end

--- The data rows of the grid, with the header dropped.
local function rows()
  return vim.list_slice(vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false), 3)
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ ui = { result = { page_size = 10, column_icons = false } } })
      local id = assert(api.connect('sqlite::memory:', { name = 'grid' }))
      wait('the connection should open', function()
        return state.connections[id] and state.connections[id].state == 'connected'
      end)
      api.use(id)
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

T['editing applies through a review'] = function()
  result.open()

  edit.set({ row = 0 }, 1, "o'alice")
  edit.toggle_delete({ { row = 1 } })
  edit.add_row()
  edit.set({ insert = 1 }, 1, 'dave')

  local statements = require('sqmeow.rpc').request('plan', {
    call_id = state.call.call_id,
    changes = edit.changes(),
  })
  eq(#statements, 3)
  eq(statements[1]:match('^UPDATE') ~= nil, true)

  local before = state.call.call_id
  edit.apply(state.call.conn_id, statements)
  wait('the result should be read again after applying', function()
    return state.call.call_id ~= before and state.call.state == 'done' and edit.count() == 0
  end)

  run('select name from people order by id')
  local names = table.concat(rows(), '\n')
  eq(names:find("o'alice", 1, true) ~= nil, true)
  eq(names:find('bob', 1, true), nil)
  eq(names:find('dave', 1, true) ~= nil, true)
end

T['a cell is changed straight from the split, and q leaves the editor'] = function()
  local win = result.open()
  vim.api.nvim_set_current_win(win)
  -- Line three is the first row, and column zero of it is `id`.
  vim.api.nvim_win_set_cursor(win, { 3, 0 })

  local function floats()
    return #vim.tbl_filter(function(window)
      return vim.api.nvim_win_get_config(window).relative ~= ''
    end, vim.api.nvim_tabpage_list_wins(0))
  end

  -- Pressed as a user presses it, in one go: `feedkeys` ends an insert left open when its keys run
  -- out. The editor opens typing, after what the cell holds, so the `9` goes on the end of the
  -- value. Opened in normal mode, the `9` would be a count and `<Esc>` would cancel the editor.
  local value = tostring(result.current_cell().value)
  vim.api.nvim_feedkeys(vim.keycode('i9<Esc><CR>'), 'mx', false)
  eq(edit.staged(0, 0), value .. '9')
  eq(floats(), 0)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode('i<Esc>q'), 'mx', false)
  eq(floats(), 0)
  eq(edit.staged(0, 0), value .. '9')
end

T['the cell editor is as tall as the value it holds'] = function()
  local win = result.open()
  vim.api.nvim_set_current_win(win)
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
  local statements = require('sqmeow.rpc').request('plan', {
    call_id = state.call.call_id,
    changes = edit.changes(),
  })

  local messages = {}
  local notify = vim.notify
  vim.notify = function(message)
    table.insert(messages, message)
  end
  MiniTest.finally(function()
    vim.notify = notify
  end)

  edit.apply(state.call.conn_id, statements)
  wait('the failure should be reported', function()
    return #messages > 0
  end)
  eq(messages[1]:find('nothing was applied', 1, true) ~= nil, true)
  eq(edit.count(), 1)
end

T['the grid moves between its split and its float, keeping its buffer'] = function()
  result.open()
  local buffer = result.buffer()
  result.toggle_float()
  eq(result.is_float(), true)
  eq(vim.api.nvim_get_current_buf(), buffer)
  -- Just a bigger view: nothing on it speaks of editing.
  eq(vim.wo.winbar:find('edit', 1, true), nil)
  -- It has a border, drawn in a window of its own around the grid, as every dialog's is.
  local floats = vim.tbl_filter(function(window)
    return vim.api.nvim_win_get_config(window).relative ~= ''
  end, vim.api.nvim_tabpage_list_wins(0))
  eq(#floats, 2)
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
  local win = result.open()
  vim.api.nvim_set_current_win(win)
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
  local _, lines = preview()
  eq(lines[1], 'id,name,age')
  eq(#lines, state.call.rows + 1)

  -- The format is the first field, and choosing JSON renders the rows as JSON instead.
  vim.api.nvim_feedkeys(vim.keycode('gg<CR>'), 'mx', false)
  local window
  window, lines = preview()
  eq(lines[1], '[')
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

  local lines = vim.api.nvim_buf_get_lines(result.buffer(), 0, -1, false)
  local text = table.concat(lines, '\n')
  eq(text:find('SCAN', 1, true) ~= nil, true)
  -- Nested under the step it belongs to, and not drawn as a grid of columns.
  eq(
    vim.iter(lines):any(function(line)
      return line:match('^  %S') ~= nil
    end),
    true
  )
  eq(text:find('│', 1, true), nil)
end

return T
