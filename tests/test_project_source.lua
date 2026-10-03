local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local config = require('sqmeow.config')
local sources = require('sqmeow.sources')
local project = require('sqmeow.sources.project')
local root, cwd

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      cwd = vim.fn.getcwd()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, 'p')
      vim.api.nvim_set_current_dir(root)
      config.apply({ sources = { { type = 'project' } } })
    end,
    post_case = function()
      vim.api.nvim_set_current_dir(cwd)
      vim.fn.delete(root, 'rf')
      config.apply({})
    end,
  },
})

local function write(contents, directory)
  local path = vim.fs.joinpath(directory or root, '.sqmeow')
  vim.fn.mkdir(path, 'p')
  vim.fn.writefile(vim.split(contents, '\n'), vim.fs.joinpath(path, 'connections.toml'))
end

T['loads the issue example through the real TOML parser'] = function()
  write([[
[dev_db]
type = "postgres"
host = "localhost"
port = 5432
database = "my_app_dev"
user = "dev_user"

[staging_db]
type = "mysql"
host = "staging.example.com"
port = 3306
database = "my_app_staging"
]])
  local found, problems = sources.load()
  eq(problems, {})
  eq(found, {
    { name = 'dev_db', url = 'postgres://dev_user@localhost:5432/my_app_dev', source = 'project' },
    {
      name = 'staging_db',
      url = 'mysql://staging.example.com:3306/my_app_staging',
      source = 'project',
    },
  })
end

T['finds the nearest file and follows working directory changes'] = function()
  write('[outer]\ntype = "postgres"')
  local nested = vim.fs.joinpath(root, 'nested')
  local child = vim.fs.joinpath(nested, 'child')
  vim.fn.mkdir(child, 'p')
  vim.api.nvim_set_current_dir(child)
  eq(sources.load()[1].name, 'outer')
  write('[inner]\ntype = "mysql"', nested)
  eq(sources.load()[1].name, 'inner')
  vim.api.nvim_set_current_dir(root)
  eq(sources.load()[1].name, 'outer')
end

T['does not start the engine when no file exists'] = function()
  helpers.stub(require('sqmeow.rpc'), 'request', function()
    error('no RPC needed')
  end)
  local found, problems = sources.load()
  eq(found, {})
  eq(problems, {})
end

T['accepts an empty config'] = function()
  write('# No connections yet')
  local found, problems = sources.load()
  eq(found, {})
  eq(problems, {})
end

T['supports TOML strings, comments, booleans and escaped credentials'] = function()
  write([=[
["dev.db"] # a quoted name
type = 'postgres'
user = "a@b"
password = "p\"#@ss" # not part of the password
database = 'app'
read_only = true
ssh = 'user@bastion'
]=])
  local found, problems = sources.load()
  eq(problems, {})
  eq(found[1], {
    name = 'dev.db',
    url = 'postgres://a%40b:p%22%23%40ss@localhost/app',
    read_only = true,
    ssh = 'user@bastion',
    source = 'project',
  })
end

T['preserves password templates'] = function()
  write([=[
[dev]
type = 'postgres'
password = '{{ env "PGPASSWORD" }}'
]=])
  eq(sources.load()[1].url, 'postgres://:{{ env "PGPASSWORD" }}@localhost/')
end

T['resolves database files relative to the project'] = function()
  write('[dev]\ntype = "sqlite"\npath = "data.db"')
  local nested = vim.fs.joinpath(root, 'nested')
  vim.fn.mkdir(nested, 'p')
  vim.api.nvim_set_current_dir(nested)
  eq(sources.load()[1].url, 'sqlite:' .. vim.fs.joinpath(root, 'data.db'))
  write('[dev]\ntype = "sqlite"\npath = ":memory:"')
  eq(sources.load()[1].url, 'sqlite::memory:')
  local absolute = vim.fs.joinpath(root, 'absolute.db')
  write("[dev]\ntype = 'duckdb'\npath = '" .. absolute .. "'")
  eq(sources.load()[1].url, 'duckdb:' .. absolute)
end

T['normalizes TLS flags for the URL builder'] = function()
  write('[dev]\ntype = "clickhouse"\ntls = true')
  eq(sources.load()[1].url, 'clickhouses://localhost/')
end

T['reports invalid configs with the file path'] = MiniTest.new_set({
  parametrize = {
    { '[dev\ntype = "postgres"', 'invalid TOML' },
    { '[dev]\ntype = "postgres"\ntype = "mysql"', 'invalid TOML' },
    { 'dev = "postgres"', 'connection table' },
    { '[dev]\nhost = "localhost"', 'supported database' },
    { '[dev]\ntype = "unknown"', 'supported database' },
    { '[dev]\ntype = "postgres"\nport = 65536', 'port must be' },
    { '[dev]\ntype = "postgres"\nport = "5432"', 'port must be' },
    { '[dev]\ntype = "postgres"\nread_only = "true"', 'read_only must be' },
    { '[dev]\ntype = "postgres"\nhost = []', 'string, integer or boolean' },
    { '[dev]\ntype = "postgres"\nhost = false', 'host must be a string' },
    { '[dev]\ntype = "postgres"\npssword = "secret"', 'unknown field' },
  },
})
T['reports invalid configs with the file path']['rejects'] = function(contents, message)
  write(contents)
  local found, problems = sources.load()
  eq(found, {})
  eq(#problems, 1)
  helpers.contains(problems[1], assert(project.path()))
  helpers.contains(problems[1], message)
end

T['does not include password source lines in parse errors'] = function()
  write('[dev]\ntype = "postgres"\npassword = "private-secret" trailing')
  local _, problems = sources.load()
  eq(#problems, 1)
  eq(problems[1]:find('private-secret', 1, true), nil)
end

T['keeps other sources available after a project error'] = function()
  write('[broken')
  helpers.stub(vim.env, 'SQMEOW_CONNECTIONS', '[{"name":"env","url":"sqlite::memory:"}]')
  config.apply({ sources = { { type = 'project' }, { type = 'env' } } })
  local found, problems = sources.load()
  eq(found[1].name, 'env')
  eq(#problems, 1)
end

T['project is enabled first by default and cannot edit a shadowed saved connection'] = function()
  write('[dev]\ntype = "postgres"')
  eq(config.defaults.sources[1].type, 'project')
  local saved = vim.fs.joinpath(root, 'saved.json')
  local file = require('sqmeow.sources.file')
  file.save({ { name = 'dev', url = 'mysql://localhost/' } }, { path = saved })
  config.apply({ sources = { { type = 'project' }, { type = 'file', path = saved } } })
  local found, problems = sources.load()
  eq(#found, 1)
  eq(found[1].source, 'project')
  eq(#problems, 1)
  helpers.contains(problems[1], 'two connections')
  eq(sources.update('dev', { name = 'dev', url = 'sqlite::memory:' }), false)
  eq(sources.remove('dev'), false)
  eq(file.load({ path = saved })[1].url, 'mysql://localhost/')
end

return T
