local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = require('sqmeow.api')
local config = require('sqmeow.config')
local editor = require('sqmeow.ui.editor')
local detail = require('sqmeow.ui.detail')
local drawer = require('sqmeow.ui.drawer')
local layout = require('sqmeow.ui.layout')
local log = require('sqmeow.ui.log')
local paths = require('sqmeow.paths')
local result = require('sqmeow.ui.result')
local state = require('sqmeow.state')

--- A tab page of its own, closed when the case ends.
local function tabpage()
  vim.cmd('tabnew')
  MiniTest.finally(function()
    vim.cmd('tabclose')
  end)
end

--- A connected fixture the editor can open scratchpads for.
local function use_connection(name, url, extra)
  state.add_connection(
    vim.tbl_extend('force', { id = 1, name = name, url = url, state = 'connected' }, extra or {})
  )
end

local T = MiniTest.new_set()

T['scratchpad'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
      vim.cmd('silent! %bwipeout!')
      vim.fn.delete(editor.directory(), 'rf')
    end,
  },
})

T['scratchpad']['keeps a file in a folder named after its connection'] = function()
  eq(
    editor.path('dev db', 'monthly report'),
    vim.fs.joinpath(editor.directory(), 'dev-db', 'monthly-report.sql')
  )
end

T['scratchpad']['gives a mongodb connection a json file'] = function()
  use_connection('docs', 'mongodb://h/app')
  eq(vim.fs.basename(editor.path('docs', 'orders')), 'orders.json')
  eq(vim.bo[assert(editor.create('docs', 'orders'))].filetype, 'json')
end

T['scratchpad']['gives a redis connection a redis file'] = function()
  use_connection('cache', 'redis://h/0')
  eq(vim.fs.basename(editor.path('cache', 'keys')), 'keys.redis')
end

T['scratchpad']['opens with the filetype its connection speaks'] = function()
  use_connection('cache', 'redis://h/0')
  use_connection('shop', 'sqlite://x.db', { id = 2 })

  local redis = assert(editor.create('cache', 'keys'))
  eq(vim.bo[redis].filetype, 'redis')
  local sql = assert(editor.create('shop', 'orders'))
  eq(vim.bo[sql].filetype, 'sql')
end

