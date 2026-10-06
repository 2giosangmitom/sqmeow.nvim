local MiniTest = require('mini.test')
-- `:Sqmeow` dispatch, completion and connection routing.

local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local config = require('sqmeow.config')

local notes = {}
local original_notify
local project_load

local function complete(line)
  return vim.fn.getcompletion(line, 'cmdline')
end

--- Configure one saved connection, named `ci`, and nothing else.
local function saved_ci()
  require('sqmeow.sources.file').add({ name = 'ci', url = 'sqlite://ci.db' })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.apply({ core = { path = vim.fn.tempname() } })
      project_load = helpers.swap(require('sqmeow.sources.project'), 'load', function()
        return {}
      end)
      notes = {}
      original_notify = helpers.swap(vim, 'notify', function(message, level)
        table.insert(notes, { message = message, level = level or vim.log.levels.INFO })
      end)
    end,
    post_case = function()
      helpers.swap(require('sqmeow.sources.project'), 'load', project_load)
      vim.notify = original_notify
      vim.fn.delete(require('sqmeow.core.paths').connections())
      config.apply({})
      vim.b.sqmeow_connection = nil
    end,
  },
})

T['completes subcommand names, sorted'] = function()
  eq(complete('Sqmeow ex'), { 'execute', 'export' })

  local all = complete('Sqmeow ')
  local sorted = vim.deepcopy(all)
  table.sort(sorted)
  eq(all, sorted)
  eq(#all, vim.tbl_count(require('sqmeow.commands').subcommands))
end

T['completes the arguments a subcommand takes, and nothing for one that takes none'] = function()
  eq(complete('Sqmeow export '), { 'csv', 'json', 'sql' })
  eq(complete('Sqmeow export j'), { 'json' })
  eq(complete('Sqmeow log '), { 'clear' })
  eq(complete('Sqmeow cancel '), {})
end

T['completes bind with none and the connections it could name'] = function()
  saved_ci()
  local offered = complete('Sqmeow bind ')
  eq(vim.tbl_contains(offered, 'none'), true)
  eq(vim.tbl_contains(offered, 'ci'), true)
  eq(complete('Sqmeow bind c'), { 'ci' })
end

T['with no subcommand, opens everything'] = function()
  local opened = false
  helpers.stub(require('sqmeow.api.view'), 'open_all', function()
    opened = true
  end)
  vim.cmd('Sqmeow')
  eq(opened, true)
end

T['an unknown subcommand is an error'] = function()
  vim.cmd('Sqmeow nope')
  eq(notes[1].level, vim.log.levels.ERROR)
end

T['execute runs the words it is given as one statement'] = function()
  local ran
  helpers.stub(require('sqmeow.api.query'), 'execute', function(sql)
    ran = sql
    return 1
  end)
  vim.cmd('Sqmeow execute select 1,  2')
  eq(ran, 'select 1, 2')
end

T['execute without words runs the buffer, or the lines a range covers'] = function()
  local called = {}
  helpers.stub(require('sqmeow.api.query'), 'execute_buffer', function()
    table.insert(called, 'buffer')
  end)
  helpers.stub(require('sqmeow.api.query'), 'execute_range', function(first, last)
    table.insert(called, { first, last })
  end)

  local buf = helpers.temp_buf({ 'select 1;', 'select 2;' })
  vim.api.nvim_set_current_buf(buf)

  vim.cmd('Sqmeow execute')
  vim.cmd('1,2Sqmeow execute')
  eq(called, { 'buffer', { 1, 2 } })
end

T['export writes a file, or copies with clipboard as the path'] = function()
  local seen = {}
  helpers.stub(require('sqmeow.api.export'), 'export', function(opts)
    table.insert(seen, opts)
  end)
  vim.cmd('Sqmeow export csv out.csv')
  vim.cmd('Sqmeow export json clipboard')
  eq(seen, { { format = 'csv', path = 'out.csv' }, { format = 'json', clipboard = true } })
end

T['save stores a name and url given, and needs a connection otherwise'] = function()
  local saved
  helpers.stub(require('sqmeow.api.connection'), 'save', function(name, url)
    saved = { name, url }
    return true
  end)
  helpers.stub(require('sqmeow.core.state'), 'current_connection', function()
    return nil
  end)

  vim.cmd('Sqmeow save ci sqlite://ci.db')
  eq(saved, { 'ci', 'sqlite://ci.db' })
  vim.cmd('Sqmeow save')
  eq(saved, { 'ci', 'sqlite://ci.db' })
end

T['bind ties a buffer to a connection it can find, and none unties it'] = function()
  saved_ci()
  helpers.stub(require('sqmeow.ui.editor'), 'update_winbar', function() end)

  vim.cmd('Sqmeow bind nowhere')
  eq(vim.b.sqmeow_connection, nil)
  vim.cmd('Sqmeow bind ci')
  eq(vim.b.sqmeow_connection, 'ci')
  vim.cmd('Sqmeow bind')
  vim.cmd('Sqmeow bind none')
  eq(vim.b.sqmeow_connection, nil)
end

T['log clear forgets the query log'] = function()
  local cleared = false
  helpers.stub(require('sqmeow.server.history'), 'clear', function()
    cleared = true
  end)
  helpers.stub(require('sqmeow.ui.drawer'), 'render', function() end)

  vim.cmd('Sqmeow log clear')
  eq(cleared, true)
end

T['a notice from connecting is shown as a warning'] = function()
  local state = require('sqmeow.core.state')
  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'quest', url = 'postgres://quest', state = 'connecting' })

  require('sqmeow.rpc.events').on_connection({
    id = id,
    state = 'connected',
    notice = 'no sessions',
  })

  eq(notes[1].level, vim.log.levels.WARN)
  state.remove_connection(id)
