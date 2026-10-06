-- These tests temporarily replace module functions to isolate RPC and popup behavior.
---@diagnostic disable: duplicate-set-field
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local browser = require('sqmeow.ui.relationships')
local state = require('sqmeow.core.state')
local rpc = require('sqmeow.rpc.client')
local popup = require('sqmeow.ui.popup')
local requests, shown, active
local original_request, original_popup, original_ensure

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state.reset()
      state.add_connection({ id = 1, state = 'connected', name = 'test', url = 'sqlite::memory:' })
      requests, shown = {}, {}
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

T['renders directions, ordered composite columns, distinct constraints and self references'] = function()
  local lines, targets = browser.lines({
    schema = 'public',
    relation = 'users',
    relationships = {
      key('team_fk', 'users', 'teams', { 'tenant', 'team' }, { 'tenant_id', 'id' }),
      key('second_team_fk', 'users', 'teams'),
      key('posts_user_fk', 'posts', 'users'),
      key('manager_fk', 'users', 'users'),
      key('unrelated', 'other', 'teams'),
    },
  })
  eq(lines, {
    'Belongs to',
    '  team_fk: public.teams',
    '    public.users.tenant → public.teams.tenant_id',
    '    public.users.team → public.teams.id',
    '  second_team_fk: public.teams',
    '    public.users.parent_id → public.teams.id',
    '  manager_fk: public.users (self)',
    '    public.users.parent_id → public.users.id',
    '',
    'Referenced by',
    '  posts_user_fk: public.posts',
    '    public.posts.parent_id → public.users.id',
    '  manager_fk: public.users (self)',
    '    public.users.parent_id → public.users.id',
  })
  eq(targets[3], { schema = 'public', relation = 'teams' })
  eq(targets[11], { schema = 'public', relation = 'posts' })
  eq(targets[13], { schema = 'public', relation = 'users' })
end

T['empty and unsupported are explicit, and transport errors use the popup'] = function()
  browser.open(1, 'public', 'users')
  browser.on_done(answer())
  eq(shown[#shown].lines, { 'Belongs to', '  None', '', 'Referenced by', '  None' })
  browser.open(1, 'public', 'users')
  browser.on_done(answer(nil, { error = 'foreign keys unsupported for Redis' }))
  eq(shown[#shown].lines, { 'Relationships unavailable', '  foreign keys unsupported for Redis' })
  rpc.request = function()
    return nil, 'transport unavailable'
  end
  browser.open(1, '', 'users')
  eq(shown[#shown].lines, { 'Relationships unavailable', '  transport unavailable' })
end

T['unqualified request uses resolved schema without changing reply identity'] = function()
  browser.open(1, '', 'users')
  browser.on_done(answer({
    key('team_fk', 'users', 'teams'),
    key('posts_fk', 'posts', 'users'),
  }, { resolved_schema = 'public' }))
  local lines = shown[#shown].lines
  eq(vim.tbl_contains(lines, '  team_fk: public.teams'), true)
  eq(vim.tbl_contains(lines, '  posts_fk: public.posts'), true)
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
  eq(shown[#shown].lines, {
    'Belongs to',
    '  None',
    '',
    'Referenced by',
    '  posts_user_fk: public.posts',
    '    public.posts.parent_id → public.Users.id',
  })
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

T['configurable keys include disabling popup close defaults'] = function()
  require('sqmeow.config').apply({ keymaps = { relationships = { browse = 'o', close = false } } })
  browser.open(1, 'public', 'users')
  eq(shown[#shown].close_maps, false)
  eq(vim.fn.maparg('o', 'n', false, true).buffer, 1)
  eq(vim.fn.maparg('q', 'n', false, true), {})
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
      tables = { { schema = 'public', name = 'users', columns = { 0 } } },
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

T['real popup stays alive across replies and one hop, then leaving invalidates it'] = function()
  popup.open = original_popup
  browser.open(1, 'public', 'users')
  eq(vim.bo.filetype, 'sqmeow-relationships')
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'Loading relationships…' })
  browser.on_done(answer({ key('team_fk', 'users', 'teams') }))
  eq(vim.bo.filetype, 'sqmeow-relationships')
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  browser.actions.browse()
  eq(requests[#requests].relation, 'teams')
  eq(vim.bo.filetype, 'sqmeow-relationships')
  local late = answer()
  vim.cmd('wincmd p')
  browser.on_done(late)
  eq(vim.bo.filetype ~= 'sqmeow-relationships', true)
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
        widest = 7,
        nulls = false,
        numeric = true,
      },
      {
        name = 'team_id',
        type_name = 'int',
        class = 'number',
        widest = 7,
        nulls = false,
        numeric = true,
      },
    },
    source = {
      kind = 'table',
      name = 'users',
      tables = {
        { schema = 'public', name = 'users', columns = { 0 } },
        { schema = 'other', name = 'teams', columns = { 1 } },
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

return T
