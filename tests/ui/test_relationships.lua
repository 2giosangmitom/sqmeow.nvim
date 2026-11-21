-- These tests temporarily replace module functions to isolate RPC and popup behavior.
---@diagnostic disable: duplicate-set-field
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local browser = require('sqmeow.ui.relationships')
local state = require('sqmeow.core.state')
local rpc = require('sqmeow.rpc.client')
local popup = require('sqmeow.ui.popup')
local requests, shown, active, condition_requests
local original_request, original_popup, original_ensure

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state.reset()
      state.add_connection({ id = 1, state = 'connected', name = 'test', url = 'sqlite::memory:' })
      requests, shown = {}, {}
      condition_requests = {}
      original_request, original_popup = rpc.request, popup.open
      original_ensure = require('sqmeow.rpc.events').ensure
      require('sqmeow.rpc.events').ensure = function() end
      rpc.request = function(method, args)
        eq(method, 'relationships')
        table.insert(requests, vim.deepcopy(args))
        return true
      end
      popup.open = function(spec)
        table.insert(shown, spec)
        local buf = vim.api.nvim_create_buf(false, true)
        local win = vim.api.nvim_open_win(buf, true, {
          relative = 'editor',
          row = 1,
          col = 1,
          width = 60,
          height = 10,
        })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, spec.lines)
        active = {
          bufnr = buf,
          winid = win,
          unmount = function()
            if vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_close(win, true)
            end
            if vim.api.nvim_buf_is_valid(buf) then
              vim.api.nvim_buf_delete(buf, { force = true })
            end
            spec.on_close()
          end,
        }
        return active
      end
    end,
    post_case = function()
      browser.close()
      rpc.request, popup.open = original_request, original_popup
      require('sqmeow.rpc.events').ensure = original_ensure
      state.reset()
      require('sqmeow.config').apply({})
    end,
  },
})

local function key(name, source, target, columns, referenced)
  return {
    name = name,
    source_schema = 'public',
    source_relation = source,
    target_schema = 'public',
    target_relation = target,
    columns = columns or { 'parent_id' },
    referenced = referenced or { 'id' },
  }
end

local function answer(keys, extra, request)
  return vim.tbl_extend('force', request or requests[#requests], {
    relationships = keys or {},
  }, extra or {})
end

--- Answer `key_conditions` while keeping the relationships mock in place.
---@param reply string[]|fun(args: table): string[]
local function mock_conditions(reply)
  local relationships = rpc.request
  rpc.request = function(method, args)
    if method == 'key_conditions' then
      table.insert(condition_requests, vim.deepcopy(args))
      return type(reply) == 'function' and reply(args) or reply
    end
    return relationships(method, args)
  end
end

