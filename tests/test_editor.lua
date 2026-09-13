local MiniTest = require('mini.test')
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

T['scratchpad']['lives under core.path'] = function()
  eq(vim.fs.dirname(editor.path('dev')), require('sqmeow.paths').scratch())
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
  eq(state.calls, {})
end

T['query log']['keeps the newest first'] = function()
  state.record_call({ call_id = 1, state = 'done', rows = 1 })
  state.record_call({ call_id = 2, state = 'done', rows = 2 })

  eq(state.calls[1].call_id, 2)
  eq(state.calls[2].call_id, 1)
end

T['query log']['forgets more than the engine holds'] = function()
  require('sqmeow.config').apply({ query = { history_size = 2 } })
  for id = 1, 5 do
    state.record_call({ call_id = id, state = 'done', rows = 0 })
  end

  eq(#state.calls, 2)
  eq(state.calls[1].call_id, 5)
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

T['knowing where a query goes'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
      require('sqmeow.config').apply({})
      vim.cmd('silent! %bwipeout!')
    end,
  },
})

--- The winbar of the window showing a buffer, or nil when it has none.
---@return string|nil
local function winbar(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.wo[win].winbar
    end
  end
  return nil
end

T['knowing where a query goes']['ties a scratchpad to the connection it is named after'] = function()
  state.add_connection({ id = 1, name = 'orders', url = 'sqlite://x.db', state = 'connected' })

  local buf = editor.open('orders')
  eq(vim.b[buf].sqmeow_connection, 'orders')
end

T['knowing where a query goes']['leaves a file that names no connection alone'] = function()
  state.add_connection({ id = 1, name = 'orders', url = 'sqlite://x.db', state = 'connected' })

  vim.fn.mkdir(editor.directory(), 'p')
  local path = vim.fs.joinpath(editor.directory(), 'notes.sql')
  vim.fn.writefile({ 'select 1' }, path)
  MiniTest.finally(function()
    vim.fn.delete(path)
  end)

  local buf = editor.open_path(path)
  eq(vim.b[buf].sqmeow_connection, nil)
end

T['knowing where a query goes']['says so above the scratchpad'] = function()
  state.add_connection({
    id = 1,
    name = 'orders',
    url = 'postgres://x/orders',
    dialect = 'postgres',
    state = 'connected',
  })

  local buf = editor.open('orders')
  eq(winbar(buf):find('orders (postgres)', 1, true) ~= nil, true)
end

T['knowing where a query goes']['says what is wrong when the connection is closed'] = function()
  state.add_connection({ id = 1, name = 'orders', url = 'sqlite://x.db', state = 'connected' })
  local buf = editor.open('orders')
  state.remove_connection(1)
  editor.update_winbar()

  eq(winbar(buf):find('`orders` is not open', 1, true) ~= nil, true)
end

T['knowing where a query goes']['draws no winbar when the option is off'] = function()
  require('sqmeow.config').apply({ ui = { winbar = false } })
  state.add_connection({ id = 1, name = 'orders', url = 'sqlite://x.db', state = 'connected' })

  local buf = editor.open('orders')
  eq(winbar(buf), '')
end

T['opening everything'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      require('sqmeow.ui.result').close()
      require('sqmeow.ui.drawer').close()
      layout.forget()
    end,
  },
})

T['opening everything']['puts up all three surfaces'] = function()
  require('sqmeow.api').open_all()

  eq(require('sqmeow.ui.drawer').is_open(), true)
  eq(require('sqmeow.ui.result').is_open(), true)
  -- And the cursor is in the scratchpad, since that is where a person types next.
  eq(require('sqmeow.ui.editor').is_scratchpad(), true)
end

T['opening everything']['closes it all again'] = function()
  require('sqmeow.api').open_all()
  require('sqmeow.api').toggle()

  eq(require('sqmeow.ui.drawer').is_open(), false)
  eq(require('sqmeow.ui.result').is_open(), false)
end

T['editing window'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      require('sqmeow.ui.result').close()
      require('sqmeow.ui.drawer').close()
      layout.forget()
    end,
  },
})

T['editing window']['is the current one when it can hold a file'] = function()
  local here = vim.api.nvim_get_current_win()
  eq(layout.editing_window(), here)
end

T['editing window']['is never the drawer'] = function()
  local drawer = require('sqmeow.ui.drawer')
  local sidebar = drawer.open()
  vim.api.nvim_set_current_win(sidebar)

  eq(layout.editing_window() ~= sidebar, true)
end

