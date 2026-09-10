--- The `:Sqmeow` command.
---
--- One command with subcommands, rather than a command per action. It keeps one name in the user's
--- command space, gives completion a single place to live, and means the plugin adds exactly one
--- entry to `:command`.

local M = {}

local function notify(message, level)
  vim.notify('sqmeow: ' .. message, level or vim.log.levels.INFO)
end

--- Discard a return value, so `return api.execute(...)` stays a statement rather than making the
--- command handler answer with a call id nobody reads.
local function void(_) end

---@class sqmeow.Subcommand
---@field desc string Shown in completion and in the help file.
---@field run fun(args: string[], opts: table)
---@field complete nil|fun(lead: string): string[]

--- Subcommands, each a description and what to run.
---@type table<string, sqmeow.Subcommand>
M.subcommands = {
  connect = {
    desc = 'Connect to a saved connection, or to a URL',
    run = function(args)
      local api = require('sqmeow.api')
      local target = args[1]

      if target then
        -- A URL has a scheme; anything else is the name of a configured connection.
        if target:find(':', 1, true) then
          return void(api.connect(target, { name = args[2] }))
        end
        return void(api.connect_named(target))
      end

      local available, problems = api.available()
      for _, problem in ipairs(problems) do
        notify(problem, vim.log.levels.WARN)
      end

      if #available == 0 then
        return vim.ui.input({ prompt = 'Database URL: ' }, function(entered)
          if entered and entered ~= '' then
            void(api.connect(entered))
          end
        end)
      end

      vim.ui.select(available, {
        prompt = 'Connect to',
        format_item = function(connection)
          return ('%s  %s'):format(connection.name, require('sqmeow.url').display(connection.url))
        end,
      }, function(chosen)
        if chosen then
          void(api.connect(chosen.url, { name = chosen.name }))
        end
      end)
    end,
    complete = function(lead)
      local names = vim.tbl_map(function(connection)
        return connection.name
      end, (require('sqmeow.api').available()))

      table.sort(names)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
    end,
  },

  save = {
    desc = 'Save a connection for next time',
    run = function(args)
      local api = require('sqmeow.api')

      if args[1] and args[2] then
        return void(api.save(args[1], args[2]))
      end

      local current = require('sqmeow.state').current_connection()
      if not current then
        return notify('connect first, or pass a name and a url', vim.log.levels.WARN)
      end

      vim.ui.input({ prompt = 'Save as: ', default = current.name }, function(name)
        if name and name ~= '' then
          void(api.save(name, current.url))
        end
      end)
    end,
  },

  disconnect = {
    desc = 'Close the current connection',
    run = function()
      require('sqmeow.api').disconnect()
    end,
  },

  use = {
    desc = 'Choose the connection queries run against',
    run = function(args)
      local api = require('sqmeow.api')
      local connections = api.connections()

      if #connections == 0 then
        return notify('there are no connections', vim.log.levels.WARN)
      end
      if args[1] then
        return void(api.use(tonumber(args[1]) or -1))
      end

      vim.ui.select(connections, {
        prompt = 'Connection',
        format_item = function(connection)
          return ('%d  %s (%s)'):format(
            connection.id,
            connection.name,
            connection.dialect or connection.state
          )
        end,
      }, function(chosen)
        if chosen then
          api.use(chosen.id)
        end
      end)
    end,
  },

  execute = {
    desc = 'Run the current buffer, or the given SQL',
    run = function(args, opts)
      local api = require('sqmeow.api')
      if #args > 0 then
        return void(api.execute(table.concat(args, ' ')))
      end
      if opts.range and opts.range > 0 then
        return void(api.execute_selection())
      end
      void(api.execute_buffer())
    end,
  },

  cancel = {
    desc = 'Stop the running query',
    run = function()
      if not require('sqmeow.api').cancel() then
        notify('there is no query running')
      end
    end,
  },

  next = {
    desc = 'Show the next page of results',
    run = function()
      require('sqmeow.api').next_page()
    end,
  },

  prev = {
    desc = 'Show the previous page of results',
    run = function()
      require('sqmeow.api').prev_page()
    end,
  },

  toggle = {
    desc = 'Show the schema drawer, or hide it',
    run = function()
      require('sqmeow.api').toggle()
    end,
  },

  drawer = {
    desc = 'Show the schema drawer',
    run = function()
      require('sqmeow.api').open_drawer()
    end,
  },

  open = {
    desc = 'Show the result window',
    run = function()
      require('sqmeow.api').open()
    end,
  },

  close = {
    desc = 'Hide the result window',
    run = function()
      require('sqmeow.api').close()
    end,
  },

  health = {
    desc = 'Run the health check',
    run = function()
      vim.cmd.checkhealth('sqmeow')
    end,
  },

  log = {
    desc = 'Show the engine log',
    run = function()
      local lines = require('sqmeow.rpc').messages()
      if #lines == 0 then
        return notify('the engine log is empty')
      end
      notify(table.concat(lines, '\n'))
    end,
  },

  start = {
    desc = 'Start the engine',
    run = function()
      local rpc = require('sqmeow.rpc')
      local channel, err = rpc.start()
      if not channel then
        return notify(err, vim.log.levels.ERROR)
      end
      local info = rpc.info()
      notify(('engine %s running (pid %d)'):format(info.core_version, info.pid))
    end,
  },

  stop = {
    desc = 'Stop the engine',
    run = function()
      require('sqmeow.rpc').stop()
      require('sqmeow.state').reset()
      require('sqmeow.ui.drawer').reset()
      notify('engine stopped')
    end,
  },

  restart = {
    desc = 'Restart the engine',
    run = function()
      local channel, err = require('sqmeow.rpc').restart()
      -- The engine's session went with it, so the mirrored state is no longer true.
      require('sqmeow.state').reset()
      require('sqmeow.ui.drawer').reset()
      if channel then
        return notify('engine restarted')
      end
      notify(err, vim.log.levels.ERROR)
    end,
  },
}

local function run(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1)

  if not name then
    return require('sqmeow.api').toggle()
  end

  local subcommand = M.subcommands[name]
  if not subcommand then
    return notify(('unknown subcommand `%s`'):format(name), vim.log.levels.ERROR)
  end

  subcommand.run(args, opts)
end

local function complete(lead, line)
  local name = line:match('^%s*Sqmeow%s+(%S+)%s')

  if name then
    local subcommand = M.subcommands[name]
    if subcommand and subcommand.complete then
      return subcommand.complete(lead)
    end
    -- A subcommand's own arguments are not subcommand names, so offer nothing rather than
    -- something misleading.
    return {}
  end

  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return vim.tbl_filter(function(candidate)
    return candidate:find(lead, 1, true) == 1
  end, names)
end

--- Register `:Sqmeow`.
function M.register()
  vim.api.nvim_create_user_command('Sqmeow', run, {
    nargs = '*',
    range = true,
    desc = 'sqmeow.nvim',
    complete = complete,
  })
end

return M
