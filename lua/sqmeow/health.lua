--- `:checkhealth sqmeow`.
---
--- Answers the questions that come up when something is wrong: which engine is being used, is it
--- the version this plugin expects, and did the configuration parse.

local M = {}

local function check_neovim()
  vim.health.start('neovim')
  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok(('version %s'):format(vim.version()))
  else
    vim.health.error('sqmeow.nvim needs Neovim 0.10 or newer')
  end
end

local function check_config()
  vim.health.start('configuration')
  local errors = require('sqmeow.config').validate(require('sqmeow').user_config or {})
  local keymaps = require('sqmeow.keymap').problems()

  if #errors == 0 and #keymaps == 0 then
    vim.health.ok('configuration is valid')
    return
  end
  for _, err in ipairs(errors) do
    vim.health.error(err)
  end

  for _, problem in ipairs(require('sqmeow.keymap').problems()) do
    vim.health.error(problem)
  end
end

local function check_engine()
  vim.health.start('engine')

  local install = require('sqmeow.install')
  local rpc = require('sqmeow.rpc')
  local path, source = install.resolve()

  if not path then
    vim.health.error(
      'no engine binary found',
      { 'Run `:Sqmeow update` to download one', 'Or build one with `cargo build --release`' }
    )
    return
  end

  local version, err = install.version(path)
  if not version then
    vim.health.error(('%s is not a usable engine: %s'):format(path, err or 'unknown error'))
    return
  end
  vim.health.ok(('sqmeow-core %s (%s)\n%s'):format(version, source, path))

  local channel, start_err = rpc.start()
  if not channel then
    vim.health.error(start_err or 'the engine would not start')
    return
  end

  local info = rpc.info()
  vim.health.ok(('running on channel %d, pid %d'):format(channel, info.pid))
  vim.health.ok(('protocol %d'):format(info.protocol_version))

  if #info.adapters == 0 then
    vim.health.info('no database adapters are compiled in yet')
  else
    vim.health.ok('adapters: ' .. table.concat(info.adapters, ', '))
  end
end

local function check_sources()
  vim.health.start('connections')

  local connections, problems = require('sqmeow.sources').load()
  for _, problem in ipairs(problems) do
    vim.health.warn(problem)
  end

  if #connections == 0 then
    vim.health.info('no connections are configured; `:Sqmeow connect <url>` works without any')
    return
  end

  local adapters = require('sqmeow.rpc').info()
  adapters = adapters and adapters.adapters or {}

  local url = require('sqmeow.url')
  for _, connection in ipairs(connections) do
    local scheme = connection.url:match('^(%w[%w%+%-%.]*)') or ''
    local dialect = M.dialect_of(scheme)
    local shown = ('%s  %s  (%s)'):format(
      connection.name,
      url.display(connection.url),
      connection.source
    )

    if not dialect then
      vim.health.error(shown .. '\nno adapter handles the `' .. scheme .. '` scheme')
    elseif #adapters > 0 and not vim.tbl_contains(adapters, dialect) then
      vim.health.error(shown .. '\nthis engine was not built with the ' .. dialect .. ' adapter')
    else
      vim.health.ok(shown)
    end
  end
end

local function check_open()
  local state = require('sqmeow.state')
  local open = state.connection_list()
  if #open == 0 then
    return
  end

  vim.health.start('open connections')
  for _, connection in ipairs(open) do
    local label = ('%d  %s (%s)'):format(connection.id, connection.name, connection.dialect or '?')
    if connection.state == 'connected' then
      vim.health.ok(label)
    else
      vim.health.warn(label .. ': ' .. connection.state)
    end
  end
end

--- Which dialect a URL scheme belongs to, or nil if none does.
---
--- Mirrors what the engine accepts. Kept here so the health check can answer offline, before the
--- engine has been started.
---@param scheme string
---@return string|nil
function M.dialect_of(scheme)
  local dialects = {
    sqlite = 'sqlite',
    sqlite3 = 'sqlite',
    file = 'sqlite',
    postgres = 'postgres',
    postgresql = 'postgres',
    mysql = 'mysql',
    mariadb = 'mysql',
  }
  return dialects[scheme:lower()]
end

--- Entry point for `:checkhealth sqmeow`.
function M.check()
  check_neovim()
  check_config()
  check_engine()
  check_sources()
  check_open()
end

return M