T['editing window']['is never the result grid'] = function()
  local result = require('sqmeow.ui.result')
  local grid = result.open()
  vim.api.nvim_set_current_win(grid)

  eq(layout.editing_window() ~= grid, true)
end

T['editing window']['is made when every window in the tab belongs to the plugin'] = function()
  vim.cmd('tabnew')
  MiniTest.finally(function()
    vim.cmd('tabclose')
  end)

  -- The one window in this tab holds a plugin surface, so there is nowhere for a file to go.
  -- Wiped afterwards: a stray buffer claiming to be one of ours is a plausible fallback for
  -- Neovim to pick when some other buffer is deleted, which would confuse later cases.
  local pretend = vim.api.nvim_get_current_buf()
  vim.bo[pretend].filetype = 'sqmeow-result'
  MiniTest.finally(function()
    pcall(vim.api.nvim_buf_delete, pretend, { force = true })
  end)

  local before = #vim.api.nvim_tabpage_list_wins(0)
  local chosen = layout.editing_window()

  eq(#vim.api.nvim_tabpage_list_wins(0), before + 1)
  eq(chosen, vim.api.nvim_get_current_win())
  eq(vim.bo[vim.api.nvim_win_get_buf(chosen)].filetype, '')
end

T['editing window']['stays in the tab it was asked from'] = function()
  local elsewhere = vim.api.nvim_get_current_win()

  vim.cmd('tabnew')
  MiniTest.finally(function()
    vim.cmd('tabclose')
  end)

  eq(layout.editing_window() ~= elsewhere, true)
end

T['closing'] = MiniTest.new_set()

T['closing']['empties the window rather than throwing when it is the last one'] = function()
  vim.cmd('tabnew')
  MiniTest.finally(function()
    vim.cmd('tabclose')
  end)

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, require('sqmeow.ui.result').buffer())

  -- Neovim refuses to close the last window in a tab, and `q` in a result grid should not throw.
  layout.close_window(win)

  eq(vim.api.nvim_win_is_valid(win), true)
  eq(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, '')
end

T['closing']['closes the window when there is another'] = function()
  vim.cmd('tabnew')
  MiniTest.finally(function()
    vim.cmd('tabclose')
  end)

  vim.cmd('split')
  local win = vim.api.nvim_get_current_win()

  layout.close_window(win)
  eq(vim.api.nvim_win_is_valid(win), false)
end

T['surfaces'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      require('sqmeow.ui.result').close()
      layout.forget()
    end,
  },
})

T['surfaces']['count as closed once something else takes their window'] = function()
  local result = require('sqmeow.ui.result')
  local win = result.open()
  eq(result.is_open(), true)

  -- A `:bdelete` elsewhere, a session restore, or a picker opening a file can all leave the
  -- window valid while showing someone else's buffer. Painting a result into that would write
  -- rows over whatever moved in.
  vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  eq(result.is_open(), false)
end

T['surfaces']['open a window of their own rather than taking one back'] = function()
  local result = require('sqmeow.ui.result')
  local taken = result.open()
  vim.api.nvim_win_set_buf(taken, vim.api.nvim_create_buf(false, true))

  local reopened = result.open()
  eq(reopened ~= taken, true)
  eq(vim.api.nvim_win_get_buf(reopened), result.buffer())

  -- The window somebody else moved into is left exactly as it was.
  eq(vim.api.nvim_win_is_valid(taken), true)
  eq(vim.api.nvim_win_get_buf(taken) ~= result.buffer(), true)
  vim.api.nvim_win_close(taken, true)
end

T['rename'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.fn.mkdir(editor.directory(), 'p')
    end,
  },
})

--- Write a scratchpad and clean it up whatever the case does to it.
local function scratchpad(name, contents)
  local path = vim.fs.joinpath(editor.directory(), name .. '.sql')
  vim.fn.writefile(contents or { 'select 1' }, path)
  MiniTest.finally(function()
    vim.fn.delete(path)
  end)
  return path
end

T['rename']['moves the file'] = function()
  local path = scratchpad('before')
  MiniTest.finally(function()
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'after.sql'))
  end)

  local renamed = editor.rename(path, 'after')
  eq(vim.fs.basename(renamed), 'after.sql')
  eq(vim.uv.fs_stat(path), nil)
  eq(vim.fn.readfile(renamed), { 'select 1' })
end

T['rename']['slugs a name that would not make a file'] = function()
  local path = scratchpad('before')
  MiniTest.finally(function()
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'my-notes.sql'))
  end)

  eq(vim.fs.basename(editor.rename(path, 'my notes')), 'my-notes.sql')
end