end

T['use activates an open connection'] = function()
  local state = require('sqmeow.core.state')
  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'first', url = 'sqlite://first.db', state = 'connected' })
  MiniTest.finally(function()
    state.remove_connection(id)
  end)

  vim.cmd('Sqmeow use first')
  eq(state.current, id)
end

T['use connects and activates a child connection of an open cluster'] = function()
  local state = require('sqmeow.core.state')
  local cluster_id = state.next_connection_id()
  state.add_connection({
    id = cluster_id,
    name = 'cluster',
    url = 'postgres://cluster/',
    state = 'connected',
  })
  local child_id = state.next_connection_id()

  helpers.stub(require('sqmeow.api.connection'), 'connect', function(url, opts)
    eq(url, 'postgres://cluster/')
    eq(opts.name, 'cluster/testdb')
    eq(opts.parent, cluster_id)
    eq(opts.database, 'testdb')
    state.add_connection({
      id = child_id,
      name = opts.name,
      parent = opts.parent,
      database = opts.database,
      url = url,
      state = 'connected',
    })
    return child_id
  end)

  MiniTest.finally(function()
    state.remove_connection(cluster_id)
    state.remove_connection(child_id)
  end)

  vim.cmd('Sqmeow use cluster/testdb')
  eq(state.current, child_id)
end

T['use reuses an existing child connection that is connecting'] = function()
  local state = require('sqmeow.core.state')
  local cluster_id = state.next_connection_id()
  state.add_connection({
    id = cluster_id,
    name = 'cluster',
    url = 'postgres://cluster/',
    state = 'connected',
  })
  local child_id = state.next_connection_id()
  state.add_connection({
    id = child_id,
    name = 'cluster/testdb',
    parent = cluster_id,
    database = 'testdb',
    url = 'postgres://cluster/',
    state = 'connecting',
  })

  local connected_called = false
  helpers.stub(require('sqmeow.api.connection'), 'connect', function()
    connected_called = true
  end)

  MiniTest.finally(function()
    state.remove_connection(cluster_id)
    state.remove_connection(child_id)
  end)

  vim.cmd('Sqmeow use cluster/testdb')
  eq(state.current, child_id)
  eq(connected_called, false)
end

T['use on cluster prompts for database and activates selection'] = function()
  local state = require('sqmeow.core.state')
  local cluster_id = state.next_connection_id()
  state.add_connection({
    id = cluster_id,
    name = 'cluster',
    url = 'postgres://cluster/',
    state = 'connected',
  })
  local child_id = state.next_connection_id()

  helpers.stub(require('sqmeow.api.connection'), 'databases', function(conn_id, cb)
    eq(conn_id, cluster_id)
    cb({ 'analytics', 'testdb' })
  end)

  local menu_opened = false
  helpers.stub(require('sqmeow.ui.form'), 'menu', function(opts)
    menu_opened = true
    eq(#opts.items, 2)
    eq(opts.items[1].value, 'analytics')
    eq(opts.items[2].value, 'testdb')
    opts.on_choice('testdb')
    return true
  end)

  helpers.stub(require('sqmeow.api.connection'), 'connect', function(url, opts)
    state.add_connection({
      id = child_id,
      name = opts.name,
      parent = opts.parent,
      database = opts.database,
      url = url,
      state = 'connected',
    })
    return child_id
  end)

  MiniTest.finally(function()
    state.remove_connection(cluster_id)
    state.remove_connection(child_id)
  end)

  vim.cmd('Sqmeow use cluster')
  eq(menu_opened, true)
  eq(state.current, child_id)
end

T['completes child databases when cluster has databases'] = function()
  local state = require('sqmeow.core.state')
  local cluster_id = state.next_connection_id()
  state.add_connection({
    id = cluster_id,
    name = 'cluster',
    url = 'postgres://cluster/',
    state = 'connected',
  })

  helpers.stub(require('sqmeow.ui.drawer'), 'databases', function(conn_id)
    if conn_id == cluster_id then
      return { 'analytics', 'testdb' }
    end
    return nil
  end)

  MiniTest.finally(function()
    state.remove_connection(cluster_id)
  end)

  local offered = complete('Sqmeow use cluster/')
  eq(vim.tbl_contains(offered, 'cluster/analytics'), true)
  eq(vim.tbl_contains(offered, 'cluster/testdb'), true)
end

return T
