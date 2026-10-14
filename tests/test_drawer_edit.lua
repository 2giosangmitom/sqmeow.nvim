local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.helpers')
local drawer = require('sqmeow.ui.drawer')
local state = require('sqmeow.core.state')

local node
---@type fun(...: any): any, string|nil
local rpc_request
---@type fun(...: any): any
local execute_query
---@type fun(...: any): any
local use_connection
local T = MiniTest.new_set()
local function setup()
  helpers.stub(drawer, 'render', function() end)
  drawer.reset()
  MiniTest.finally(function()
    drawer.reset()
  end)
  helpers.stub(state, 'connections', {
    [1] = { id = 1, name = 'dev', dialect = 'postgres', state = 'connected' },
  })
  node = { kind = 'table', name = 'users', conn_id = 1, path = { 'public', 'tables', 'users' } }
  helpers.stub(drawer, 'current_node', function()
    return node
  end)
  -- Opening the template must never execute it or change the active connection.
  execute_query = function()
    error('table editing must not execute a query')
  end
  use_connection = function()
    error('table editing must not change the active connection')
  end
  rpc_request = function()
    error('unexpected engine request')
  end
  helpers.stub(require('sqmeow.api.query'), 'execute', function(...)
    return execute_query(...)
  end)
  helpers.stub(require('sqmeow.api.connection'), 'use', function(...)
    return use_connection(...)
  end)
  helpers.stub(require('sqmeow.rpc.client'), 'request', function(...)
    return rpc_request(...)
  end)
  helpers.stub(require('sqmeow.rpc.events'), 'ensure', function() end)
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
end

local function cache_columns(columns)
  drawer.on_nodes({ conn_id = node.conn_id, path = node.path, nodes = columns })
end

local function content()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end

local function request_routine(kind)
  node.kind = kind or 'function'
  node.path = { 'public', node.kind == 'function' and 'functions' or 'procedures', 'users' }
  local request
  rpc_request = function(method, params)
    eq(method, 'routine_source')
    request = params
    return true
  end
  drawer.actions.edit()
  eq(request.conn_id, 1)
  eq(request.schema, 'public')
  eq(request.name, 'users')
  eq(request.kind, node.kind)
  return request
end

for _, kind in ipairs({ 'function', 'procedure' }) do
  T['opens the complete ' .. kind .. ' definition without executing it'] = function()
    setup()
    local original = vim.api.nvim_get_current_buf()
    local request = request_routine(kind)
    eq(vim.api.nvim_get_current_buf(), original)
    local source = 'CREATE OR REPLACE '
      .. kind:upper()
      .. ' public.users()\nAS $$\nBEGIN\n  -- body\nEND\n$$;'
    node = { kind = 'connection', name = 'other' }
    drawer.on_routine(vim.tbl_extend('force', request, { source = source }))
    eq(content(), source)
    eq(vim.b.sqmeow_connection, 'dev')
    eq(vim.bo.filetype, 'sql')
    eq(vim.bo.buftype, 'nofile')
    helpers.contains(vim.wo.winbar, 'dev')
    helpers.contains(vim.api.nvim_buf_get_name(0), '[Routine: public.users]')
  end
end

T['matches routine completions by request and complete identity'] = function()
  setup()
  local original = vim.api.nvim_get_current_buf()
  local request = request_routine()
  for _, mismatch in ipairs({
    { request_id = request.request_id + 1 },
    { conn_id = 2 },
    { schema = 'other' },
    { name = 'other' },
    { kind = 'procedure' },
  }) do
    drawer.on_routine(vim.tbl_extend('force', request, { source = 'wrong definition' }, mismatch))
    eq(vim.api.nvim_get_current_buf(), original)
  end
  drawer.on_routine(
    vim.tbl_extend('force', request, { source = 'first overload\n\nsecond overload' })
  )
  eq(content(), 'first overload\n\nsecond overload')
  drawer.on_routine(vim.tbl_extend('force', request, { source = 'duplicate response' }))
  eq(content(), 'first overload\n\nsecond overload')
end

T['reports hidden, unsupported and empty routine source without opening a buffer'] = function()
  setup()
  local message
  helpers.stub(require('sqmeow.core.utils'), 'notify', function(text)
    message = text
  end)
  local original = vim.api.nvim_get_current_buf()
  for _, error in ipairs({ 'encrypted routine', 'unsupported adapter' }) do
    local request = request_routine()
    drawer.on_routine(vim.tbl_extend('force', request, { error = error }))
    eq(message, error)
    eq(vim.api.nvim_get_current_buf(), original)
  end
  local request = request_routine()
  drawer.on_routine(vim.tbl_extend('force', request, { source = ' \n' }))
  helpers.contains(message, 'no visible source')
  eq(vim.api.nvim_get_current_buf(), original)
end