T['rename']['cannot write outside the scratchpad directory'] = function()
  local path = scratchpad('before')

  -- The separators become dashes, so this names a file in the directory rather than above it.
  local renamed = editor.rename(path, '../../escaped')
  MiniTest.finally(function()
    vim.fn.delete(renamed)
  end)

  eq(vim.fs.dirname(renamed), vim.fs.normalize(editor.directory()))
end

T['rename']['refuses a name already taken'] = function()
  local path = scratchpad('before')
  scratchpad('taken')

  local renamed, err = editor.rename(path, 'taken')
  eq(renamed, nil)
  eq(err:find('already a scratchpad') ~= nil, true)
  eq(vim.uv.fs_stat(path) ~= nil, true)
end

T['rename']['does nothing when the name has not changed'] = function()
  local path = scratchpad('before')

  eq(editor.rename(path, 'before'), vim.fs.normalize(path))
  eq(vim.uv.fs_stat(path) ~= nil, true)
end

T['rename']['refuses a path outside the scratchpad directory'] = function()
  local elsewhere = vim.fn.tempname()
  vim.fn.writefile({ 'important' }, elsewhere)
  MiniTest.finally(function()
    vim.fn.delete(elsewhere)
  end)

  local renamed, err = editor.rename(elsewhere, 'mine')
  eq(renamed, nil)
  eq(err:find('is not a scratchpad') ~= nil, true)
  eq(vim.uv.fs_stat(elsewhere) ~= nil, true)
end

T['rename']['says so when there is nothing there'] = function()
  local renamed, err = editor.rename(vim.fs.joinpath(editor.directory(), 'absent.sql'), 'other')
  eq(renamed, nil)
  eq(err:find('there is no scratchpad') ~= nil, true)
end

T['rename']['carries an open buffer over to the new name'] = function()
  local path = scratchpad('opened')
  MiniTest.finally(function()
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'moved.sql'))
  end)

  local buf = editor.open_path(path)
  local renamed = editor.rename(path, 'moved')

  -- The buffer must follow the file. Left on the old name it would write the scratchpad back
  -- under it on the next `:w`, which is a confusing way to learn a rename did not stick.
  eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), renamed)
  eq(vim.bo[buf].modified, false)
  eq(#editor.buffers_for(vim.fs.normalize(path)), 0)
end

T['remove'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.fn.mkdir(editor.directory(), 'p')
    end,
  },
})

T['remove']['deletes the file'] = function()
  local path = vim.fs.joinpath(editor.directory(), 'doomed.sql')
  vim.fn.writefile({ 'select 1' }, path)

  eq(editor.remove(path), true)
  eq(vim.uv.fs_stat(path), nil)
end

T['remove']['unloads the buffer, so a later write cannot bring it back'] = function()
  local path = vim.fs.joinpath(editor.directory(), 'loaded.sql')
  vim.fn.writefile({ 'select 1' }, path)

  local buf = editor.open_path(path)
  eq(editor.remove(path), true)
  eq(vim.api.nvim_buf_is_valid(buf), false)
end

T['remove']['refuses a path outside the scratchpad directory'] = function()
  local elsewhere = vim.fn.tempname()
  vim.fn.writefile({ 'important' }, elsewhere)
  MiniTest.finally(function()
    vim.fn.delete(elsewhere)
  end)

  local removed, err = editor.remove(elsewhere)
  eq(removed, false)
  eq(err:find('is not a scratchpad') ~= nil, true)
  eq(vim.uv.fs_stat(elsewhere) ~= nil, true)
end

T['remove']['says so when there is nothing there'] = function()
  local removed, err = editor.remove(vim.fs.joinpath(editor.directory(), 'absent.sql'))
  eq(removed, false)
  eq(err:find('there is no scratchpad') ~= nil, true)
end

T['list'] = MiniTest.new_set()

T['list']['names the saved files without their extension, newest first'] = function()
  vim.fn.mkdir(editor.directory(), 'p')
  for _, name in ipairs({ 'older', 'newer' }) do
    vim.fn.writefile({ 'select 1' }, vim.fs.joinpath(editor.directory(), name .. '.sql'))
  end
  MiniTest.finally(function()
    for _, name in ipairs({ 'older', 'newer' }) do
      vim.fn.delete(vim.fs.joinpath(editor.directory(), name .. '.sql'))
    end
  end)

  local names = vim.tbl_map(function(pad)
    return pad.name
  end, editor.list())

  eq(vim.tbl_contains(names, 'older'), true)
  eq(vim.tbl_contains(names, 'newer'), true)
end

return T
