local MiniTest = require('mini.test')
-- Lua API and RPC against a real engine; assert data rather than rendered text.
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local rpc = require('sqmeow.rpc.client')
local state = require('sqmeow.core.state')
local run = helpers.run
local primary

local function setup(opts)
  require('sqmeow').setup(opts or {})
end

local function row(index)
  return rpc.request('row', { call_id = state.call.call_id, row = index or 0 })
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      rpc.stop()
      state.reset()
      vim.cmd('enew')
      setup()
      primary = helpers.connect('sqlite::memory:', { name = 'first' })
      run('create table people (id integer primary key, name text, score real, avatar blob)')
      run([[insert into people values
        (1, 'alice', 9.5, x'deadbeef'), (2, 'bob', 7.0, null), (3, null, null, null)]])
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

T['failed connections are forgotten without replacing the working connection'] = function()
  eq(state.current_connection().state, 'connected')
  eq(state.current_connection().dialect, 'sqlite')
  local id = helpers.connect('oracle://localhost/x')
  eq(state.connections[id], nil)
  eq(state.current, primary)
end

T['queries return columns values nulls and binary data'] = function()
  local summary = run('select id, name, avatar from people order by id')
  eq(summary.state, 'done')
  eq(summary.rows, 3)
  eq(#summary.columns, 3)
  eq(summary.capabilities, { query = true, memory = true, filter = true })
  local first = assert(row())
  eq(first[1].name, 'id')
  eq(first[1].value, '1')
  eq(first[2].value, 'alice')
  eq(first[2].is_null, false)
  eq(first[3].value, '0xdeadbeef')
  eq(row(2)[2].is_null, true)
end

T['empty results retain columns and out of range rows are rejected'] = function()
  local summary = run('select id, name from people where 0')
  eq(summary.rows, 0)
  eq(#summary.columns, 2)
  local values, err = row(99)
  eq(values, nil)
  eq(err ~= nil, true)
end

T['writes report affected rows'] = function()
  local summary = run('update people set score = score where id in (1, 2)')
  eq(summary.rows, 0)
  eq(summary.affected, 2)
end

T['timeouts stop execution and leave the connection usable'] = function()
  setup({ query = { timeout_ms = 50 } })
  MiniTest.finally(setup)
  local summary = run([[with recursive n(x) as
    (select 1 union all select x + 1 from n where x < 100000000) select count(*) from n]])
  eq(summary.state, 'error')
  helpers.contains(summary.error, 'timeout')
  eq(run('select 1').state, 'done')
end

T['multi-statement queries retain every result without splitting quoted semicolons'] = function()
  local summary = run([[select 'a;b' as first; select 2 as second]])
  eq(#summary.results, 2)
  eq(summary.columns[1].name, 'second')
  local first = rpc.request('row', { call_id = summary.results[1].call_id, row = 0 })
  eq(first[1].value, 'a;b')
  eq(row()[1].value, '2')
end

T['archived multi-statement results restore together'] = function()
  local summary = run('select 1 as first; select 2 as second')
  local earlier = summary.results[1].archive
  helpers.wait_for('both results should be saved', function()
    return vim.uv.fs_stat(earlier) ~= nil and vim.uv.fs_stat(summary.archive) ~= nil
  end)
  local entry = require('sqmeow.server.history').entries({ limit = 1 })[1]
  eq(entry.results, { earlier })
  local before = state.call.call_id
  require('sqmeow.api.view').restore(entry)
  helpers.wait_for('the run should be restored', function()
    return state.call.call_id ~= before and state.call.state == 'done'
  end)
  eq(#state.call.results, 2)
  eq(state.call.columns[1].name, 'second')
  eq(row()[1].value, '2')
end

T['a failed batch retains every completed result'] = function()
  for count, prefix in ipairs({ 'select 1 as first;', 'select 1 as first; select 2 as second;' }) do
    local summary = run(prefix .. ' select nope from people')
    eq(summary.state, 'error')
    helpers.contains(summary.error, 'nope')
    eq(#(summary.results or {}), count + 1)
    for index = 1, count do
      local completed = summary.results[index]
      eq(completed.state, 'done')
      eq(rpc.request('row', { call_id = completed.call_id, row = 0 })[1].value, tostring(index))
    end
    eq(summary.results[count + 1].state, 'error')
  end
end

T['a failed query does not evict the previous result'] = function()
  setup({ query = { history_size = 1 } })
  MiniTest.finally(setup)
  local previous = run('select 42 as kept').call_id
  eq(run('select nope from people').state, 'error')
  eq(rpc.request('row', { call_id = previous, row = 0 })[1].value, '42')
end

T['evicted results can be restored from their archive'] = function()
  setup({ query = { history_size = 1 } })
  MiniTest.finally(setup)
  local first = vim.deepcopy(run("select 'kept on disk' as note"))
  helpers.wait_for('the result should be saved', function()
    return vim.uv.fs_stat(first.archive) ~= nil
  end)
  run('select 2')
  require('sqmeow.api.view').restore({
    result = first.archive,
    dialect = 'sqlite',
    statement = first.sql,
  })
  helpers.wait_for('the result should restore', function()
    return state.call.state == 'done' and state.call.columns[1].name == 'note'
  end)
  eq(row()[1].value, 'kept on disk')
end

T['empty queries do not execute and database errors leave the connection usable'] = function()
  eq(require('sqmeow.api.query').execute('   \n  '), nil)
  eq(require('sqmeow.api.query').execute('-- just a comment'), nil)
  local summary = run('select nope from people')
  eq(summary.state, 'error')
  helpers.contains(summary.error, 'nope')
  eq(run('select id from people').state, 'done')
end

T['row limits bound retained data and RPC pages preserve row order'] = function()
  setup({ query = { max_rows = 5 } })
  MiniTest.finally(setup)
  local summary = run([[with recursive n(x) as
    (select 1 union all select x + 1 from n where x < 50) select x from n]])
  eq(summary.rows, 5)
  eq(summary.truncated, true)
  local page = rpc.request('rows', { call_id = summary.call_id, offset = 4, limit = 4 })
  eq(page.total, 5)
  eq(page.indices, { 4 })
  eq(rpc.request('rows', { call_id = summary.call_id, offset = 5, limit = 4 }).indices, {})
end

T['buffer bindings override the active connection and reject unavailable targets'] = function()
  local second = helpers.connect('sqlite::memory:', { name = 'second' })
  MiniTest.finally(function()
    require('sqmeow.api.connection').disconnect(second)
    state.current = primary
  end)
  require('sqmeow.api.connection').use(primary)
  local buf = helpers.temp_buf({ 'select 1 as one' })
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].sqmeow_connection = 'second'
  local id = assert(require('sqmeow.api.query').execute_buffer())
  helpers.wait_for('the bound query should finish', function()
    return state.call.call_id == id and state.call.state == 'done'
  end)
  eq(state.call.conn_id, second)
  vim.b[buf].sqmeow_connection = 'gone'
  eq(require('sqmeow.api.query').execute_buffer(), nil)
  vim.b[buf].sqmeow_connection = nil
  eq(require('sqmeow.api.connection').target().id, primary)
end

T['disconnect disables refresh but retains local result capabilities'] = function()
  local id = helpers.connect('sqlite::memory:', { name = 'capability-check' })
  local summary = run('select 1 as value', { conn_id = id })
  eq(rpc.request('result_capabilities', { call_id = summary.call_id }).query, true)
  require('sqmeow.api.connection').disconnect(id)
  helpers.wait_for('the connection should close', function()
    return state.connections[id] == nil
  end)
  eq(rpc.request('result_capabilities', { call_id = summary.call_id }), {
    query = false,
    memory = true,
    filter = true,
  })
end

T['exports selected rows and typed whole results to files'] = function()
  run('select id, name from people order by id')
  for _, spec in ipairs({
    { format = 'csv', headers = false, offset = 1, limit = 1 },
    { format = 'json' },
  }) do
    local path = vim.fn.tempname()
    MiniTest.finally(function()
      vim.fn.delete(path)
    end)
    spec.path = path
    require('sqmeow.api.export').export(spec)
    helpers.wait_for('the export should finish', function()
      local stat = vim.uv.fs_stat(path)
      return stat ~= nil and stat.size > 0
    end)
    local text = table.concat(vim.fn.readfile(path, 'b'), '\n')
    if spec.format == 'csv' then
      eq(text, '2,bob\n')
    else
      local decoded = vim.json.decode(text)
      eq(#decoded, 3)
      eq(decoded[1].name, 'alice')
      eq(decoded[3].name, vim.NIL)
    end
  end
end

T['export overwrite confirmation is tied to the destination file'] = function()
  run('select id, name from people order by id')
  local path = helpers.temp_file({ 'existing data' })
  local spec
  helpers.stub(require('sqmeow.ui.form'), 'open', function(options)
    spec = options
    return true
  end)
  require('sqmeow.api.export').export()
  local values = { path = vim.fs.dirname(path), filename = vim.fs.basename(path) }
  eq(spec.validate(values) ~= nil, true)
  eq(vim.fn.readfile(path), { 'existing data' })
  eq(spec.validate(values), nil)
  local other = helpers.temp_file({ 'other data' })
  values.filename = vim.fs.basename(other)
  eq(spec.validate(values) ~= nil, true)
  eq(vim.fn.readfile(other), { 'other data' })
  eq(spec.validate(values), nil)
end

return T