T['unqualified request uses resolved schema without changing reply identity'] = function()
  browser.open(1, '', 'users')
  browser.on_done(answer({
    key('team_fk', 'users', 'teams'),
    key('posts_fk', 'posts', 'users'),
  }, { resolved_schema = 'public' }))
  vim.api.nvim_win_set_cursor(active.winid, { 2, 0 })
  browser.actions.browse()
  eq(requests[#requests].schema, 'public')
  eq(requests[#requests].relation, 'teams')
end

T['catalog spelling does not change request correlation'] = function()
  browser.open(1, 'public', 'users')
  browser.on_done(answer({ key('posts_user_fk', 'posts', 'Users') }, {
    resolved_schema = 'public',
    resolved_relation = 'Users',
  }))
  eq(#shown, 2)
  local _, targets = browser.lines(answer({ key('posts_user_fk', 'posts', 'Users') }, {
    resolved_schema = 'public',
    resolved_relation = 'Users',
  }))
  eq(vim.tbl_count(targets) > 0, true)
end

T['rejects every mismatched identity and repeated same-table requests'] = function()
  browser.open(1, 'public', 'users')
  local first = vim.deepcopy(requests[1])
  browser.open(1, 'public', 'users')
  eq(requests[2].request_id > first.request_id, true)
  local count = #shown
  browser.on_done(answer(nil, nil, first))
  for field, value in pairs({ conn_id = 2, schema = 'other', relation = 'other', request_id = -1 }) do
    browser.on_done(answer(nil, { [field] = value }))
  end
  eq(#shown, count)
  browser.on_done(answer())
  eq(#shown, count + 1)
  browser.on_done(answer())
  eq(#shown, count + 1)
end

T['close, buffer leave, disconnect and reset prevent late reopening'] = function()
  for _, close in ipairs({
    browser.close,
    function()
      shown[#shown].on_close()
    end,
    function()
      state.remove_connection(1)
    end,
    state.reset,
    require('sqmeow.rpc.events').on_engine_restart,
  }) do
    state.add_connection({ id = 1, state = 'connected', name = 'test', url = 'sqlite::memory:' })
    browser.open(1, 'public', 'users')
    local payload, count = answer(), #shown
    close()
    browser.on_done(payload)
    eq(#shown, count)
  end
end

T['outgoing, incoming and self navigation request only one hop'] = function()
  local keys = {
    key('team_fk', 'users', 'teams'),
    key('posts_fk', 'posts', 'users'),
    key('self_fk', 'users', 'users'),
  }
  for _, target in ipairs({ 'teams', 'posts', 'users' }) do
    browser.open(1, 'public', 'users')
    browser.on_done(answer(keys))
    local _, targets = browser.lines(answer(keys))
    local line
    for index, entry in pairs(targets) do
      if entry.relation == target then
        line = index
        break
      end
    end
    vim.api.nvim_win_set_cursor(active.winid, { line, 0 })
    local count = #requests
    browser.actions.browse()
    eq(#requests, count + 1)
    eq(requests[#requests].relation, target)
    eq(requests[#requests].schema, 'public')
  end
end

T['drawer uses the same exact relation as structure and ignores headings'] = function()
  local drawer = require('sqmeow.ui.drawer')
  local original = drawer.current_node
  MiniTest.finally(function()
    drawer.current_node = original
  end)
  drawer.current_node = function()
    return { conn_id = 1, kind = 'table', path = { 'public', 'tables', 'users' } }
  end
  drawer.actions.relationships()
  eq(requests[#requests].relation, 'users')
  eq(requests[#requests].schema, 'public')
  drawer.current_node = function()
    return { kind = 'schema' }
  end
  drawer.actions.relationships()
  eq(#requests, 1)
end

T['result uses provenance and the existing structure fallback without row predicates'] = function()
  local result = require('sqmeow.ui.result')
  state.call = {
    conn_id = 1,
    state = 'done',
    source = {
      kind = 'table',
      name = 'users',
      tables = { { schema = 'public', name = 'users', columns = { { index = 0, name = 'id' } } } },
    },
  }
  result.actions.relationships()
  eq(requests[#requests].relation, 'users')
  state.call =
    { conn_id = 1, state = 'done', sql = 'SELECT * FROM public.teams', dialect = 'postgres' }
  result.actions.relationships()
  eq(requests[#requests].relation, 'teams')
  eq(requests[#requests].schema, 'public')
  eq(vim.tbl_count(requests[#requests]), 4)
end

T['result column provenance selects the other joined table'] = function()
  local result = require('sqmeow.ui.result')
  MiniTest.finally(function()
    result.close()
  end)
  local win = result.open()
  state.call = {
    conn_id = 1,
    state = 'done',
    rows = 0,
    columns = {
      {
        name = 'user_id',
        type_name = 'int',
        class = 'number',
        nulls = false,
        numeric = true,
      },
      {
        name = 'team_id',
        type_name = 'int',
        class = 'number',
        nulls = false,
        numeric = true,
      },
    },
    source = {
      kind = 'table',
      name = 'users',
      tables = {
        { schema = 'public', name = 'users', columns = { { index = 0, name = 'user_id' } } },
        { schema = 'other', name = 'teams', columns = { { index = 1, name = 'team_id' } } },
      },
    },
  }
  result.redraw()
  vim.api.nvim_set_current_win(win)
  local header = vim.api.nvim_buf_get_lines(result.buffer(), 0, 1, false)[1]
  local start = assert(header:find('team_id', 1, true))
  vim.api.nvim_win_set_cursor(win, { 1, start - 1 })
  result.actions.relationships()
  eq(requests[#requests].relation, 'teams')
  eq(requests[#requests].schema, 'other')
end

T['gd and gr query referenced parent and referencing child rows'] = function()
  local executed = {}
  local query = require('sqmeow.api.query')
  local original_execute = query.execute
  local original_select = vim.ui.select
  MiniTest.finally(function()
    query.execute = original_execute
    vim.ui.select = original_select
  end)
  query.execute = function(sql_text, opts)
    table.insert(executed, { sql = sql_text, opts = opts })
  end
  mock_conditions(function(args)
    local column = args.columns[1].column
    return { ('"%s" = 42'):format(column) }
  end)

  browser.follow({
    conn_id = 1,
    schema = 'public',
    relation = 'orders',
    direction = 'outgoing',
    column = 'user_id',
    dialect = 'postgres',
    call_id = 5,
    row = 2,
    columns = { { index = 0, name = 'user_id' } },
  })
  browser.on_done(answer({
    key('orders_user_fk', 'orders', 'users', { 'user_id' }, { 'id' }),
  }))
  eq(#executed, 1)
  eq(executed[1].sql, 'select * from "public"."users" where "id" = 42')
  eq(executed[1].opts.conn_id, 1)
  eq(condition_requests[1].call_id, 5)
  eq(condition_requests[1].row, 2)
  eq(condition_requests[1].columns, { { index = 0, column = 'id', source = 'user_id' } })

  -- Incoming references with multiple child tables prompt via vim.ui.select.
  local selected_prompt
  vim.ui.select = function(items, opts, on_choice)
    selected_prompt = opts.prompt
    on_choice(items[2])
  end
  browser.follow({
    conn_id = 1,
    schema = 'public',
    relation = 'users',
    direction = 'incoming',
    column = 'id',
    dialect = 'postgres',
    call_id = 5,
    row = 2,
    columns = { { index = 0, name = 'id' } },
  })
  browser.on_done(answer({
    key('orders_user_fk', 'orders', 'users', { 'user_id' }, { 'id' }),
    key('invoices_user_fk', 'invoices', 'users', { 'customer_id' }, { 'id' }),
  }))
  eq(selected_prompt, 'Referenced by:')
  eq(#executed, 2)
  eq(executed[2].sql, 'select * from "public"."invoices" where "customer_id" = 42')
  eq(condition_requests[2].columns, { { index = 0, column = 'customer_id', source = 'id' } })
end

T['composite foreign keys match case-insensitively and warn when incomplete or staged'] = function()
  local executed = {}
  local notified = {}
  local query = require('sqmeow.api.query')
  local original_execute = query.execute
  local original_notify = vim.notify
  MiniTest.finally(function()
    query.execute = original_execute
    vim.notify = original_notify
  end)
  query.execute = function(sql_text, opts)
    table.insert(executed, { sql = sql_text, opts = opts })
  end
  vim.notify = function(msg, level)
    table.insert(notified, { msg = msg, level = level })
  end
  mock_conditions(function(args)
    local conditions = {}
    for _, item in ipairs(args.columns) do
      local value = item.column == 'tenant_id' and 7 or 10
      table.insert(conditions, ('"%s" = %d'):format(item.column, value))
    end
    return conditions
  end)

  browser.follow({
    conn_id = 1,
    schema = 'public',
    relation = 'order_items',
    direction = 'outgoing',
    column = 'order_id',
    dialect = 'postgres',
    call_id = 7,
    row = 3,
    columns = {
      { index = 0, name = 'TENANT_ID' },
      { index = 1, name = 'order_id' },
    },
  })
  browser.on_done(answer({
    key(
      'items_order_fk',
      'order_items',
      'orders',
      { 'tenant_id', 'order_id' },
      { 'tenant_id', 'id' }
    ),
  }))
  eq(#executed, 1)
  eq(executed[1].sql, 'select * from "public"."orders" where "tenant_id" = 7 and "id" = 10')
  eq(condition_requests[1].columns, {
    { index = 0, column = 'tenant_id', source = 'tenant_id' },
    { index = 1, column = 'id', source = 'order_id' },
  })

  -- Missing sibling key column warns instead of running a partial WHERE clause.
  browser.follow({
    conn_id = 1,
    schema = 'public',
    relation = 'order_items',
    direction = 'outgoing',
    column = 'order_id',
    dialect = 'postgres',
    call_id = 7,
    row = 3,
    columns = { { index = 1, name = 'order_id' } },
  })
  browser.on_done(answer({
    key(
      'items_order_fk',
      'order_items',
      'orders',
      { 'tenant_id', 'order_id' },
      { 'tenant_id', 'id' }
    ),
  }))
  eq(#executed, 1)
  eq(
    notified[#notified].msg,
    'sqmeow: `order_id` needs every column of its foreign key in this result'
  )

  -- A staged sibling value is not in the database yet, so following it would be a lie.
  browser.follow({
    conn_id = 1,
    schema = 'public',
    relation = 'order_items',
    direction = 'outgoing',
    column = 'order_id',
    dialect = 'postgres',
    call_id = 7,
    row = 3,
    columns = {
      { index = 0, name = 'tenant_id' },
      { index = 1, name = 'order_id' },
    },
    staged = { [0] = true },
  })
  browser.on_done(answer({
    key(
      'items_order_fk',
      'order_items',
      'orders',
      { 'tenant_id', 'order_id' },
      { 'tenant_id', 'id' }
    ),
  }))
  eq(#executed, 1)
  eq(
    notified[#notified].msg,
    'sqmeow: apply the staged change to `tenant_id` before following its foreign key'
  )
end

T['gd and gr work from the K row-details popup and warn on NULL cells'] = function()
  local detail = require('sqmeow.ui.detail')
  local result = require('sqmeow.ui.result')
  local notified = {}
  local captured
  local original_call = state.call
  local original_notify = vim.notify
  local original_follow = browser.follow
  popup.open = original_popup
  MiniTest.finally(function()
    detail.close()
    state.call = original_call
    vim.notify = original_notify
    browser.follow = original_follow
  end)
  vim.notify = function(msg, level)
    table.insert(notified, { msg = msg, level = level })
  end
  browser.follow = function(spec)
    captured = spec
  end

  state.call = {
    call_id = 11,
    conn_id = 1,
    state = 'done',
    columns = {
      {
        name = 'user_id',
        type_name = 'int',
        class = 'number',
        nulls = false,
        numeric = true,
        key = 'foreign_key',
      },
      {
        name = 'parent_id',
        type_name = 'int',
        class = 'number',
        nulls = true,
        numeric = true,
        key = 'foreign_key',
      },
    },
    source = {
      kind = 'table',
      name = 'orders',
      tables = {
        {
          schema = 'public',
          name = 'orders',
          columns = {
            { index = 0, name = 'user_id' },
            { index = 1, name = 'parent_id' },
          },
        },
      },
    },
  }
  rpc.request = function(method, params)
    if method == 'row' then
      return {
        { name = 'user_id', declared_type = 'int', value = 99 },
        { name = 'parent_id', declared_type = 'int', is_null = true },
      }
    end
    table.insert(requests, params)
    return true
  end

  detail.open(0)
  -- Line 2 is `parent_id` (NULL): should warn and not follow a relationship.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  detail.actions.goto_definition()
  eq(captured, nil)
  eq(notified[#notified].msg, 'sqmeow: `parent_id` is NULL')

  -- Line 1 is `user_id = 99`: should close detail popup and follow the relationship.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  detail.actions.goto_definition()
  eq(captured.relation, 'orders')
  eq(captured.schema, 'public')
  eq(captured.column, 'user_id')
  eq(captured.call_id, 11)
  eq(captured.row, 0)
  eq(captured.columns, {
    { index = 0, name = 'user_id' },
    { index = 1, name = 'parent_id' },
  })

  -- Direct follow_cell on NULL also warns.
  result.follow_cell('outgoing', { column = 1, name = 'parent_id', is_null = true }, { row = 0 })
  eq(notified[#notified].msg, 'sqmeow: `parent_id` is NULL')
end

T['follow_cell maps aliased columns and refuses staged edits and aggregate views'] = function()
  local result = require('sqmeow.ui.result')
  local edit = require('sqmeow.ui.edit')
  local notified = {}
  local captured
  local original_follow = browser.follow
  local original_notify = vim.notify
  MiniTest.finally(function()
    browser.follow = original_follow
    vim.notify = original_notify
    edit.reset()
  end)
  browser.follow = function(spec)
    captured = spec
  end
  vim.notify = function(msg, level)
    table.insert(notified, { msg = msg, level = level })
  end

  state.call = {
    call_id = 9,
    conn_id = 1,
    state = 'done',
    columns = {
      {
        name = 'uid',
        type_name = 'int',
        class = 'number',
        nulls = false,
        numeric = true,
      },
    },
    source = {
      kind = 'table',
      name = 'orders',
      tables = {
        {
          schema = 'public',
          name = 'orders',
          columns = { { index = 0, name = 'user_id' } },
        },
      },
    },
  }
  state.connections[1].dialect = 'postgres'

  result.follow_cell('outgoing', { column = 0, name = 'uid', is_null = false }, { row = 4 })
  eq(captured.column, 'user_id')
  eq(captured.row, 4)
  eq(captured.call_id, 9)
  eq(captured.dialect, 'postgres')
  eq(captured.columns, { { index = 0, name = 'user_id' } })
  eq(captured.staged, nil)

  edit.set({ row = 4 }, 0, '7')
  captured = nil
  result.follow_cell('outgoing', { column = 0, name = 'uid', is_null = false }, { row = 4 })
  eq(captured, nil)
  eq(
    notified[#notified].msg,
    'sqmeow: apply the staged change to `user_id` before following its foreign key'
  )

  edit.reset()
  state.call.aggregated = true
  captured = nil
  result.follow_cell('outgoing', { column = 0, name = 'uid', is_null = false }, { row = 4 })
  eq(captured, nil)
  eq(notified[#notified].msg, 'sqmeow: foreign keys cannot be followed from an aggregated result')
end

return T
