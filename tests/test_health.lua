local MiniTest = require('mini.test')
-- `:checkhealth sqmeow`, read through what it reports rather than the buffer checkhealth draws.

local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local config = require('sqmeow.config')
local health = require('sqmeow.health')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')

--- Read connections from the environment, and nothing else.
local function use_env()
  config.apply({ sources = { { type = 'env' } } })
end

--- Run the check, and answer with each section's lines as `level: message`, keyed by section.
local function report()
  local sections, current = {}, nil
  for _, level in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
    helpers.stub(vim.health, level, function(message)
      if level == 'start' then
        current = message
        sections[current] = {}
      else
        table.insert(sections[current], level .. ': ' .. message)
      end
    end)
  end
  health.check()
  return sections
end

local function starts(line, prefix)
  return line ~= nil and vim.startswith(line, prefix)
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
      vim.env.SQMEOW_CONNECTIONS = nil
      rpc.stop()
      state.reset()
    end,
  },
})

T['reports the engine, its adapters, the configuration and nui.nvim'] = function()
  local sections = report()

  eq(sections.configuration[#sections.configuration], 'ok: configuration is valid')
  local engine = table.concat(sections.engine, '\n')
  helpers.contains(engine, 'ok: sqmeow-core')
  for _, dialect in ipairs({
    'sqlite',
    'duckdb',
    'postgres',
    'mysql',
    'redis',
    'mongodb',
    'scylla',
    'surrealdb',
    'clickhouse',
  }) do
    eq({ dialect, engine:find(dialect, 1, true) ~= nil }, { dialect, true })
  end
  eq(sections.dependencies[1], 'ok: nui.nvim is installed')
  -- Nothing is open, so there is no section for open connections.
  eq(sections['open connections'], nil)
end

T['flags a connection no adapter handles'] = function()
  vim.env.SQMEOW_CONNECTIONS = vim.json.encode({
    { name = 'fine', url = 'sqlite://fine.db' },
    { name = 'odd', url = 'oracle://host/space' },
  })
  use_env()

  local connections = report().connections
  eq(#connections, 2)
  eq(starts(connections[1], 'ok: fine  sqlite://fine.db'), true)
  eq(starts(connections[2], 'error: odd'), true)
  helpers.contains(connections[2], 'no adapter handles the `oracle` scheme')
end

T['warns about a source that cannot be read'] = function()
  vim.env.SQMEOW_CONNECTIONS = 'not json'
  use_env()

  local connections = report().connections
  eq(starts(connections[1], 'warn: SQMEOW_CONNECTIONS does not hold valid JSON'), true)
  eq(connections[2], 'info: no connections are configured; `:Sqmeow add` makes one')
end

T['knows the dialect of every scheme the engine accepts'] = function()
  -- The same aliases the engine reads a URL by, so the check never calls a working URL broken.
  local schemes = {
    sqlite = 'sqlite',
    sqlite3 = 'sqlite',
    file = 'sqlite',
    duckdb = 'duckdb',
    scylla = 'scylla',
    cassandra = 'scylla',
    clickhouse = 'clickhouse',
    clickhouses = 'clickhouse',
    postgres = 'postgres',
    postgresql = 'postgres',
    PostgreSQL = 'postgres',
    mysql = 'mysql',
    mariadb = 'mysql',
    redis = 'redis',
    rediss = 'redis',
    valkey = 'redis',
    valkeys = 'redis',
    mongodb = 'mongodb',
    ['mongodb+srv'] = 'mongodb',
    surrealdb = 'surrealdb',
    surrealdbs = 'surrealdb',
  }
  for scheme, dialect in pairs(schemes) do
    eq({ scheme, health.dialect_of(scheme) }, { scheme, dialect })
  end
  eq(health.dialect_of('oracle'), nil)
end

return T
