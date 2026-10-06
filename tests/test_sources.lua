local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local sources = require('sqmeow.sources')
local file = require('sqmeow.sources.file')
local config = require('sqmeow.config')
local state = require('sqmeow.core.state')

local scratch = vim.fs.joinpath(vim.fn.tempname(), 'connections.json')
local project_load

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.apply({ core = { path = vim.fs.dirname(scratch) } })
      project_load = helpers.swap(sources.builtin.project, 'load', function()
        return {}
      end)
    end,
    post_case = function()
      helpers.swap(sources.builtin.project, 'load', project_load)
      config.apply({})
      pcall(vim.fn.delete, scratch)
      state.reset()
    end,
  },
})

--- Keep writes under the test's data directory.
local function only_file()
  config.apply({ core = { path = vim.fs.dirname(scratch) } })
end

--- Save a connection to the scratch file.
local function save(name, url)
  return file.add({ name = name, url = url }, { path = scratch })
end

T['file'] = MiniTest.new_set()

T['file']['is empty when the file is not there'] = function()
  only_file()
  eq(sources.load(), {})
end

T['file']['round-trips what it saved'] = function()
  only_file()

  eq(save('prod', 'postgres://host/prod'), true)
  local found = sources.load()

  eq(#found, 1)
  eq(found[1].name, 'prod')
  eq(found[1].url, 'postgres://host/prod')
  eq(found[1].source, 'file')
end

T['file']['replaces a connection of the same name'] = function()
  save('prod', 'postgres://old/prod')
  save('prod', 'postgres://new/prod')
  only_file()

  local found = sources.load()
  eq(#found, 1)
  eq(found[1].url, 'postgres://new/prod')
end

T['file']['keeps other connections when adding one'] = function()
  save('a', 'sqlite://a.db')
  save('b', 'sqlite://b.db')
  only_file()

  eq(#sources.load(), 2)
end

T['file']['does not write back the source label it read'] = function()
  save('a', 'sqlite://a.db')
  local written = vim.json.decode(table.concat(vim.fn.readfile(scratch), '\n'))
  eq(written[1].source, nil)
end

T['file']['edits one connection in place'] = function()
  save('a', 'sqlite://a.db')
  save('b', 'sqlite://b.db')

  eq(file.update('a', { name = 'first', url = 'sqlite://first.db' }, { path = scratch }), true)
  only_file()

  local found = sources.load()
  -- Renamed where it stood, rather than removed and appended, so the list keeps its order.
  eq(found[1].name, 'first')
  eq(found[1].url, 'sqlite://first.db')
  eq(found[2].name, 'b')
end

T['file']['refuses to edit one that is not there'] = function()
  save('a', 'sqlite://a.db')

  local written, err = file.update('nope', { name = 'x', url = 'sqlite://x.db' }, {
    path = scratch,
  })
  eq(written, false)
  helpers.contains(assert(err, 'there should be an error'), 'nope')
end

T['file']['deletes one connection, keeping the rest'] = function()
  save('a', 'sqlite://a.db')
  save('b', 'sqlite://b.db')

  eq(file.remove('a', { path = scratch }), true)
  only_file()

  local found = sources.load()
  eq(#found, 1)
  eq(found[1].name, 'b')
end

T['file']['refuses to delete one that is not there'] = function()
  save('a', 'sqlite://a.db')

  local written, err = file.remove('nope', { path = scratch })
  eq(written, false)
  helpers.contains(assert(err, 'there should be an error'), 'nope')

  only_file()
  eq(#sources.load(), 1)
end

T['file']['refuses a rename onto a name already taken'] = function()
  save('a', 'sqlite://a.db')
  save('b', 'sqlite://b.db')

  -- Two rows under one name is a list the loader cannot tell apart.
  local written, err = file.update('a', { name = 'b', url = 'sqlite://a.db' }, { path = scratch })
  eq(written, false)
  helpers.contains(assert(err, 'there should be an error'), 'already')

  only_file()
  eq(#sources.load(), 2)
end

T['file']['reports malformed json'] = function()
  helpers.writefile(scratch, { 'not json' })
  only_file()

  local found, problems = sources.load()
  eq(found, {})
  eq(#problems, 1)
end

T['editing'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
    end,
  },
})

T['editing']['changes the saved connection'] = function()
  save('app', 'sqlite://app.db')
  only_file()

  eq(require('sqmeow.api.connection').edit('app', { name = 'production' }), true)

  local found = sources.load()
  eq(found[1].name, 'production')
  -- Only what was named changed. A url left out of the table is the url it already had.
  eq(found[1].url, 'sqlite://app.db')
end

T['editing']['renames an open connection along with the saved one'] = function()
  save('app', 'sqlite://app.db')
  only_file()

  local id = state.next_connection_id()
  state.add_connection({
    id = id,
    name = 'app',
    url = 'sqlite://app.db',
    dialect = 'sqlite',
    state = 'connected',
  })

  require('sqmeow.api.connection').edit('app', { name = 'production' })
  eq(state.connections[id].name, 'production')
end

T['editing']['refuses a connection no source declares'] = function()
  only_file()
  eq(require('sqmeow.api.connection').edit('nope', { name = 'x' }), false)
end

T['editing']['renames an open connection on its own'] = function()
  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'scratch', url = 'sqlite::memory:', state = 'connected' })

  eq(require('sqmeow.api.connection').rename(id, 'notes'), true)
  eq(state.connections[id].name, 'notes')
  -- An empty name would leave a row with nothing on it.
  eq(require('sqmeow.api.connection').rename(id, ''), false)
  eq(require('sqmeow.api.connection').rename(id + 99, 'nowhere'), false)
end

T['removing'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      state.reset()
    end,
  },
})

T['removing']['forgets the saved connection and closes it while it is open'] = function()
  save('app', 'sqlite://app.db')
  only_file()

  local id = state.next_connection_id()
  state.add_connection({
    id = id,
    name = 'app',
    url = 'sqlite://app.db',
    dialect = 'sqlite',
    state = 'connected',
  })
  helpers.stub(require('sqmeow.rpc.client'), 'request', function()
    return true
  end)

  eq(require('sqmeow.api.connection').remove('app'), true)
  eq(sources.find('app'), nil)
  eq(state.connections[id], nil)
end

T['removing']['forgets a saved connection that was never opened'] = function()
  save('app', 'sqlite://app.db')
  only_file()

  eq(require('sqmeow.api.connection').remove('app'), true)
  eq(sources.load(), {})
end

T['removing']['closes a connection that was never saved'] = function()
  only_file()

  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'scratch', url = 'sqlite::memory:', state = 'connected' })
  helpers.stub(require('sqmeow.rpc.client'), 'request', function()
    return true
  end)

  eq(require('sqmeow.api.connection').remove('scratch'), true)
  eq(state.connections[id], nil)
