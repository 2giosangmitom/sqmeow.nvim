local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.helpers')
local structure = require('sqmeow.ui.structure')
local drawer = require('sqmeow.ui.drawer')
local state = require('sqmeow.core.state')
local T = MiniTest.new_set()

local function setup(request_error)
  structure.close()
  MiniTest.finally(structure.close)
  helpers.stub(state, 'connections', {
    [1] = { id = 1, name = 'dev', dialect = 'postgres', state = 'connected' },
  })
  helpers.stub(state, 'current', nil)
  helpers.stub(require('sqmeow.rpc.events'), 'ensure', function() end)
  local requests, messages = {}, {}
  helpers.stub(require('sqmeow.rpc.client'), 'request', function(method, args)
    table.insert(requests, { method = method, args = vim.deepcopy(args) })
    if request_error then
      return nil, request_error
    end
    return true
  end)
  helpers.stub(require('sqmeow.core.utils'), 'notify', function(message)
    table.insert(messages, message)
  end)
  helpers.stub(require('sqmeow.api.query'), 'execute', function()
    error('inspection must not execute source')
  end)
  local existing = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    existing[buf] = true
  end
  MiniTest.finally(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not existing[buf] then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
  return requests, messages
end

local function select_routine(kind, name)
  local node = {
    conn_id = 1,
    kind = kind,
    name = name or 'do_work',
    path = { 'public', kind == 'function' and 'functions' or 'procedures', name or 'do_work' },
  }
  helpers.stub(drawer, 'current_node', function()
    return node
  end)
end

local function content()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end

for _, kind in ipairs({ 'function', 'procedure' }) do
  T['K inspects a ' .. kind .. ' signature and body without an editor'] = function()
    local requests = setup()
    select_routine(kind)
    local original = vim.api.nvim_get_current_buf()
    drawer.actions.structure()
    eq(vim.api.nvim_get_current_buf(), original)
    eq(requests[1].method, 'routine_source')
    local args = requests[1].args
    eq(args.conn_id, 1)
    eq(args.schema, 'public')
    eq(args.name, 'do_work')
    eq(args.kind, kind)
    local source = 'CREATE OR REPLACE '
      .. kind:upper()
      .. ' public.do_work(n integer)\nAS $$\nBEGIN\n  NULL;\nEND\n$$;'
    structure.on_routine(vim.tbl_extend('force', args, { source = source }))
    eq(content(), source)
    eq(vim.bo.filetype, 'sql')
    eq(vim.bo.modifiable, false)
    eq(vim.b.sqmeow_editor, nil)
    eq(vim.b.sqmeow_connection, nil)
    eq(vim.api.nvim_win_get_config(0).relative ~= '', true)
    local popup_buf = vim.api.nvim_get_current_buf()
    structure.close()
    eq(vim.api.nvim_buf_is_valid(popup_buf), false)
  end
end

T['keeps overloads and uses SurrealQL highlighting'] = function()
  local requests = setup()
  state.connections[1].dialect = 'surrealdb'
  structure.open_routine(1, 'main', 'fn::work', 'function')
  local source = 'first overload\n\nsecond overload'
  structure.on_routine(vim.tbl_extend('force', requests[1].args, { source = source }))
  eq(content(), source)
  eq(vim.bo.filetype, 'surql')
end

T['matches complete identity and discards older or duplicate replies'] = function()
  local requests = setup()
  local original = vim.api.nvim_get_current_buf()
  structure.open_routine(1, 'public', 'old', 'function')
  local old = requests[1].args
  structure.open_routine(1, 'public', 'latest', 'procedure')
  local latest = requests[2].args
  structure.on_routine(vim.tbl_extend('force', old, { source = 'old definition' }))
  eq(vim.api.nvim_get_current_buf(), original)
  for _, mismatch in ipairs({
    { conn_id = 2 },
    { schema = 'other' },
    { name = 'other' },
    { kind = 'function' },
    { request_id = latest.request_id + 1 },
  }) do
    structure.on_routine(vim.tbl_extend('force', latest, { source = 'wrong definition' }, mismatch))
    eq(vim.api.nvim_get_current_buf(), original)
  end
  structure.on_routine(vim.tbl_extend('force', latest, { source = 'latest definition' }))
  eq(content(), 'latest definition')
  structure.on_routine(vim.tbl_extend('force', latest, { source = 'duplicate definition' }))
  eq(content(), 'latest definition')
end

T['reports rejected, hidden, unsupported and empty source'] = function()
  local requests, messages = setup('connection closed')
  local original = vim.api.nvim_get_current_buf()
  structure.open_routine(1, 'public', 'work', 'function')
  eq(messages[1], 'connection closed')
  structure.on_routine(vim.tbl_extend('force', requests[1].args, { source = 'late source' }))
  eq(vim.api.nvim_get_current_buf(), original)
end

T['handles asynchronous source errors and empty source without a popup'] = function()
  local requests, messages = setup()
  local original = vim.api.nvim_get_current_buf()
  for _, message in ipairs({ 'encrypted routine', 'unsupported adapter' }) do
    structure.open_routine(1, 'public', 'work', 'function')
    structure.on_routine(vim.tbl_extend('force', requests[#requests].args, { error = message }))
    eq(messages[#messages], message)
    eq(vim.api.nvim_get_current_buf(), original)
  end
  structure.open_routine(1, 'public', 'work', 'function')
  structure.on_routine(vim.tbl_extend('force', requests[#requests].args, { source = ' \n' }))
  helpers.contains(messages[#messages], 'no visible source')
  eq(vim.api.nvim_get_current_buf(), original)
end

T['cancels inspection on close, disconnect and engine restart'] = function()
  local requests = setup()
  helpers.stub(require('sqmeow.ui.relationships'), 'close', function() end)
  helpers.stub(require('sqmeow.ui.result'), 'forget', function() end)
  local original = vim.api.nvim_get_current_buf()
  for _, cancel in ipairs({
    structure.close,
    function()
      structure.invalidate(1)
    end,
    function()
      require('sqmeow.rpc.events').on_engine_restart()
    end,
  }) do
    structure.open_routine(1, 'public', 'work', 'function')
    cancel()
    structure.on_routine(
      vim.tbl_extend('force', requests[#requests].args, { source = 'late definition' })
    )
    eq(vim.api.nvim_get_current_buf(), original)
  end
  structure.open_routine(1, 'public', 'work', 'function')
  state.remove_connection(1)
  structure.on_routine(
    vim.tbl_extend('force', requests[#requests].args, { source = 'closed connection' })
  )
  eq(vim.api.nvim_get_current_buf(), original)
end

T['closes a visible definition when its connection is removed'] = function()
  local requests = setup()
  structure.open_routine(1, 'public', 'work', 'function')
  structure.on_routine(vim.tbl_extend('force', requests[1].args, { source = 'definition' }))
  local popup_buf = vim.api.nvim_get_current_buf()
  structure.invalidate(2)
  eq(vim.api.nvim_buf_is_valid(popup_buf), true)
  state.remove_connection(1)
  eq(vim.api.nvim_buf_is_valid(popup_buf), false)
end

T['routes editor and inspector replies independently for the same routine'] = function()
  local requests = setup()
  select_routine('function')
  drawer.actions.edit()
  drawer.actions.structure()
  local edit, inspect = requests[1].args, requests[2].args
  eq(edit.request_id == inspect.request_id, false)
  local edit_reply = vim.tbl_extend('force', edit, { source = 'editable definition' })
  drawer.on_routine(edit_reply)
  structure.on_routine(edit_reply)
  local editor_buf = vim.api.nvim_get_current_buf()
  eq(content(), 'editable definition')
  eq(vim.b.sqmeow_editor, true)
  local inspect_reply = vim.tbl_extend('force', inspect, { source = 'inspected definition' })
  drawer.on_routine(inspect_reply)
  structure.on_routine(inspect_reply)
  eq(content(), 'inspected definition')
  eq(vim.bo.modifiable, false)
  eq(vim.b.sqmeow_editor, nil)
  eq(vim.api.nvim_buf_get_lines(editor_buf, 0, -1, false), { 'editable definition' })
end

T['preserves table structure rendering'] = function()
  local requests = setup()
  helpers.stub(drawer, 'current_node', function()
    return { kind = 'table', name = 'users', conn_id = 1, path = { 'public', 'tables', 'users' } }
  end)
  drawer.actions.structure()
  eq(
    requests[1],
    { method = 'structure', args = { conn_id = 1, schema = 'public', relation = 'users' } }
  )
  structure.on_done({
    conn_id = 1,
    schema = 'public',
    relation = 'users',
    columns = {
      { name = 'id', type_name = 'integer', primary_key = true, nullable = false },
    },
    definition = 'CREATE TABLE public.users (id integer PRIMARY KEY);',
  })
  helpers.contains(content(), 'Columns')
  helpers.contains(content(), 'primary key')
  helpers.contains(content(), 'CREATE TABLE public.users')
  eq(vim.bo.filetype, 'sqmeow-structure')
  eq(vim.bo.modifiable, false)
end

return T
