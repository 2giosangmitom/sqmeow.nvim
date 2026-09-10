local eq = MiniTest.expect.equality
local sources = require('sqmeow.sources')
local file = require('sqmeow.sources.file')
local config = require('sqmeow.config')

local scratch = vim.fs.joinpath(vim.fn.tempname(), 'connections.json')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
      vim.env.SQMEOW_CONNECTIONS = nil
      vim.g.dbs = nil
      pcall(vim.fn.delete, scratch)
    end,
  },
})

--- Configure sources without any of the defaults, so a case sees only what it declares.
local function only(...)
  config.apply({ sources = { ... } })
end

T['memory'] = MiniTest.new_set()

T['memory']['reads connections from setup'] = function()
  config.apply({
    sources = {},
    connections = { { name = 'dev', url = 'sqlite://dev.db' } },
  })

  local found = sources.load()
  eq(#found, 1)
  eq(found[1].name, 'dev')
  eq(found[1].source, 'memory')
end

T['memory']['needs no source entry of its own'] = function()
  config.apply({
    sources = { { type = 'file', path = scratch } },
    connections = {
      { name = 'inline', url = 'sqlite://x.db' },
    },
  })

  eq(sources.load()[1].name, 'inline')
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
  eq(problems[1]:find('SQMEOW_CONNECTIONS', 1, true) ~= nil, true)
end

T['file'] = MiniTest.new_set()

T['file']['is empty when the file is not there'] = function()
  only({ type = 'file', path = scratch })
  eq(sources.load(), {})
end

T['file']['round-trips what it saved'] = function()
  only({ type = 'file', path = scratch })

  eq(file.add({ name = 'prod', url = 'postgres://host/prod' }, { path = scratch }), true)
  local found = sources.load()

  eq(#found, 1)
  eq(found[1].name, 'prod')
  eq(found[1].url, 'postgres://host/prod')
  eq(found[1].source, 'file')
end

T['file']['replaces a connection of the same name'] = function()
  file.add({ name = 'prod', url = 'postgres://old/prod' }, { path = scratch })
  file.add({ name = 'prod', url = 'postgres://new/prod' }, { path = scratch })
  only({ type = 'file', path = scratch })

  local found = sources.load()
  eq(#found, 1)
  eq(found[1].url, 'postgres://new/prod')
end

T['file']['keeps other connections when adding one'] = function()
  file.add({ name = 'a', url = 'sqlite://a.db' }, { path = scratch })
  file.add({ name = 'b', url = 'sqlite://b.db' }, { path = scratch })
  only({ type = 'file', path = scratch })

  eq(#sources.load(), 2)
end

T['file']['does not write back the source label it read'] = function()
  file.add({ name = 'a', url = 'sqlite://a.db' }, { path = scratch })
  local written = vim.json.decode(table.concat(vim.fn.readfile(scratch), '\n'))
  eq(written[1].source, nil)
end

T['file']['reports malformed json'] = function()
  vim.fn.mkdir(vim.fs.dirname(scratch), 'p')
  vim.fn.writefile({ 'not json' }, scratch)
  only({ type = 'file', path = scratch })

  local found, problems = sources.load()
  eq(found, {})
  eq(#problems, 1)
end

T['dadbod'] = MiniTest.new_set()

T['dadbod']['reads a table of names to urls'] = function()
  vim.g.dbs = { dev = 'sqlite://dev.db', prod = 'postgres://host/prod' }
  only({ type = 'dadbod' })

  local found = sources.load()
  eq(#found, 2)
  -- A table has no order, so the source sorts it into one.
  eq(found[1].name, 'dev')
  eq(found[2].name, 'prod')
end

T['dadbod']['reads a list of name and url pairs'] = function()
  vim.g.dbs = { { name = 'dev', url = 'sqlite://dev.db' } }
  only({ type = 'dadbod' })

  eq(sources.load()[1].name, 'dev')
end

T['dadbod']['is empty when g:dbs is unset'] = function()
  only({ type = 'dadbod' })
  eq(sources.load(), {})
end

T['combining'] = MiniTest.new_set()

T['combining']['reads every source in order'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'from-env', url = 'sqlite://e.db' } })
  vim.g.dbs = { ['from-dadbod'] = 'sqlite://d.db' }
  only({ type = 'env' }, { type = 'dadbod' })

  local found = sources.load()
  eq(#found, 2)
  eq(found[1].source, 'env')
  eq(found[2].source, 'dadbod')
end

T['combining']['reports a duplicate name instead of hiding it'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'dev', url = 'sqlite://e.db' } })
  vim.g.dbs = { dev = 'sqlite://d.db' }
  only({ type = 'env' }, { type = 'dadbod' })

  local found, problems = sources.load()
  -- The first one still works, and the collision is surfaced rather than silently resolved.
  eq(#found, 1)
  eq(found[1].url, 'sqlite://e.db')
  eq(#problems, 1)
  eq(problems[1]:find('dev', 1, true) ~= nil, true)
end

T['combining']['reports an unknown source type'] = function()
  only({ type = 'nowhere' })

  local _, problems = sources.load()
  eq(#problems, 1)
  eq(problems[1]:find('nowhere', 1, true) ~= nil, true)
end

T['combining']['reports an entry missing a url'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({ { name = 'broken' } })
  only({ type = 'env' })

  local found, problems = sources.load()
  eq(found, {})
  eq(#problems, 1)
end

T['combining']['finds one connection by name'] = function()
  vim.g.dbs = { dev = 'sqlite://dev.db' }
  only({ type = 'dadbod' })

  eq(sources.find('dev').url, 'sqlite://dev.db')
  eq(sources.find('nope'), nil)
end

return T
