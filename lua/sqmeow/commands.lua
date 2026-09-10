--- The `:Sqmeow` command.
---
--- One command with subcommands, rather than a command per action. It keeps one name in the
--- user's command space and gives completion a single place to live.

local M = {}

--- Subcommands, each a description and what to run.
---@type table<string, { desc: string, run: fun() }>
M.subcommands = {
  health = {
    desc = 'Run the health check',
    run = function()
      vim.cmd.checkhealth('sqmeow')
    end,
  },

  start = {
    desc = 'Start the engine',
    run = function()
      local channel, err = require('sqmeow.rpc').start()
      if not channel then
        vim.notify('sqmeow: ' .. err, vim.log.levels.ERROR)
        return
      end
      local info = require('sqmeow.rpc').info()
      vim.notify(('sqmeow: engine %s running (pid %d)'):format(info.core_version, info.pid))
    end,
  },

  stop = {
    desc = 'Stop the engine',
    run = function()
      require('sqmeow.rpc').stop()
      vim.notify('sqmeow: engine stopped')
    end,
  },

  log = {
    desc = 'Show the engine log',
    run = function()
      local lines = require('sqmeow.rpc').messages()
      if #lines == 0 then
        vim.notify('sqmeow: the engine log is empty')
        return
      end
      vim.notify(table.concat(lines, '\n'))
    end,
  },

  restart = {
    desc = 'Restart the engine',
    run = function()
      local channel, err = require('sqmeow.rpc').restart()
      vim.notify(
        channel and 'sqmeow: engine restarted' or ('sqmeow: ' .. err),
        channel and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end,
  },
}

local function run(opts)
  local name = opts.fargs[1]
  if not name then
    vim.cmd.checkhealth('sqmeow')
    return
  end

  local subcommand = M.subcommands[name]
  if not subcommand then
    vim.notify(('sqmeow: unknown subcommand `%s`'):format(name), vim.log.levels.ERROR)
    return
  end

  subcommand.run()
end

local function complete(lead, line)
  -- Only the first argument completes, so a subcommand's own arguments are not offered a
  -- subcommand list.
  if line:match('^%s*Sqmeow%s+%S+%s') then
    return {}
  end

  return vim.tbl_filter(function(name)
    return name:find(lead, 1, true) == 1
  end, vim.tbl_keys(M.subcommands))
end

--- Register `:Sqmeow`.
function M.register()
  vim.api.nvim_create_user_command('Sqmeow', run, {
    nargs = '*',
    desc = 'sqmeow.nvim',
    complete = complete,
  })
end

return M
