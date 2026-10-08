local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local rpc = require('sqmeow.rpc.client')
local state = require('sqmeow.core.state')
local result = require('sqmeow.ui.result')
local connection

local function snapshot()
  return helpers.run('select country, amount, active from sales order by rowid')
end

local function apply(spec)
  local received
  local off = rpc.on('call:view', function(payload)
    received = payload
  end)
  assert(require('sqmeow.api.view').aggregate(spec))
  helpers.wait_for('Polars should finish the aggregate view', function()
    return received ~= nil
  end)
  off()
  assert(not received.error, received.error)
  return received
end

local function rows(offset, limit)
  return assert(
    rpc.request(
      'rows',
      { call_id = state.call.call_id, offset = offset or 0, limit = limit or 100 }
    )
  )
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      rpc.stop()
      state.reset()
      vim.cmd('enew')
      require('sqmeow').setup({
        query = { persist_history = true },
        ui = { result = { page_size = 1 } },
      })
      connection = helpers.connect('sqlite::memory:', { name = 'aggregate' })
      helpers.run('create table sales (country text, amount integer, active integer)')
      helpers.run(
        [[insert into sales values ('a', 2, 1), ('b', 5, 1), ('a', 3, 0), (null, null, 0), (null, null, 0)]]
      )
    end,
    post_case = function()
      require('sqmeow.ui.filter').close()
      rpc.stop()
      state.reset()
    end,
  },
})

T['grouping updates schema paging details export and reset without replacing the snapshot'] = function()
  local original = vim.deepcopy(snapshot())
  apply({
    group_by = 'country',
    aggregates = 'COUNT(*) AS users, SUM(amount) AS total',
    order_by = 'country ASC NULLS LAST',
  })
  eq(state.call.call_id, original.call_id)
  eq(state.call.aggregated, true)
  eq(state.call.source, nil)
  eq(state.call.rows, 3)
  eq(state.call.source_rows, 5)
  eq(state.call.columns[2].name, 'users')
  eq(rows(0, 1).rows, { { 'a', 2, 5 } })
  eq(rows(1, 1).rows, { { 'b', 1, 5 } })
  eq(rows(2, 1).rows, { { vim.NIL, 2, vim.NIL } })
  local detail = assert(rpc.request('row', { call_id = original.call_id, row = 0 }))
  eq(detail[2].name, 'users')
  eq(detail[2].value, '2')
  for _, all in ipairs({ false, true }) do
    eq(
      rpc.request('export_preview', { call_id = original.call_id, format = 'csv', all = all }),
      'country,users,total\na,2,5\nb,1,5\n,2,\n'
    )
  end
  helpers.contains(result.describe(state.call), 'read-only')
  apply({ group_by = '', aggregates = '', having = '', where = '', order_by = '' })
  eq(state.call.aggregated, false)
  eq(state.call.rows, 5)
  eq(state.call.columns, original.columns)
  eq(rows().rows[1], { 'a', 2, 1 })
end

T['aggregate history works after source table removal and disconnect'] = function()
  local original = vim.deepcopy(snapshot())
  helpers.run('drop table sales')
  require('sqmeow.api.view').reopen(original.call_id)
  require('sqmeow.api.connection').disconnect(connection)
  helpers.wait_for('connection should close', function()
    return state.connections[connection] == nil
  end)
  apply({
    group_by = 'country',
    aggregates = 'SUM(amount) AS total',
    where = 'active = 1',
    having = 'total >= 3',
    order_by = 'total DESC',
  })
  eq(rows().rows, { { 'b', 5 } })
  eq(state.call.capabilities.query, false)
  eq(state.call.call_id, original.call_id)
end

T['aggregate view survives reopening retained history'] = function()
  local original = vim.deepcopy(snapshot())
  apply({ group_by = 'country', aggregates = 'COUNT(*) AS n' })
  helpers.run('select 99 as unrelated')
  require('sqmeow.api.view').reopen(original.call_id)
  eq(state.call.aggregated, true)
  eq(state.call.columns[2].name, 'n')
  eq(rows().rows[1], { 'a', 2 })
  eq(state.call.original_columns[2].name, 'amount')
end

T['restored archived results aggregate without any live connection'] = function()
  local original = vim.deepcopy(snapshot())
  helpers.wait_for('snapshot should be archived', function()
    return vim.uv.fs_stat(original.archive) ~= nil
  end)
  require('sqmeow.api.connection').disconnect(connection)
  helpers.wait_for('connection should close', function()
    return state.connections[connection] == nil
  end)
  local id = assert(require('sqmeow.api.view').restore({
    result = original.archive,
    statement = original.sql,
    dialect = 'sqlite',
  }))
  helpers.wait_for('archive should restore', function()
    return state.call.call_id == id and state.call.state == 'done'
  end)
  apply({
    group_by = 'country',
    aggregates = 'COUNT(*) AS n, AVG(amount) AS average',
    having = 'n > 1',
  })
  eq(rows().total, 2)
  eq(rows().rows[1], { 'a', 2, 2.5 })
