local MiniTest = require('mini.test')
-- `:Sqmeow`: which subcommand a line reaches, what completion offers, and what each says when there
-- is nothing to act on. The work itself is the api's, and is stubbed where a case only routes to it.

local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = require('sqmeow.api')
local config = require('sqmeow.config')

local notes = {}
local original_notify

--- What the cases have told the user so far, in order.
local function messages()
  return vim.tbl_map(function(note)
    return note.message
  end, notes)
end

local function complete(line)
  return vim.fn.getcompletion(line, 'cmdline')
end

--- Configure one saved connection, named `ci`, and nothing else.
local function saved_ci()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'ci', url = 'sqlite://ci.db' } })
  config.apply({ sources = { { type = 'env' } } })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      notes = {}
      original_notify = helpers.swap(vim, 'notify', function(message, level)
        table.insert(notes, { message = message, level = level or vim.log.levels.INFO })
      end)
    end,
    post_case = function()
      vim.notify = original_notify
      config.apply({})
      vim.env.SQMEOW_CONNECTIONS = nil
      vim.b.sqmeow_connection = nil
    end,
  },
})

T['every subcommand is described and runnable'] = function()
  for name, subcommand in pairs(require('sqmeow.commands').subcommands) do
    eq({ name, type(subcommand.desc), type(subcommand.run) }, { name, 'string', 'function' })
  end
end

T['completes subcommand names, sorted'] = function()
  eq(complete('Sqmeow ex'), { 'execute', 'export' })

  local all = complete('Sqmeow ')
  local sorted = vim.deepcopy(all)
  table.sort(sorted)
  eq(all, sorted)
  eq(#all, vim.tbl_count(require('sqmeow.commands').subcommands))
end

T['completes the arguments a subcommand takes, and nothing for one that takes none'] = function()
  eq(complete('Sqmeow export '), { 'csv', 'json' })
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
  helpers.stub(api, 'open_all', function()
    opened = true
  end)
  vim.cmd('Sqmeow')
  eq(opened, true)
end

T['an unknown subcommand is an error'] = function()
  vim.cmd('Sqmeow nope')
  eq(notes[1], { message = 'sqmeow: unknown subcommand `nope`', level = vim.log.levels.ERROR })
end

T['execute runs the words it is given as one statement'] = function()
  local ran
  helpers.stub(api, 'execute', function(sql)
    ran = sql
    return 1
  end)
  vim.cmd('Sqmeow execute select 1,  2')
  eq(ran, 'select 1, 2')
end

T['execute without words runs the buffer, or the lines a range covers'] = function()
  local called = {}
  helpers.stub(api, 'execute_buffer', function()
    table.insert(called, 'buffer')
  end)
  helpers.stub(api, 'execute_selection', function()
    table.insert(called, 'selection')
  end)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  MiniTest.finally(function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'select 1;', 'select 2;' })

  vim.cmd('Sqmeow execute')
  vim.cmd('1,2Sqmeow execute')
  eq(called, { 'buffer', 'selection' })
end

T['export writes a file, or copies with clipboard as the path'] = function()
  local seen = {}
  helpers.stub(api, 'export', function(opts)
    table.insert(seen, opts)
  end)
  vim.cmd('Sqmeow export csv out.csv')
  vim.cmd('Sqmeow export json clipboard')
  eq(seen, { { format = 'csv', path = 'out.csv' }, { format = 'json', clipboard = true } })
end

T['save stores a name and url given, and needs a connection otherwise'] = function()
  local saved
  helpers.stub(api, 'save', function(name, url)
    saved = { name, url }
    return true
  end)
  helpers.stub(require('sqmeow.state'), 'current_connection', function()
    return nil
  end)

  vim.cmd('Sqmeow save ci sqlite://ci.db')
  eq(saved, { 'ci', 'sqlite://ci.db' })
  vim.cmd('Sqmeow save')
  eq(messages(), { 'sqmeow: connect first, or pass a name and a url' })
end

T['says when there is nothing to act on'] = function()
  helpers.stub(api, 'cancel', function()
    return false
  end)
  helpers.stub(api, 'connections', function()
    return {}
  end)
  helpers.stub(require('sqmeow.rpc'), 'messages', function()
    return {}
  end)

  vim.cmd('Sqmeow cancel')
  vim.cmd('Sqmeow use nowhere')
  vim.cmd('Sqmeow use')
  vim.cmd('Sqmeow messages')
  eq(messages(), {
    'sqmeow: there is no query running',
    'sqmeow: nothing open is called `nowhere`',
    'sqmeow: nothing is connected',
    'sqmeow: the engine log is empty',
  })
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

  eq(messages(), {
    'sqmeow: there is no connection called `nowhere`',
    'sqmeow: this buffer runs on ci',
    'sqmeow: this buffer runs on ci',
    'sqmeow: this buffer follows the active connection again',
  })
end

T['log clear forgets the query log'] = function()
  local cleared = false
  helpers.stub(require('sqmeow.history'), 'clear', function()
    cleared = true
  end)
  helpers.stub(require('sqmeow.ui.drawer'), 'render', function() end)

  vim.cmd('Sqmeow log clear')
  eq(cleared, true)
  eq(messages(), { 'sqmeow: the query log is empty' })
end

return T