T['scratchpad']['is written as soon as it is created, so it is listed'] = function()
  use_connection('shop', 'sqlite://x.db')
  editor.create('shop', 'orders')

  local pads = editor.list()
  eq(#pads, 1)
  eq({ pads[1].name, pads[1].folder }, { 'orders', 'shop' })
end

T['scratchpad']['refuses to be created without a name'] = function()
  local buf, err = editor.create('shop', '  ')
  eq(buf, nil)
  eq(err, 'a scratchpad needs a name')
end

T['scratchpad']['keeps its folder and extension when renamed'] = function()
  use_connection('cache', 'redis://h/0')
  editor.create('cache', 'keys')

  local renamed = editor.rename(editor.path('cache', 'keys'), 'sessions')
  eq(renamed, vim.fs.normalize(vim.fs.joinpath(editor.directory(), 'cache', 'sessions.redis')))
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
  eq(vim.fs.dirname(vim.fs.dirname(editor.path('dev', 'x'))), paths.scratch())
end

T['scratchpad']['marks the buffers it attaches to'] = function()
  local buf = helpers.temp_buf()
  eq(editor.is_scratchpad(buf), false)

  editor.attach(buf)
  eq(editor.is_scratchpad(buf), true)

  local seen = helpers.buf_maps(buf)
  eq(seen['<CR>'] ~= nil, true)
  -- An editing buffer keeps its own motions.
  eq(seen['?'], nil)
  eq(seen['q'], nil)
end

T['row detail'] = MiniTest.new_set()

--- What each line of the detail reads as.
local function texts(lines)
  return vim.tbl_map(function(line)
    return line:content()
  end, lines)
end

T['row detail']['lines up names, types and values'] = function()
  local lines = detail.lines({
    { name = 'id', declared_type = 'uuid', key = 'primary_key', value = '1', is_null = false },
    {
      name = 'owner',
      declared_type = 'integer',
      key = 'foreign_key',
      value = '7',
      is_null = false,
    },
  }, 80)

  eq(texts(lines), { 'id     uuid (PK)     1', 'owner  integer (FK)  7' })
end

T['row detail']['shows null as null'] = function()
  local lines =
    detail.lines({ { name = 'v', declared_type = 'text', value = '', is_null = true } }, 80)
  eq(texts(lines), { 'v  text  NULL' })
end

T['row detail']['keeps each value to one line that fits'] = function()
  local lines = detail.lines({
    { name = 'note', declared_type = 'text', value = 'first\nsecond line', is_null = false },
  }, 20)

  eq(texts(lines), { 'note  text  first s' .. config.get().icons.grid.ellipsis })
end

T['row detail']['cuts a long type short but keeps its key'] = function()
  local lines = detail.lines({
    {
      name = 'k',
      declared_type = 'character varying(255)',
      key = 'primary_key',
      value = 'x',
      is_null = false,
    },
  }, 80)

  local ellipsis = config.get().icons.grid.ellipsis
  eq(texts(lines), { 'k  character ' .. ellipsis .. ' (PK)  x' })
end

T['row detail']['handles a row with no columns'] = function()
  eq(detail.lines({}, 80), {})
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
  config.apply({ query = { history_size = 2 } })
  for id = 1, 5 do
    state.record_call({ call_id = id, state = 'done', rows = 0 })
  end

  eq(#state.calls, 2)
  eq(state.calls[1].call_id, 5)
  config.apply({})
end

T['query log']['describes what happened'] = function()
  local row = log.describe({
    state = 'done',
    rows = 3,
    elapsed_ms = 12,
    statement = 'select *\n  from people',
  })

  helpers.contains(row, '3 rows')
  helpers.contains(row, '12ms')
  -- The statement is flattened to one line, because a picker row is one line.
  helpers.contains(row, 'select * from people')
end

T['query log']['describes an error and a cancellation'] = function()
  helpers.contains(log.describe({ state = 'error', statement = 'x' }), 'error')
  helpers.contains(log.describe({ state = 'cancelled', statement = 'x' }), 'cancelled')
end

T['query log']['describes a statement that changed rows'] = function()
  local row = log.describe({ state = 'done', rows = 0, affected = 4, statement = 'update t' })
  helpers.contains(row, '4 affected')
end

T['layout'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      layout.forget()
      result.close()
      drawer.close()
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
  result.open()
  layout.remember()

  -- The second call must not capture a layout that already includes a plugin window.
  eq(layout.is_remembered(), true)
end

T['layout']['puts the windows back when the last one closes'] = function()
  local before = vim.fn.winrestcmd()
  local windows = #vim.api.nvim_list_wins()

  result.open()
  eq(#vim.api.nvim_list_wins() > windows, true)

  result.close()
  eq(#vim.api.nvim_list_wins(), windows)
  eq(vim.fn.winrestcmd(), before)
  eq(layout.is_remembered(), false)
end

T['layout']['waits for the last window before restoring'] = function()
  drawer.open()
  result.open()

  result.close()
  -- The drawer is still up, so the recorded layout is still needed.
  eq(layout.is_remembered(), true)

  drawer.close()
end

T['knowing where a query goes'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
      config.apply({})
      vim.cmd('silent! %bwipeout!')
      -- Scratchpads written here must not be left for the drawer's cases to count.
      vim.fn.delete(editor.directory(), 'rf')
    end,
  },
})

--- The winbar of the window showing a buffer, or nil when it has none.
---@return string|nil
local function winbar(buf)
  local win = helpers.find_win(function(candidate)
    return vim.api.nvim_win_get_buf(candidate) == buf
  end)
  return win and vim.wo[win].winbar or nil
end

T['knowing where a query goes']['ties a scratchpad to the connection whose folder it is in'] = function()
  use_connection('orders', 'sqlite://x.db')

  local buf = editor.create('orders', 'monthly')
  eq(vim.b[buf].sqmeow_connection, 'orders')
end

T['knowing where a query goes']['still ties a file from before folders by its name'] = function()
  use_connection('orders', 'sqlite://x.db')

  local path = vim.fs.joinpath(editor.directory(), 'orders.sql')
  helpers.writefile(path, { 'select 1' })

  local buf = editor.open_path(path)
  eq(vim.b[buf].sqmeow_connection, 'orders')
end

T['knowing where a query goes']['leaves a file that names no connection alone'] = function()
  use_connection('orders', 'sqlite://x.db')

  local path = vim.fs.joinpath(editor.directory(), 'notes.sql')
  helpers.writefile(path, { 'select 1' })
  MiniTest.finally(function()
    vim.fn.delete(path)
  end)

  local buf = editor.open_path(path)
  eq(vim.b[buf].sqmeow_connection, nil)
end

T['knowing where a query goes']['says so above the scratchpad'] = function()
  use_connection('orders', 'postgres://x/orders', { dialect = 'postgres' })

  local buf = editor.create('orders', 'monthly')
  helpers.contains(winbar(buf), 'orders (postgres)')
end

T['knowing where a query goes']['says what is wrong when the connection is closed'] = function()
  use_connection('orders', 'sqlite://x.db')
  local buf = editor.create('orders', 'monthly')
  state.remove_connection(1)
  editor.update_winbar()

  helpers.contains(winbar(buf), '`orders` is not open')
end

T['knowing where a query goes']['draws no winbar when the option is off'] = function()
  config.apply({ ui = { winbar = false } })
  use_connection('orders', 'sqlite://x.db')

  local buf = editor.create('orders', 'monthly')
  eq(winbar(buf), '')
end

T['opening everything'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      result.close()
      drawer.close()
      layout.forget()
    end,
  },
})

T['opening everything']['puts up the drawer and the result, and creates no scratchpad'] = function()
  local before = #editor.list()
  api.open_all()

  eq(drawer.is_open(), true)
  eq(result.is_open(), true)
  -- Scratchpads are made when someone asks for one, never as a side effect of opening the client.
  eq(editor.is_scratchpad(), false)
  eq(#editor.list(), before)
end

T['opening everything']['closes it all again'] = function()
  api.open_all()
  api.toggle()

  eq(drawer.is_open(), false)
  eq(result.is_open(), false)
end

T['editing window'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      result.close()
      drawer.close()
      layout.forget()
    end,
  },
})