T['discards routine completions after disconnect, invalidation or restart'] = function()
  setup()
  helpers.stub(require('sqmeow.ui.relationships'), 'close', function() end)
  helpers.stub(require('sqmeow.ui.result'), 'forget', function() end)
  local original = vim.api.nvim_get_current_buf()
  for _, cancel in ipairs({
    function()
      drawer.forget(1)
    end,
    function()
      drawer.invalidate(1, node.path)
    end,
    drawer.reset,
    function()
      require('sqmeow.rpc.events').on_engine_restart()
    end,
  }) do
    local request = request_routine()
    cancel()
    drawer.on_routine(vim.tbl_extend('force', request, { source = 'late definition' }))
    eq(vim.api.nvim_get_current_buf(), original)
  end
  local request = request_routine()
  state.connections[1] = nil
  drawer.on_routine(vim.tbl_extend('force', request, { source = 'closed connection' }))
  eq(vim.api.nvim_get_current_buf(), original)
end

T['clears a rejected routine request'] = function()
  setup()
  node.kind = 'function'
  local request
  local message
  helpers.stub(require('sqmeow.core.utils'), 'notify', function(text)
    message = text
  end)
  rpc_request = function(_, params)
    request = params
    return nil, 'connection closed'
  end
  local original = vim.api.nvim_get_current_buf()
  drawer.actions.edit()
  eq(message, 'connection closed')
  drawer.on_routine(vim.tbl_extend('force', request, { source = 'late definition' }))
  eq(vim.api.nvim_get_current_buf(), original)
end

T['opens a bound scratch buffer with current columns as editable statements'] = function()
  setup()
  cache_columns({
    { name = 'id', type_name = 'integer', primary_key = true },
    { name = 'email', type_name = 'text', nullable = false },
  })
  drawer.actions.edit()
  eq(vim.bo.filetype, 'sql')
  eq(vim.bo.buftype, 'nofile')
  eq(vim.b.sqmeow_connection, 'dev')
  eq(vim.b.sqmeow_editor, true)
  helpers.contains(vim.api.nvim_buf_get_name(0), '[Alter: users]')
  helpers.contains(content(), 'ALTER COLUMN "id" TYPE integer;')
  helpers.contains(content(), 'ALTER COLUMN "email" TYPE text;')
  helpers.absent(content(), '-- Current columns:')
  helpers.contains(vim.wo.winbar, 'dev')
  local line = vim.api.nvim_win_get_cursor(0)[1]
  eq(vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1], 'ALTER TABLE "public"."users"')
end

T['loads uncached columns before opening and keeps the originating node'] = function()
  setup()
  local requests = 0
  rpc_request = function(method, params)
    requests = requests + 1
    eq(method, 'introspect')
    eq(params, { conn_id = 1, path = node.path })
    return true
  end
  local original = vim.api.nvim_get_current_buf()
  drawer.actions.edit()
  drawer.actions.edit()
  eq(requests, 1)
  eq(vim.api.nvim_get_current_buf(), original)
  local path = node.path
  node = { kind = 'connection', name = 'other' }
  drawer.on_nodes({ conn_id = 1, path = path, nodes = { { name = 'email', type_name = 'text' } } })
  helpers.contains(content(), 'ALTER TABLE "public"."users"')
  helpers.contains(content(), 'ALTER COLUMN "email" TYPE text;')
  eq(vim.b.sqmeow_connection, 'dev')
end

T['does not open an editor after failed introspection'] = function()
  setup()
  local message
  helpers.stub(require('sqmeow.core.utils'), 'notify', function(text)
    message = text
  end)
  rpc_request = function()
    return true
  end
  local original = vim.api.nvim_get_current_buf()
  drawer.actions.edit()
  drawer.on_nodes({ conn_id = 1, path = node.path, error = 'cannot read columns' })
  eq(message, 'cannot read columns')
  eq(vim.api.nvim_get_current_buf(), original)
end

T['reports immediate introspection failure and clears the pending edit'] = function()
  setup()
  local message
  helpers.stub(require('sqmeow.core.utils'), 'notify', function(text)
    message = text
  end)
  rpc_request = function()
    return nil, 'connection closed'
  end
  local original = vim.api.nvim_get_current_buf()
  drawer.actions.edit()
  eq(message, 'connection closed')
  cache_columns({ { name = 'email', type_name = 'text' } })
  eq(vim.api.nvim_get_current_buf(), original)
end

T['cancels pending edits on invalidation or engine reset'] = function()
  setup()
  rpc_request = function()
    return true
  end
  local original = vim.api.nvim_get_current_buf()
  for _, cancel in ipairs({
    function()
      drawer.invalidate(1, {})
    end,
    drawer.reset,
  }) do
    drawer.invalidate(1, {})
    drawer.actions.edit()
    cancel()
    cache_columns({ { name = 'email', type_name = 'text' } })
    eq(vim.api.nvim_get_current_buf(), original)
  end
end

