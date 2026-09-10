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
  if #errors == 0 then
    vim.health.ok('configuration is valid')
    return
  end
  for _, err in ipairs(errors) do
    vim.health.error(err)
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

--- Entry point for `:checkhealth sqmeow`.
function M.check()
  check_neovim()
  check_config()
  check_engine()
end

return M
