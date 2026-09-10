local eq = MiniTest.expect.equality
local editor = require('sqmeow.ui.editor')
local detail = require('sqmeow.ui.detail')
local diagnostics = require('sqmeow.diagnostics')
local layout = require('sqmeow.ui.layout')
local log = require('sqmeow.ui.log')
local state = require('sqmeow.state')

local T = MiniTest.new_set()

T['scratchpad'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
    end,
  },
})

T['scratchpad']['names a file after the connection'] = function()
  eq(vim.fs.basename(editor.path('dev')), 'dev.sql')
end

T['scratchpad']['makes a connection name safe to use as a file name'] = function()
  eq(editor.slug('postgres://user@host/db'), 'postgres-user-host-db')
  eq(editor.slug('plain'), 'plain')
  eq(editor.slug('a  b'), 'a-b')
end

T['scratchpad']['falls back to a name when there is nothing usable left'] = function()
  eq(editor.slug('///'), 'scratch')
  eq(editor.slug(''), 'scratch')
end

T['scratchpad']['lives under the data directory'] = function()
  eq(editor.path('dev'):find(vim.fn.stdpath('data'), 1, true), 1)
end

T['scratchpad']['uses the current connection when given no name'] = function()
  state.add_connection({ id = 1, name = 'orders', url = 'sqlite://x.db', state = 'connected' })
  eq(vim.fs.basename(editor.path()), 'orders.sql')
end

T['scratchpad']['marks the buffers it attaches to'] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  eq(editor.is_scratchpad(buf), false)

  editor.attach(buf)
  eq(editor.is_scratchpad(buf), true)

  local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
  local seen = {}
  for _, map in ipairs(maps) do
    seen[map.lhs] = true
  end
  eq(seen['<CR>'], true)
  -- An editing buffer keeps its own motions.
  eq(seen['?'], nil)
  eq(seen['q'], nil)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T['row detail'] = MiniTest.new_set()

T['row detail']['lines up names and values'] = function()
  local lines = detail.lines({
    { name = 'id', value = '1', is_null = false },
    { name = 'name', value = 'alice', is_null = false },
  })

  eq(lines, { 'id    1', 'name  alice' })
end

T['row detail']['shows null as null'] = function()
  local lines = detail.lines({ { name = 'v', value = '', is_null = true } })
  eq(lines, { 'v  NULL' })
end

T['row detail']['indents a value that runs over several lines'] = function()
  -- Room for the whole value is the reason this view exists, so a line break is kept rather than
  -- escaped the way a grid cell has to.
  local lines = detail.lines({
    { name = 'note', value = 'first\nsecond', is_null = false },
    { name = 'id', value = '1', is_null = false },
  })

  eq(lines, { 'note  first', '      second', 'id    1' })
end

T['row detail']['handles a row with no columns'] = function()
  eq(detail.lines({}), {})
end

T['diagnostics'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.diagnostic.reset(diagnostics.namespace)
    end,
  },
})

T['diagnostics']['sit on the lines the statement occupies'] = function()
  local built = diagnostics.build({ error = 'no such column', start_line = 2, end_line = 4 })

  eq(built.lnum, 2)
  eq(built.end_lnum, 4)
  eq(built.severity, vim.diagnostic.severity.ERROR)
  eq(built.message, 'no such column')
  eq(built.source, 'sqmeow')
end

T['diagnostics']['default to the first line when the engine sent no range'] = function()
  local built = diagnostics.build({ error = 'broken' })
  eq(built.lnum, 0)
  eq(built.end_lnum, 0)
end

T['diagnostics']['land in the buffer the query came from'] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'select 1;', 'select nope;' })

  diagnostics.set(buf, { error = 'no such column: nope', start_line = 1, end_line = 1 })
  local found = vim.diagnostic.get(buf, { namespace = diagnostics.namespace })

  eq(#found, 1)
  eq(found[1].lnum, 1)

  diagnostics.clear(buf)
  eq(#vim.diagnostic.get(buf, { namespace = diagnostics.namespace }), 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['diagnostics']['do nothing without a buffer to show them in'] = function()
  diagnostics.set(nil, { error = 'broken' })
  diagnostics.clear(nil)
  diagnostics.set(9999, { error = 'broken' })
end

T['query log'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
    end,
  },
})

T['query log']['starts empty'] = function()
  eq(log.entries(), {})
end

T['query log']['keeps the newest first'] = function()
  state.record_call({ call_id = 1, state = 'done', rows = 1 })
  state.record_call({ call_id = 2, state = 'done', rows = 2 })

  eq(log.entries()[1].call_id, 2)
  eq(log.entries()[2].call_id, 1)
end

T['query log']['forgets more than the engine holds'] = function()
  require('sqmeow.config').apply({ query = { history_size = 2 } })
  for id = 1, 5 do
    state.record_call({ call_id = id, state = 'done', rows = 0 })
  end

  eq(#log.entries(), 2)
  eq(log.entries()[1].call_id, 5)
  require('sqmeow.config').apply({})
end

T['query log']['describes what happened'] = function()
  local row = log.describe({
    state = 'done',
    rows = 3,
    elapsed_ms = 12,
    statement = 'select *\n  from people',
  })

  eq(row:find('3 rows', 1, true) ~= nil, true)
  eq(row:find('12ms', 1, true) ~= nil, true)
  -- The statement is flattened to one line, because a picker row is one line.
  eq(row:find('select * from people', 1, true) ~= nil, true)
end

T['query log']['describes an error and a cancellation'] = function()
  eq(log.describe({ state = 'error', statement = 'x' }):find('error', 1, true) ~= nil, true)
  eq(log.describe({ state = 'cancelled', statement = 'x' }):find('cancelled', 1, true) ~= nil, true)
end

T['query log']['describes a statement that changed rows'] = function()
  local row = log.describe({ state = 'done', rows = 0, affected = 4, statement = 'update t' })
  eq(row:find('4 affected', 1, true) ~= nil, true)
end

T['layout'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      layout.forget()
      require('sqmeow.ui.result').close()
      require('sqmeow.ui.drawer').close()
    end,
  },
})

T['layout']['remembers nothing until asked'] = function()
  eq(layout.is_remembered(), false)
end

T['layout']['records the layout before the first window opens'] = function()
  layout.remember()
  eq(layout.is_remembered(), true)
end

T['layout']['does not overwrite what it already recorded'] = function()
  layout.remember()
  require('sqmeow.ui.result').open()
  layout.remember()

  -- The second call must not capture a layout that already includes a plugin window.
  eq(layout.is_remembered(), true)
end

T['layout']['puts the windows back when the last one closes'] = function()
  local before = vim.fn.winrestcmd()
  local windows = #vim.api.nvim_list_wins()

  require('sqmeow.ui.result').open()
  eq(#vim.api.nvim_list_wins() > windows, true)

  require('sqmeow.ui.result').close()
  eq(#vim.api.nvim_list_wins(), windows)
  eq(vim.fn.winrestcmd(), before)
  eq(layout.is_remembered(), false)
end

T['layout']['waits for the last window before restoring'] = function()
  require('sqmeow.ui.drawer').open()
  require('sqmeow.ui.result').open()

  require('sqmeow.ui.result').close()
  -- The drawer is still up, so the recorded layout is still needed.
  eq(layout.is_remembered(), true)

  require('sqmeow.ui.drawer').close()
end

return T