T['uses surrealdb field statements and filetype'] = function()
  setup()
  state.connections[1].dialect = 'surrealdb'
  cache_columns({ { name = 'email', type_name = 'string' } })
  drawer.actions.edit()
  eq(vim.bo.filetype, 'surql')
  eq(vim.b.sqmeow_connection, 'dev')
  helpers.contains(content(), 'DEFINE FIELD OVERWRITE `email` ON TABLE `users` TYPE string;')
end

T['does not expose SQL editors for unsupported databases'] = function()
  setup()
  rpc_request = function()
    error('unsupported editing must not request columns')
  end
  local message
  helpers.stub(require('sqmeow.core.utils'), 'notify', function(text)
    message = text
  end)
  state.connections[1].dialect = 'mongodb'
  local original = vim.api.nvim_get_current_buf()
  drawer.actions.edit()
  eq(vim.api.nvim_get_current_buf(), original)
  helpers.contains(message, 'not supported')
end

T['opens a new buffer without overwriting earlier edits'] = function()
  setup()
  cache_columns({ { name = 'email', type_name = 'text' } })
  drawer.actions.edit()
  local first = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(first, 0, -1, false, { 'my edited template' })
  drawer.actions.edit()
  local second = vim.api.nvim_get_current_buf()
  eq(first == second, false)
  helpers.contains(vim.api.nvim_buf_get_name(second), '[Alter: users (1)]')
  eq(vim.api.nvim_buf_get_lines(first, 0, -1, false), { 'my edited template' })
end

T['preserves connection editing'] = function()
  setup()
  node = { kind = 'connection', name = 'dev' }
  local spec = { name = 'dev', url = 'postgres://localhost/dev' }
  helpers.stub(require('sqmeow.sources'), 'find', function(name)
    eq(name, 'dev')
    return spec
  end)
  local edited
  helpers.stub(require('sqmeow.ui.connection'), 'edit', function(value)
    edited = value
    return true
  end)
  drawer.actions.edit()
  eq(edited, spec)
end

T['preserves preview execution, reuse and modified buffers after sharing setup'] = function()
  setup()
  local executions = {}
  execute_query = function(statement, opts)
    table.insert(executions, { statement = statement, opts = opts })
  end
  use_connection = function(id)
    eq(id, 1)
  end
  drawer.actions.preview_editor()
  local first = vim.api.nvim_get_current_buf()
  helpers.contains(content(), 'select * from "public"."users"')
  helpers.contains(vim.wo.winbar, 'dev')
  eq(executions[1].opts.source_buf, first)
  eq(executions[1].opts.history, false)
  drawer.actions.preview_editor()
  eq(vim.api.nvim_get_current_buf(), first)
  vim.api.nvim_buf_set_lines(first, 0, -1, false, { 'edited preview' })
  drawer.actions.preview_editor()
  eq(vim.api.nvim_get_current_buf() == first, false)
  eq(vim.api.nvim_buf_get_lines(first, 0, -1, false), { 'edited preview' })
  eq(#executions, 3)
end

T['fetches a real postgres definition through the engine'] = function()
  local url = vim.env.SQMEOW_TEST_POSTGRES_URL
  if not url then
    MiniTest.skip('set SQMEOW_TEST_POSTGRES_URL for routine editing integration')
  end
  local id = helpers.connect(url, { name = 'routine-edit-smoke' })
  local opts = { conn_id = id }
  MiniTest.finally(function()
    helpers.run('DROP FUNCTION IF EXISTS public.sqmeow_editor_body(integer)', opts)
    helpers.run('DROP PROCEDURE IF EXISTS public.sqmeow_editor_proc()', opts)
    require('sqmeow.api.connection').disconnect(id)
  end)
  helpers.run(
    'CREATE OR REPLACE FUNCTION public.sqmeow_editor_body(n integer) RETURNS integer LANGUAGE sql AS $$ SELECT n + 17 $$',
    opts
  )
  helpers.run(
    'CREATE OR REPLACE PROCEDURE public.sqmeow_editor_proc() LANGUAGE plpgsql AS $$ BEGIN NULL; END $$',
    opts
  )
  local selected
  helpers.stub(drawer, 'current_node', function()
    return selected
  end)
  for _, routine in ipairs({
    { name = 'sqmeow_editor_body', kind = 'function', body = 'SELECT n + 17' },
    { name = 'sqmeow_editor_proc', kind = 'procedure', body = 'BEGIN NULL; END' },
  }) do
    selected = {
      kind = routine.kind,
      name = routine.name,
      conn_id = id,
      path = { 'public', routine.kind == 'function' and 'functions' or 'procedures', routine.name },
    }
    local call_id = state.call.call_id
    drawer.actions.edit()
    helpers.wait_for('the routine definition should reach its bound editor', function()
      return vim.api.nvim_buf_get_name(0):find('[Routine: public.' .. routine.name .. ']', 1, true)
        ~= nil
    end)
    eq(vim.b.sqmeow_connection, 'routine-edit-smoke')
    helpers.contains(content(), routine.body)
    eq(state.call.call_id, call_id)
    vim.api.nvim_buf_delete(0, { force = true })
  end
end

return T
