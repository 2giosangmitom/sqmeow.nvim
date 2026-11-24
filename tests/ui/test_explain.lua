-- Visual execution plan viewer: query wrapping, tree enrichment, rendering,
-- folding, navigation, operator detail popup, and silent RPC execution.
---@diagnostic disable: duplicate-set-field
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.ui.helpers')

local explain = require('sqmeow.ui.explain')
local events = require('sqmeow.rpc.events')
local rpc = require('sqmeow.rpc.client')
local state = require('sqmeow.core.state')
local result = require('sqmeow.ui.result')
local history = require('sqmeow.server.history')

local function sample_plan()
  return {
    {
      ['Planning Time'] = 0.42,
      ['Execution Time'] = 10.0,
      Plan = {
        ['Node Type'] = 'Hash Join',
        ['Join Type'] = 'Inner',
        ['Hash Cond'] = '(o.customer_id = c.id)',
        ['Startup Cost'] = 10.0,
        ['Total Cost'] = 100.0,
        ['Plan Rows'] = 500,
        ['Actual Rows'] = 500,
        ['Actual Loops'] = 1,
        ['Actual Total Time'] = 10.0,
        ['Shared Hit Blocks'] = 20,
        ['Shared Read Blocks'] = 2,
        Plans = {
          {
            ['Node Type'] = 'Seq Scan',
            ['Relation Name'] = 'orders',
            ['Alias'] = 'o',
            ['Filter'] = "(status = 'paid')",
            ['Startup Cost'] = 0.0,
            ['Total Cost'] = 70.0,
            ['Plan Rows'] = 10,
            ['Actual Rows'] = 500,
            ['Actual Loops'] = 1,
            ['Actual Total Time'] = 7.0,
            ['Shared Hit Blocks'] = 100,
            ['Shared Read Blocks'] = 5,
          },
          {
            ['Node Type'] = 'Index Scan',
            ['Relation Name'] = 'customers',
            ['Index Name'] = 'customers_pkey',
            ['Startup Cost'] = 0.15,
            ['Total Cost'] = 15.0,
            ['Plan Rows'] = 100,
            ['Actual Rows'] = 100,
            ['Actual Loops'] = 1,
            ['Actual Total Time'] = 1.0,
            ['Shared Hit Blocks'] = 15,
            ['Shared Read Blocks'] = 0,
          },
        },
      },
    },
  }
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      explain.close()
      explain.invalidate()
    end,
  },
})

T['detects read-only statements through leading comments'] = function()
  eq(explain.is_read_only('SELECT * FROM orders'), true)
  eq(
    explain.is_read_only('-- comment\n/* block */\nWITH cte AS (SELECT 1) SELECT * FROM cte'),
    true
  )
  eq(explain.is_read_only('VALUES (1, 2)'), true)
  eq(explain.is_read_only('UPDATE orders SET status = 1'), false)
  eq(explain.is_read_only('DELETE FROM orders WHERE id = 1'), false)
  eq(explain.is_read_only('INSERT INTO orders VALUES (1)'), false)
end

T['strips existing EXPLAIN prefixes and trailing semicolons'] = function()
  eq(explain.strip_explain('EXPLAIN (ANALYZE, BUFFERS) SELECT 1;  '), 'SELECT 1')
  eq(explain.strip_explain('EXPLAIN SELECT * FROM orders;'), 'SELECT * FROM orders')
end