end

T['removing']['only closes a connection from another source'] = function()
  helpers.stub(sources.builtin.project, 'load', function()
    return { { name = 'ci', url = 'sqlite://ci.db' } }
  end)

  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'ci', url = 'sqlite://ci.db', state = 'connected' })
  helpers.stub(require('sqmeow.rpc.client'), 'request', function()
    return true
  end)

  -- The open connection is closed, but the entry it came from stays.
  eq(require('sqmeow.api.connection').remove('ci'), true)
  eq(state.connections[id], nil)
  eq(sources.find('ci').url, 'sqlite://ci.db')
end

T['removing']['refuses a connection from another source that is not open'] = function()
  helpers.stub(sources.builtin.project, 'load', function()
    return { { name = 'ci', url = 'sqlite://ci.db' } }
  end)

  eq(require('sqmeow.api.connection').remove('ci'), false)
  eq(sources.find('ci').url, 'sqlite://ci.db')
end

T['removing']['refuses a connection nothing declares'] = function()
  only_file()
  eq(require('sqmeow.api.connection').remove('nope'), false)
end

T['combining'] = MiniTest.new_set()

T['combining']['reads every source in order'] = function()
  helpers.stub(sources.builtin.project, 'load', function()
    return { { name = 'from-project', url = 'sqlite://p.db' } }
  end)
  save('from-file', 'sqlite://f.db')

  local found = sources.load()
  eq(#found, 2)
  eq(found[1].source, 'project')
  eq(found[2].source, 'file')
end

T['combining']['reports a duplicate name instead of hiding it'] = function()
  helpers.stub(sources.builtin.project, 'load', function()
    return { { name = 'dev', url = 'sqlite://p.db' } }
  end)
  save('dev', 'sqlite://f.db')

  local found, problems = sources.load()
  -- The first one still works, and the collision is surfaced rather than silently resolved.
  eq(#found, 1)
  eq(found[1].url, 'sqlite://p.db')
  eq(#problems, 1)
  helpers.contains(problems[1], 'dev')
end

T['combining']['reports an entry missing a url'] = function()
  helpers.writefile(scratch, { '[{"name":"broken"}]' })

  local found, problems = sources.load()
  eq(found, {})
  eq(#problems, 1)
end

T['combining']['finds one connection by name'] = function()
  save('dev', 'sqlite://dev.db')
  only_file()

  eq(sources.find('dev').url, 'sqlite://dev.db')
  eq(sources.find('nope'), nil)
end

T['connecting'] = MiniTest.new_set()

T['connecting']['reuses an open connection of the same name'] = function()
  save('dev', 'sqlite://dev.db')
  only_file()

  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'dev', url = 'sqlite://dev.db', state = 'connected' })

  local connect_called = false
  helpers.stub(require('sqmeow.api.connection'), 'connect', function()
    connect_called = true
  end)

  local returned_id = require('sqmeow.api.connection').connect_named('dev')
  eq(returned_id, id)
  eq(state.current, id)
  eq(connect_called, false)
end

T['connecting']['opens a new connection when not already open'] = function()
  save('dev', 'sqlite://dev.db')
  only_file()

  local connected
  helpers.stub(require('sqmeow.api.connection'), 'connect', function(url, opts)
    connected = { url = url, name = opts.name }
    return 42
  end)

  local returned_id = require('sqmeow.api.connection').connect_named('dev')
  eq(returned_id, 42)
  eq(connected, { url = 'sqlite://dev.db', name = 'dev' })
end

T['connecting']['refuses changed connection settings'] = MiniTest.new_set({
  parametrize = {
    { { url = 'sqlite://other.db' } },
    { { read_only = true } },
    { { ssh = 'bastion' } },
  },
})
T['connecting']['refuses changed connection settings']['until closed'] = function(changes)
  only_file()
  file.save(
    { vim.tbl_extend('force', { name = 'dev', url = 'sqlite://dev.db' }, changes) },
    { path = scratch }
  )
  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'dev', url = 'sqlite://dev.db', state = 'connected' })
  local returned, err = require('sqmeow.api.connection').connect_named('dev')
  eq(returned, nil)
  helpers.contains(err, 'close it before reconnecting')
end

return T