T['editing window']['is the current one when it can hold a file'] = function()
  local here = vim.api.nvim_get_current_win()
  eq(layout.editing_window(), here)
end

T['editing window']['is never the drawer'] = function()
  local sidebar = drawer.open()
  vim.api.nvim_set_current_win(sidebar)

  eq(layout.editing_window() ~= sidebar, true)
end

T['editing window']['is never the result grid'] = function()
  local grid = result.open()
  vim.api.nvim_set_current_win(grid)

  eq(layout.editing_window() ~= grid, true)
end

T['editing window']['is made when every window in the tab belongs to the plugin'] = function()
  tabpage()

  -- The one window in this tab holds a plugin surface.
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

  tabpage()

  eq(layout.editing_window() ~= elsewhere, true)
end

T['closing'] = MiniTest.new_set()

T['closing']['empties the window rather than throwing when it is the last one'] = function()
  tabpage()

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, result.buffer())

  -- Neovim refuses to close the last window in a tab, and `q` in a result grid should not throw.
  layout.close_window(win)

  eq(vim.api.nvim_win_is_valid(win), true)
  eq(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, '')
end

T['closing']['closes the window when there is another'] = function()
  tabpage()

  vim.cmd('split')
  local win = vim.api.nvim_get_current_win()

  layout.close_window(win)
  eq(vim.api.nvim_win_is_valid(win), false)
end

T['surfaces'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      result.close()
      layout.forget()
    end,
  },
})

T['surfaces']['count as closed once something else takes their window'] = function()
  local win = result.open()
  eq(result.is_open(), true)

  -- A `:bdelete` elsewhere, a session restore, or a picker opening a file can all leave the window
  -- valid while showing someone else's buffer.
  vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  eq(result.is_open(), false)
end

T['surfaces']['open a window of their own rather than taking one back'] = function()
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

  local renamed = assert(editor.rename(path, 'after'))
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
  local renamed = assert(editor.rename(path, '../../escaped'))
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
  helpers.contains(assert(err, 'there should be an error'), 'already a scratchpad')
  eq(vim.uv.fs_stat(path) ~= nil, true)
end

T['rename']['does nothing when the name has not changed'] = function()
  local path = scratchpad('before')

  eq(editor.rename(path, 'before'), vim.fs.normalize(path))
  eq(vim.uv.fs_stat(path) ~= nil, true)
end

T['rename']['refuses a path outside the scratchpad directory'] = function()
  local elsewhere = helpers.temp_file({ 'important' })

  local renamed, err = editor.rename(elsewhere, 'mine')
  eq(renamed, nil)
  helpers.contains(assert(err, 'there should be an error'), 'is not a scratchpad')
  eq(vim.uv.fs_stat(elsewhere) ~= nil, true)
end

T['rename']['says so when there is nothing there'] = function()
  local renamed, err = editor.rename(vim.fs.joinpath(editor.directory(), 'absent.sql'), 'other')
  eq(renamed, nil)
  helpers.contains(assert(err, 'there should be an error'), 'there is no scratchpad')
end

T['rename']['carries an open buffer over to the new name'] = function()
  local path = scratchpad('opened')
  MiniTest.finally(function()
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'moved.sql'))
  end)

  local buf = editor.open_path(path)
  local renamed = editor.rename(path, 'moved')

  -- The buffer must follow the file.
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
  local path = scratchpad('doomed')

  eq(editor.remove(path), true)
  eq(vim.uv.fs_stat(path), nil)
end

T['remove']['unloads the buffer, so a later write cannot bring it back'] = function()
  local path = scratchpad('loaded')

  local buf = editor.open_path(path)
  eq(editor.remove(path), true)
  eq(vim.api.nvim_buf_is_valid(buf), false)
end

T['remove']['refuses a path outside the scratchpad directory'] = function()
  local elsewhere = helpers.temp_file({ 'important' })

  local removed, err = editor.remove(elsewhere)
  eq(removed, false)
  helpers.contains(assert(err, 'there should be an error'), 'is not a scratchpad')
  eq(vim.uv.fs_stat(elsewhere) ~= nil, true)
end

T['remove']['says so when there is nothing there'] = function()
  local removed, err = editor.remove(vim.fs.joinpath(editor.directory(), 'absent.sql'))
  eq(removed, false)
  helpers.contains(assert(err, 'there should be an error'), 'there is no scratchpad')
end

T['list'] = MiniTest.new_set()

T['list']['names the saved files without their extension, newest first'] = function()
  scratchpad('older')
  scratchpad('newer')

  local names = vim.tbl_map(function(pad)
    return pad.name
  end, editor.list())

  eq(vim.tbl_contains(names, 'older'), true)
  eq(vim.tbl_contains(names, 'newer'), true)
end

return T