T['builds dialect-specific EXPLAIN queries safely'] = function()
  local sql, analyze, err = explain.build_query('postgres', 'SELECT * FROM orders;')
  eq(err, nil)
  eq(analyze, true)
  eq(sql, 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM orders')

  local wsql, wanalyze, werr = explain.build_query('postgres', 'DELETE FROM orders WHERE id = 1;')
  eq(werr, nil)
  eq(wanalyze, false)
  eq(wsql, 'EXPLAIN (FORMAT JSON) DELETE FROM orders WHERE id = 1')

  local forced, fanalyze = explain.build_query('cockroachdb', 'SELECT 1', { analyze = false })
  eq(fanalyze, false)
  eq(forced, 'EXPLAIN (FORMAT JSON) SELECT 1')

  local bad, _, bad_err = explain.build_query('redis', 'GET foo')
  eq(bad, nil)
  eq(bad_err ~= nil, true)
end

T['extracts the statement containing the cursor line'] = function()
  local lines = {
    'SELECT 1;',
    '',
    'SELECT *',
    'FROM orders;',
    'SELECT 3;',
  }
  eq(explain.statement_at_line(lines, 1), 'SELECT 1;')
  eq(explain.statement_at_line(lines, 3), 'SELECT *\nFROM orders;')
  eq(explain.statement_at_line(lines, 5), 'SELECT 3;')
end

T['enriches plan nodes with exclusive time, cost, buffers, and flags'] = function()
  local doc = sample_plan()
  local root = doc[1].Plan
  local stats = explain.enrich(root, 10.0, 100.0, true)

  eq(stats.seq_scans, 1)
  eq(stats.mismatches, 1)
  eq(stats.shared_hit, 135)
  eq(stats.shared_read, 7)

  -- Hash Join exclusive time: 10.0 - (7.0 + 1.0) = 2.0ms => 20%
  eq(math.floor(root._meta.excl_time + 0.5), 2)
  eq(math.floor(root._meta.pct + 0.5), 20)

  local seq = root.Plans[1]
  eq(seq._meta.is_seq_scan, true)
  eq(seq._meta.has_mismatch, true)
  eq(seq._meta.flags, { 'FULL SCAN', 'EST MISMATCH' })
end

T['renders operator tree, supports jump, fold, yank, and close'] = function()
  local doc = sample_plan()
  local raw = vim.json.encode(doc)
  local ok = explain.render(doc, raw, 'SELECT * FROM orders', {
    is_analyze = true,
    connection = 'demo',
  })
  eq(ok, true)

  local v = assert(explain.state())
  eq(vim.bo[v.buf].filetype, 'sqmeow-explain')
  eq(vim.bo[v.buf].modifiable, false)

  local lines = vim.api.nvim_buf_get_lines(v.buf, 0, -1, false)
  local joined = table.concat(lines, '\n')
  eq(joined:find('Hash Join', 1, true) ~= nil, true)
  eq(joined:find('Seq Scan on orders', 1, true) ~= nil, true)
  eq(joined:find('[FULL SCAN, EST MISMATCH]', 1, true) ~= nil, true)
  eq(joined:find('Index Scan on customers (customers_pkey)', 1, true) ~= nil, true)

  -- Cursor starts on root operator (line 5); next_operator moves to child on line 6
  eq(vim.api.nvim_win_get_cursor(v.win)[1], 5)
  explain.actions.next_operator()
  eq(vim.api.nvim_win_get_cursor(v.win)[1], 6)
  explain.actions.prev_operator()
  eq(vim.api.nvim_win_get_cursor(v.win)[1], 5)

  -- Folding root hides its children
  explain.actions.toggle_fold()
  local folded = table.concat(vim.api.nvim_buf_get_lines(v.buf, 0, -1, false), '\n')
  eq(folded:find('Seq Scan on orders', 1, true), nil)
  explain.actions.toggle_fold()
  local unfolded = table.concat(vim.api.nvim_buf_get_lines(v.buf, 0, -1, false), '\n')
  eq(unfolded:find('Seq Scan on orders', 1, true) ~= nil, true)

  -- Yank copies raw JSON to unnamed register
  explain.actions.yank_json()
  eq(vim.fn.getreg('"'), raw)

  -- Close cleans up state
  explain.actions.close()
  eq(explain.state(), nil)
end

T['runs silently via RPC without opening result grid or overwriting state.call'] = function()
  local doc = sample_plan()
  local raw = vim.json.encode(doc)
  local prev_call = { call_id = 99, state = 'done', sql = 'SELECT 42' }
  state.call = prev_call

  local result_rendered = false
  local history_appended = false
  local rpc_methods = {}

  helpers.stub(result, 'render', function()
    result_rendered = true
  end)
  helpers.stub(history, 'append', function()
    history_appended = true
  end)
  helpers.stub(rpc, 'request', function(method, args)
    table.insert(rpc_methods, { method = method, args = args })
    if method == 'execute' then
      return 101, nil
    elseif method == 'rows' then
      return { rows = { { raw } } }, nil
    end
    return nil, 'unexpected'
  end)

  local cid = explain.run({ id = 1, name = 'pg', dialect = 'postgres' }, 'SELECT * FROM orders')
  eq(cid, 101)
  eq(rpc_methods[1].method, 'execute')

  -- Deliver executing and done events through events.on_call
  events.on_call({ call_id = 101, conn_id = 1, state = 'executing' })
  events.on_call({ call_id = 101, conn_id = 1, state = 'done', rows = 1 })

  vim.wait(1000, function()
    return explain.state() ~= nil
  end)

  eq(result_rendered, false)
  eq(history_appended, false)
  eq(state.call, prev_call)
  eq(explain.state() ~= nil, true)
  eq(rpc_methods[2].method, 'rows')
  eq(rpc_methods[2].args.call_id, 101)
end

return T