end

T['aggregation rejects editing and database refresh at the engine'] = function()
  local original = snapshot()
  apply({ group_by = 'country', aggregates = 'COUNT(*) AS n' })
  local _, err = rpc.request('plan', { call_id = original.call_id, changes = { deletes = { 0 } } })
  helpers.contains(err, 'read-only')
  _, err = rpc.request(
    'apply',
    { call_id = original.call_id, conn_id = connection, statements = { 'delete from sales' } }
  )
  helpers.contains(err, 'read-only')
  _, err = rpc.request('result_view', {
    call_id = original.call_id,
    refresh = true,
    conn_id = connection,
    sql = original.sql,
    aggregates = 'COUNT(*) AS n',
  })
  helpers.contains(err, 'snapshot-only')
end

T['invalid having preserves both the previous view and its specification'] = function()
  snapshot()
  apply({ group_by = 'country', aggregates = 'COUNT(*) AS n' })
  local before = rows()
  local spec = vim.deepcopy(result.spec())
  local received
  local off = rpc.on('call:view', function(payload)
    received = payload
  end)
  assert(require('sqmeow.api.view').aggregate({
    group_by = 'country',
    aggregates = 'SUM(amount) AS total',
    having = 'unknown > 1',
  }))
  helpers.wait_for('invalid having should report an error', function()
    return received ~= nil
  end)
  off()
  eq(type(received.error), 'string')
  eq(rows(), before)
  eq(result.spec(), spec)
  eq(state.call.columns[2].name, 'n')
end

T['filter bar applies group aggregate having and offers original columns'] = function()
  snapshot()
  result.open()
  require('sqmeow.ui.filter').open(3)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_line_count(buf), 5)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '',
    'total DESC',
    'country',
    'COUNT(*) AS users, SUM(amount) AS total',
    'users >= 2 AND total IS NOT NULL',
  })
  local received
  local off = rpc.on('call:view', function(payload)
    received = payload
  end)
  require('sqmeow.ui.filter').apply()
  helpers.wait_for('bar should apply the aggregate', function()
    return received ~= nil
  end)
  off()
  assert(not received.error, received.error)
  eq(rows().rows, { { 'a', 2, 5 } })
  require('sqmeow.ui.filter').open(3)
  local items = require('sqmeow.ui.filter').complete(0, 'am')
  eq(items[1].word, 'amount')
  require('sqmeow.ui.filter').close()
end

T['truncated snapshots warn and aggregate only retained rows'] = function()
  require('sqmeow').setup({ query = { max_rows = 3 } })
  snapshot()
  eq(state.call.truncated, true)
  apply({ aggregates = 'COUNT(*) AS n, SUM(amount) AS total' })
  eq(rows().rows, { { 3, 10 } })
  eq(state.call.source_rows, 3)
  eq(state.call.truncated, true)
  helpers.contains(result.describe(state.call), 'truncated')
end

T['latest reset supersedes aggregate work and keeps source metadata'] = function()
  local original = vim.deepcopy(snapshot())
  assert(
    require('sqmeow.api.view').aggregate({ group_by = 'country', aggregates = 'COUNT(*) AS n' })
  )
  local reset
  local off = rpc.on('call:view', function(payload)
    if payload.aggregated == false then
      reset = payload
    end
  end)
  result.actions.reset_view()
  helpers.wait_for('latest reset should finish', function()
    return reset ~= nil
  end)
  off()
  eq(state.call.columns, original.columns)
  eq(state.call.aggregated, false)
  eq(rows().total, 5)
  eq(result.spec().aggregates, '')
end

T['matching an aggregate cell adds having instead of filtering the source'] = function()
  snapshot()
  apply({ group_by = 'country', aggregates = 'COUNT(*) AS n' })
  helpers.stub(result, 'current_cell', function()
    return { row = 0, column = 1 }
  end)
  local received
  local off = rpc.on('call:view', function(payload)
    received = payload
  end)
  result.actions.filter_cell()
  helpers.wait_for('aggregate cell match should apply HAVING', function()
    return received ~= nil
  end)
  off()
  assert(not received.error, received.error)
  eq(result.spec().where, '')
  helpers.contains(result.spec().having, 'n')
  eq(rows().total, 2)
end

return T
