-- Subcommands for one domain; required directly by sqmeow.commands.
-- No re-export.

local M = {}

local notify = require('sqmeow.core.utils').notify

M.subcommands = {
  install = {
    desc = 'Install the engine this plugin needs, by download or with cargo',
    complete = function(lead)
      return vim.tbl_filter(function(method)
        return method:find(lead, 1, true) == 1
      end, require('sqmeow.server.install').methods)
    end,
    run = function(args)
      local method = args[1]
      require('sqmeow.server.install').install({
        method = method ~= '' and method or nil,
        version = args[2],
        callback = function(path)
          if not path then
            return
          end

          -- Stop the running engine before using the newly installed binary.
          require('sqmeow.rpc.client').stop()
          require('sqmeow.core.state').reset()
          require('sqmeow.ui.drawer').reset()
        end,
      })
    end,
  },
  health = {
    desc = 'Run the health check',
    run = function()
      vim.cmd.checkhealth('sqmeow')
    end,
  },
  messages = {
    desc = 'Show what the engine has been saying',
    run = function()
      local lines = require('sqmeow.rpc.client').messages()
      if #lines == 0 then
        return notify('the engine log is empty')
      end
      notify(table.concat(lines, '\n'))
    end,
  },
  start = {
    desc = 'Start the engine',
    run = function()
      local rpc = require('sqmeow.rpc.client')
      local channel, err = rpc.start()
      if not channel then
        return notify(err or 'the engine could not be started', vim.log.levels.ERROR)
      end
      local info = assert(rpc.info(), 'a started engine has answered its handshake')
      notify(('engine %s running (pid %d)'):format(info.core_version, info.pid))
    end,
  },
  stop = {
    desc = 'Stop the engine',
    run = function()
      require('sqmeow.rpc.client').stop()
      require('sqmeow.core.state').reset()
      require('sqmeow.ui.drawer').reset()
      notify('engine stopped')
    end,
  },
  restart = {
    desc = 'Restart the engine',
    run = function()
      local channel, err = require('sqmeow.rpc.client').restart()
      -- Restarting discards the engine session; clear its Lua state too.
      require('sqmeow.core.state').reset()
      require('sqmeow.ui.drawer').reset()
      if channel then
        return notify('engine restarted')
      end
      notify(err or 'the engine could not be restarted', vim.log.levels.ERROR)
    end,
  },
}

return M
