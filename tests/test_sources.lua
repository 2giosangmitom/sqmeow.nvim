local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local sources = require('sqmeow.sources')
local file = require('sqmeow.sources.file')
local config = require('sqmeow.config')
local state = require('sqmeow.state')
local api = require('sqmeow.api')

local scratch = vim.fs.joinpath(vim.fn.tempname(), 'connections.json')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
      vim.env.SQMEOW_CONNECTIONS = nil
      pcall(vim.fn.delete, scratch)
    end,
  },
})

--- Configure sources without any of the defaults, so a case sees only what it declares.
local function only(...)
  config.apply({ sources = { ... } })
end

--- Read only the scratch file, and nothing else.
local function only_file()
  only({ type = 'file', path = scratch })
end

--- Save a connection to the scratch file.
local function save(name, url)
  return file.add({ name = name, url = url }, { path = scratch })
end

T['env'] = MiniTest.new_set()

T['env']['reads a json array'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'ci', url = 'sqlite://ci.db' } })
  only({ type = 'env' })

  local found = sources.load()
  eq(#found, 1)
  eq(found[1].name, 'ci')
  eq(found[1].source, 'env')
end

T['env']['reads the variable a source names'] = function()
  vim.env.SQMEOW_OTHER = vim.json.encode({ { name = 'other', url = 'sqlite://o.db' } })
  only({ type = 'env', var = 'SQMEOW_OTHER' })

  eq(sources.load()[1].name, 'other')
  vim.env.SQMEOW_OTHER = nil
end

T['env']['is empty when the variable is unset'] = function()
  only({ type = 'env' })
  eq(sources.load(), {})
end

T['env']['reports malformed json'] = function()
  vim.env.SQMEOW_CONNECTIONS = 'not json'
  only({ type = 'env' })

  local found, problems = sources.load()
  eq(found, {})
  eq(#problems, 1)
  helpers.contains(problems[1], 'SQMEOW_CONNECTIONS')
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

  eq(api.edit('app', { name = 'production' }), true)

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

  api.edit('app', { name = 'production' })
  eq(state.connections[id].name, 'production')
end

T['editing']['refuses a connection no source declares'] = function()
  only_file()
  eq(api.edit('nope', { name = 'x' }), false)
end

T['editing']['renames an open connection on its own'] = function()
  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'scratch', url = 'sqlite::memory:', state = 'connected' })

  eq(api.rename(id, 'notes'), true)
  eq(state.connections[id].name, 'notes')
  -- An empty name would leave a row with nothing on it.
  eq(api.rename(id, ''), false)
  eq(api.rename(id + 99, 'nowhere'), false)
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
  helpers.stub(require('sqmeow.rpc'), 'request', function()
    return true
  end)

  eq(api.remove('app'), true)
  eq(sources.find('app'), nil)
  eq(state.connections[id], nil)
end

T['removing']['forgets a saved connection that was never opened'] = function()
  save('app', 'sqlite://app.db')
  only_file()

  eq(api.remove('app'), true)
  eq(sources.load(), {})
end

T['removing']['closes a connection that was never saved'] = function()
  only_file()

  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'scratch', url = 'sqlite::memory:', state = 'connected' })
  helpers.stub(require('sqmeow.rpc'), 'request', function()
    return true
  end)

  eq(api.remove('scratch'), true)
  eq(state.connections[id], nil)
end

T['removing']['only closes a connection from another source'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'ci', url = 'sqlite://ci.db' } })
  only({ type = 'env' })

  local id = state.next_connection_id()
  state.add_connection({ id = id, name = 'ci', url = 'sqlite://ci.db', state = 'connected' })
  helpers.stub(require('sqmeow.rpc'), 'request', function()
    return true
  end)

  -- The open connection is closed, but the entry it came from stays.
  eq(api.remove('ci'), true)
  eq(state.connections[id], nil)
  eq(sources.find('ci').url, 'sqlite://ci.db')
end

T['removing']['refuses a connection from another source that is not open'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'ci', url = 'sqlite://ci.db' } })
  only({ type = 'env' })

  eq(api.remove('ci'), false)
  eq(sources.find('ci').url, 'sqlite://ci.db')
end

T['removing']['refuses a connection nothing declares'] = function()
  only_file()
  eq(api.remove('nope'), false)
end

T['combining'] = MiniTest.new_set()

T['combining']['reads every source in order'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'from-env', url = 'sqlite://e.db' } })
  save('from-file', 'sqlite://f.db')
  only({ type = 'env' }, { type = 'file', path = scratch })

  local found = sources.load()
  eq(#found, 2)
  eq(found[1].source, 'env')
  eq(found[2].source, 'file')
end

T['combining']['reports a duplicate name instead of hiding it'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'dev', url = 'sqlite://e.db' } })
  save('dev', 'sqlite://f.db')
  only({ type = 'env' }, { type = 'file', path = scratch })

  local found, problems = sources.load()
  -- The first one still works, and the collision is surfaced rather than silently resolved.
  eq(#found, 1)
  eq(found[1].url, 'sqlite://e.db')
  eq(#problems, 1)
  helpers.contains(problems[1], 'dev')
end

T['combining']['reports an unknown source type'] = function()
  only({ type = 'nowhere' })

  local _, problems = sources.load()
  eq(#problems, 1)
  helpers.contains(problems[1], 'nowhere')
end

T['combining']['reports an entry missing a url'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'broken' } })
  only({ type = 'env' })

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

T['a command source reads what the command prints, in the background'] = function()
  local command = require('sqmeow.sources.command')
  command.reload()
  local source =
    { type = 'command', command = { 'printf', '[{"name": "vault", "url": "sqlite::memory:"}]' } }

  local first = command.load(source)
  eq(first, {})
  local found
  vim.wait(5000, function()
    found = command.load(source)
    return #found > 0
  end, 20)
  eq(found[1].name, 'vault')

  local failing = { type = 'command', command = 'echo nope >&2; exit 3' }
  local _, err
  vim.wait(5000, function()
    _, err = command.load(failing)
    return err ~= nil
  end, 20)
  eq(err:find('nope', 1, true) ~= nil, true)
end

return T
