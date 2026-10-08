local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local query = require('sqmeow.api.query')
local rpc = require('sqmeow.rpc.client')
local state = require('sqmeow.core.state')
local result = require('sqmeow.ui.result')

local T = MiniTest.new_set()
local definitions, requests, prompts, opened
local restorations
local function hook_stub(target, key, value)
  local original = helpers.swap(target, key, value)
  restorations[#restorations + 1] = function()
    target[key] = original
  end
end
T['prompts'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require('sqmeow.config').apply({ query = { persist_history = false } })
      state.reset()
      state.connections[1] =
        { id = 1, name = 'first', url = 'sqlite::memory:', state = 'connected', dialect = 'sqlite' }
      state.connections[2] = {
        id = 2,
        name = 'second',
        url = 'sqlite::memory:',
        state = 'connected',
        dialect = 'sqlite',
      }
      state.current = 1
      definitions, requests, prompts, opened = {}, {}, {}, 0
      restorations = {}
      hook_stub(require('sqmeow.api.connection'), 'target', function()
        return state.connections[state.current]
      end)
      hook_stub(require('sqmeow.rpc.events'), 'ensure', function() end)
      hook_stub(require('sqmeow.ui.edit'), 'settle', function()
        return false
      end)
      hook_stub(result, 'open', function()
        opened = opened + 1
      end)
      hook_stub(result, 'update_winbar', function() end)
      hook_stub(rpc, 'request', function(method, args)
        requests[#requests + 1] = { method = method, args = args }
        if method == 'query_parameters' then
          return definitions
        elseif method == 'inspect' then
          return {}
        elseif method == 'execute' then
          return 42
        end
        error('unexpected RPC: ' .. method)
      end)
      hook_stub(vim.ui, 'input', function(opts, callback)
        prompts[#prompts + 1] = { opts = opts, callback = callback }
      end)
    end,
    post_case = function()
      for index = #restorations, 1, -1 do
        restorations[index]()
      end
      state.reset()
      require('sqmeow.config').apply({})
    end,
  },
})

T['prompts']['unannotated parameters use a simple name prompt'] = function()
  definitions = { { name = 'id', kind = 'auto' } }
  local id = query.execute('select :id;')
  eq(id, nil)
  eq(prompts[1].opts.prompt, 'id: ')
  prompts[1].callback('42')
  eq(requests[#requests].args.parameters, { id = '42' })
end

local function submitted()
  local calls = {}
  for _, request in ipairs(requests) do
    if request.method == 'execute' then
      calls[#calls + 1] = request.args
    end
  end
  return calls
end

T['prompts']['collects defaults and repeated names once before submission'] = function()
  definitions = {
    { name = 'name', kind = 'text', default = 'guest' },
    { name = 'count', kind = 'int', default = '2' },
    { name = 'name', kind = 'text' },
    { name = 'ratio', kind = 'float' },
    { name = 'active', kind = 'bool', default = 'true' },
  }
  local sql = 'select :name, :count, :name, :ratio, :active'
  local id, err = query.execute(sql)
  eq({ id, err }, { nil, 'waiting for parameter values' })
  eq(prompts[1].opts, { prompt = 'name (text): ', default = 'guest' })
  eq(opened, 0)
  prompts[1].callback('')
  eq(prompts[2].opts, { prompt = 'count (int): ', default = '2' })
  prompts[2].callback('2')
  eq(prompts[3].opts, { prompt = 'ratio (float): ', default = '' })
  prompts[3].callback('1.5')
  eq(prompts[4].opts, { prompt = 'active (bool): ', default = 'true' })
  eq(submitted(), {})
  prompts[4].callback('false')
  eq(#submitted(), 1)
  eq(submitted()[1].parameters, { name = '', count = '2', ratio = '1.5', active = 'false' })
  eq(state.call.statement, sql)
  eq(rawget(state.call, 'parameters'), nil)
end

T['prompts']['cancelling a later prompt leaves the existing result and edits alone'] = function()
  definitions = { { name = 'first', kind = 'text' }, { name = 'second', kind = 'text' } }
  local previous = { call_id = 7, statement = 'select 7', state = 'done' }
  state.call = previous
  helpers.stub(require('sqmeow.ui.edit'), 'settle', function()
    error('cancellation must not settle staged edits')
  end)
  query.execute('select :first, :second')
  prompts[1].callback('private-first-value')
  prompts[2].callback(nil)
  eq(submitted(), {})
  eq(opened, 0)
  eq(state.call, previous)
end

T['prompts']['freezes connection SQL and selectors during asynchronous input'] = function()
  definitions = { { name = 'value', kind = 'text' } }
  local buf = helpers.temp_buf({ 'select :value;' })
  local opts = { source_buf = buf, line = 0, history = false, where = '1 = 1' }
  query.execute('select :value;', opts)
  eq(requests[1].args, {
    conn_id = 1,
    sql = 'select :value;',
    line = 0,
    parameter_source = 'select :value;',
  })
  state.current = 2
  opts.line = 99
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'select 999;' })
  prompts[1].callback('private-value')
  local args = submitted()[1]
  eq({ args.conn_id, args.sql, args.line, args.where }, { 1, 'select :value;', 0, '1 = 1' })
  eq(args.parameter_source, 'select :value;')
  eq(state.call.conn_id, 1)
  eq(state.call.history, false)
  helpers.absent(vim.inspect(state.call), 'private-value')
end

T['prompts']['supplied values including an empty map bypass discovery and prompts'] = function()
  for _, parameters in ipairs({ { value = 'raw-secret' }, {} }) do
    eq(query.execute('select :value', { parameters = parameters }), 42)
    eq(submitted()[#submitted()].parameters, parameters)
  end
  eq(#prompts, 0)
  for _, request in ipairs(requests) do
    assert(request.method ~= 'query_parameters', 'supplied values must bypass discovery')
  end
  helpers.absent(vim.inspect(state.call), 'raw-secret')
end

T['prompts']['ordinary SQL avoids discovery while server can reject literal candidates'] = function()
  for _, sql in ipairs({ 'select 1', "select 'https://example.com'", 'select 1::int' }) do
    requests = {}
    eq(query.execute(sql), 42)
    eq(requests[1].method == 'query_parameters', false)
  end
  for _, sql in ipairs({ "select ':literal'", '-- @param unused text\nselect 1' }) do
    requests = {}
    eq(query.execute(sql), 42)
    eq(requests[1].method, 'query_parameters')
  end
  eq(#prompts, 0)
end

T['prompts']['discovery errors do not open or replace a result'] = function()
  local previous = { call_id = 7, state = 'done' }
  state.call = previous
  helpers.stub(vim, 'notify', function() end)
  helpers.stub(rpc, 'request', function()
    return nil, 'invalid parameter definition'
  end)
  local id, err = query.execute('select :value')
  eq(id, nil)
  eq(err, 'invalid parameter definition')
  eq(state.call, previous)
  eq(opened, 0)
  eq(#prompts, 0)
end

T['prompts']['synchronous input still reports deferred work from the outer call'] = function()
  definitions = { { name = 'value', kind = 'text' } }
  helpers.stub(vim.ui, 'input', function(_, callback)
    callback('value')
  end)
  local id, err = query.execute('select :value')
  eq(id, nil)
  eq(err, 'waiting for parameter values')
  eq(#submitted(), 1)
end

T['prompts']['staged edits and destructive confirmation retain collected values'] = function()
  definitions = { { name = 'value', kind = 'text' } }
  local retry, confirm
  helpers.stub(require('sqmeow.ui.edit'), 'settle', function(callback)
    retry = callback
    return true
  end)
  query.execute('delete from things where name = :value')
  prompts[1].callback('secret')
  eq(submitted(), {})
  helpers.stub(require('sqmeow.ui.edit'), 'settle', function()
    return false
  end)
  local request = rpc.request
  helpers.stub(rpc, 'request', function(method, args)
    if method == 'inspect' then
      return { 'delete' }
    end
    return request(method, args)
  end)
  helpers.stub(vim.ui, 'select', function(_, _, callback)
    confirm = callback
  end)
  state.current = 2
  retry()
  eq(opened, 0)
  confirm('Run it')
  eq(submitted()[1].parameters, { value = 'secret' })
  eq(submitted()[1].conn_id, 1)
  eq(#prompts, 1)
end

T['prompts']['statement visual selection and range keep their existing scopes'] = function()
  definitions = { { name = 'value', kind = 'text' } }
  local buf = helpers.temp_buf({ 'select 1;', 'select :value;', 'select 3;' })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  query.execute_statement()
  eq(requests[1].args.line, 1)
  prompts[1].callback('statement')
  eq(submitted()[1].line, 1)
  query.execute_range(2, 2)
  prompts[2].callback('range')
  eq(submitted()[2].sql, 'select :value;')
  eq(submitted()[2].line, nil)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys('V', 'mx', false)
  query.execute_selection()
  prompts[3].callback('selection')
  eq(submitted()[3].sql, 'select :value;')
end

T['sqlite'] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ query = { persist_history = false } })
    end,
    pre_case = function()
      helpers.connect('sqlite::memory:', { name = 'parameters' })
      restorations = {}
      hook_stub(vim.ui, 'input', function()
        error('integration queries must not prompt')
      end)
    end,
    post_case = function()
      for index = #restorations, 1, -1 do
        restorations[index]()
      end
      rpc.stop()
      state.reset()
    end,
  },
})

T['sqlite']['binds repeated supplied values and keeps secrets out of history and call state'] = function()
  local sql = 'select :secret = :secret as matches'
  local call = helpers.run(sql, { parameters = { secret = 'private-parameter-value' } })
  eq(call.state, 'done')
  eq(call.statement, sql)
  eq(rpc.request('row', { call_id = call.call_id, row = 0 })[1].value, '1')
  helpers.absent(vim.inspect(call), 'private-parameter-value')
  local entries = require('sqmeow.server.history').entries({ limit = 1 })
  eq(entries[1].statement, sql)
  helpers.absent(vim.inspect(entries[1]), 'private-parameter-value')
end

T['sqlite']['literal colons are ignored by actual server discovery'] = function()
  local sql = "select 'https://example.com/:not_a_parameter' as url"
  eq(rpc.request('query_parameters', { conn_id = state.current, sql = sql }), {})
  local call = helpers.run(sql)
  eq(call.state, 'done')
  eq(
    rpc.request('row', { call_id = call.call_id, row = 0 })[1].value,
    'https://example.com/:not_a_parameter'
  )
end

T['sqlite']['typed supplied values execute only the selected statement'] = function()
  local sql = table.concat({
    '-- @param count int = 2',
    '-- @param ratio float = 1.5',
    '-- @param active bool = true',
    'select :unused;',
    'select :count + :ratio as total, :active as active;',
  }, '\n')
  local discovered =
    rpc.request('query_parameters', { conn_id = state.current, sql = sql, line = 4 })
  eq(discovered, {
    { name = 'count', kind = 'int', default = '2' },
    { name = 'ratio', kind = 'float', default = '1.5' },
    { name = 'active', kind = 'bool', default = 'true' },
  })
  local call = helpers.run(sql, {
    line = 4,
    parameters = { count = '2', ratio = '1.5', active = 'true' },
  })
  eq(call.state, 'done')
  local row = rpc.request('row', { call_id = call.call_id, row = 0 })
  eq(row[1].value, '3.5')
  eq(row[2].value, '1')
end

T['sqlite']['uses defaults and preserves null empty and literal NULL text'] = function()
  local sql = [[-- @param count int = 42
-- @param missing text = NULL
-- @param empty text = ""
-- @param literal text = "NULL"
select :count as count, :missing as missing, :empty as empty, :literal as literal]]
  local call = helpers.run(sql, { parameters = {} })
  eq(call.state, 'done')
  local row = rpc.request('row', { call_id = call.call_id, row = 0 })
  eq(row[1].value, '42')
  eq(row[2].is_null, true)
  eq(row[3].value, '')
  eq(row[4].value, 'NULL')
end

T['sqlite']['binds injection-like text without executing it'] = function()
  helpers.run('create table safe (id integer primary key, name text)')
  local value = "alice'); DROP TABLE safe; --"
  local call = helpers.run('insert into safe values (1, :name)', { parameters = { name = value } })
  eq(call.state, 'done')
  local selected = helpers.run('select name from safe')
  eq(rpc.request('row', { call_id = selected.call_id, row = 0 })[1].value, value)
end

T['sqlite']['validates later inputs before executing any statements'] = function()
  helpers.stub(vim, 'notify', function() end)
  local id, err = query.execute('create table must_not_exist (id int); select :missing', {
    parameters = {},
    confirmed = true,
  })
  eq(id, nil)
  helpers.contains(err, 'missing')
  local call =
    helpers.run("select count(*) as count from sqlite_master where name = 'must_not_exist'")
  eq(rpc.request('row', { call_id = call.call_id, row = 0 })[1].value, '0')
end

T['sqlite']['refresh reuses bound values and preserves editable provenance'] = function()
  helpers.run('create table people (id integer primary key, name text)')
  helpers.run("insert into people values (1, 'alice'), (2, 'bob')")
  local sql = '-- @param id int\nselect id, name from people where id = :id'
  local call = helpers.run(sql, { parameters = { id = '2' } })
  eq(call.state, 'done')
  eq(call.source.tables[1].name, 'people')
  local refreshed = rpc.request('result_view', {
    call_id = call.call_id,
    conn_id = call.conn_id,
    sql = call.sql,
    refresh = true,
  })
  eq(refreshed.route, 'query')
  helpers.wait_for('bound refresh should finish', function()
    return state.call.call_id == refreshed.call_id and state.call.state == 'done'
  end)
  eq(state.call.rows, 1)
  eq(rpc.request('row', { call_id = refreshed.call_id, row = 0 })[1].value, '2')
  eq(state.call.sql, call.sql)
end

T['sqlite']['selected ranges use declarations outside the selection'] = function()
  local buf = helpers.temp_buf({ '-- @param count int = 42', 'select :count + 1 as answer;' })
  local call = helpers.run('select :count + 1 as answer;', { source_buf = buf, parameters = {} })
  eq(call.state, 'done')
  eq(rpc.request('row', { call_id = call.call_id, row = 0 })[1].value, '43')
end

T['sqlite']['statement selection ignores unfinished unrelated SQL'] = function()
  local sql =
    "-- @param count int = 42\n-- @param unused invalid\nselect :count + 1 as answer;\nselect 'unfinished"
  local call = helpers.run(sql, { line = 2, parameters = {} })
  eq(call.state, 'done')
  eq(rpc.request('row', { call_id = call.call_id, row = 0 })[1].value, '43')
end

T['sqlite']['unannotated inputs infer types and can force text'] = function()
  local call =
    helpers.run('select :id + 1 as answer, :text as text, :empty as empty, :flag as flag', {
      parameters = { id = '42', text = '"42"', empty = '', flag = 'true' },
    })
  eq(call.state, 'done')
  local row = rpc.request('row', { call_id = call.call_id, row = 0 })
  eq(row[1].value, '43')
  eq(row[2].value, '42')
  eq(row[3].value, '')
  eq(row[4].value, '1')
end

T['sqlite']['bound results respect retained row limits'] = function()
  require('sqmeow').setup({ query = { max_rows = 2, persist_history = false } })
  local call = helpers.run(
    '-- @param limit int = 5\nwith recursive n(x) as (select 1 union all select x+1 from n where x < :limit) select x from n',
    { parameters = {} }
  )
  eq(call.state, 'done')
  eq(call.rows, 2)
  eq(call.truncated, true)
end

T['sqlite']['restored results do not silently refresh using defaults'] = function()
  helpers.stub(vim, 'notify', function() end)
  require('sqmeow.config').apply({ query = { persist_history = true } })
  local history = require('sqmeow.server.history')
  local sql = '-- @param n int = 1\nselect :n as n'
  local call = helpers.run(sql, { parameters = { n = '2' } })
  helpers.wait_for('parameterized result should be archived', function()
    return vim.uv.fs_stat(call.archive) ~= nil
  end)
  local entry = history.entries({ limit = 1 })[1]
  require('sqmeow.api.view').restore(entry)
  helpers.wait_for('archive should be restored', function()
    return state.call.call_id ~= call.call_id and state.call.state == 'done'
  end)
  local restored = state.call.call_id
  local answer, err = rpc.request('result_view', {
    call_id = restored,
    conn_id = call.conn_id,
    sql = sql,
    refresh = true,
  })
  eq(answer, nil)
  helpers.contains(err, 'parameter values are no longer held')
  eq(rpc.request('row', { call_id = restored, row = 0 })[1].value, '2')
end

T['duckdb'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require('sqmeow').setup({ query = { persist_history = false } })
      state.reset()
      helpers.connect('duckdb::memory:', { name = 'parameter_duckdb' })
    end,
    post_case = function()
      rpc.stop()
    end,
  },
})

T['duckdb']['prompts and native execution preserve typed values through refresh'] = function()
  local sql = 'select :id as id, :id + 1 as answer, :flag as flag, :name as name'
  local names = {}
  helpers.stub(vim.ui, 'input', function(opts, callback)
    names[#names + 1] = opts.prompt
    callback(
      ({ ['id: '] = '42', ['flag: '] = 'true', ['name: '] = "Alice' ; SELECT 99 --" })[opts.prompt]
    )
  end)
  query.execute(sql)
  helpers.wait_for('DuckDB prompted run should finish', function()
    return state.call ~= nil and state.call.state ~= 'executing'
  end)
  local call = assert(state.call, 'the prompted query should leave a result')
  eq(call.state, 'done')
  eq(names, { 'id: ', 'flag: ', 'name: ' })
  local row = rpc.request('row', { call_id = call.call_id, row = 0 })
  eq(row[1].value, '42')
  eq(row[2].value, '43')
  eq(row[3].value, 'true')
  eq(row[4].value, "Alice' ; SELECT 99 --")
  local refresh = rpc.request('result_view', {
    call_id = call.call_id,
    conn_id = call.conn_id,
    sql = call.sql,
    refresh = true,
  })
  helpers.wait_for('DuckDB bound refresh should finish', function()
    return state.call.call_id == refresh.call_id and state.call.state ~= 'executing'
  end)
  eq(state.call.state, 'done')
  eq(rpc.request('row', { call_id = refresh.call_id, row = 0 }), row)
  eq(#names, 3)
end

return T
