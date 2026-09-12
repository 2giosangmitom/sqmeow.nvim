--- The `:Sqmeow` command.
---
--- One command with subcommands, rather than a command per action. It keeps one name in the user's
--- command space, gives completion a single place to live, and means the plugin adds exactly one
--- entry to `:command`.

local M = {}

local function notify(message, level)
  require('sqmeow.integrations.notify').notify(message, level)
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

      -- Nothing saved and nothing open means there is nothing to pick from, so the only useful
      -- thing to offer is the dialog that makes one.
      if #api.available() == 0 and #api.connections() == 0 then
        return require('sqmeow.ui.connection').create()
      end

      require('sqmeow.pickers').connections({ prompt = 'Connect to' })
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

  add = {
    desc = 'Add a connection, choosing the database and filling in a form',
    run = function()
      require('sqmeow.ui.connection').create()
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

  edit = {
    desc = 'Change a saved connection: what it is called, or where it points',
    run = function(args)
      -- The form is the way in. The prompts stay for a URL it cannot take apart, such as one
      -- holding a template, where fields would lose more than they gain.
      local function prompt(spec)
        if require('sqmeow.ui.connection').edit(spec) then
          return
        end

        vim.ui.input({ prompt = 'Call it: ', default = spec.name }, function(name)
          if not name or name == '' then
            return
          end
          vim.ui.input({ prompt = 'URL: ', default = spec.url }, function(url)
            if not url or url == '' then
              return
            end
            require('sqmeow.api').edit(spec.name, { name = name, url = url })
          end)
        end)
      end

      if args[1] then
        local spec = require('sqmeow.sources').find(args[1])
        if not spec then
          return notify(
            ('there is no configured connection named `%s`'):format(args[1]),
            vim.log.levels.WARN
          )
        end
        return prompt(spec)
      end

      require('sqmeow.pickers').connections({
        prompt = 'Edit',
        -- Only the saved ones: an open connection that was never saved has no entry to change.
        only = 'saved',
        on_choice = prompt,
      })
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

  disconnect = {
    desc = 'Close the current connection',
    run = function()
      require('sqmeow.api').disconnect()
    end,
  },

  use = {
    desc = 'Choose the connection queries run against',
    run = function(args)
      if args[1] then
        return void(require('sqmeow.api').use(tonumber(args[1]) or -1))
      end
      require('sqmeow.pickers').connections()
    end,
  },

  execute = {
    desc = 'Run the current buffer, the selection, or the given SQL',
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

  statement = {
    desc = 'Run the statement the cursor is in',
    run = function()
      void(require('sqmeow.api').execute_statement())
    end,
  },

  scratch = {
    desc = 'Open the scratchpad for this connection',
    run = function(args)
      void(require('sqmeow.api').scratchpad(args[1]))
    end,
  },

  export = {
    desc = 'Write the result to a file',
    run = function(args)
      require('sqmeow.api').export({ format = args[1], path = args[2] })
    end,
    complete = function(lead)
      return vim.tbl_filter(function(format)
        return format:find(lead, 1, true) == 1
      end, { 'csv', 'json' })
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

  find = {
    desc = "Open one of the plugin's pickers",
    run = function(args)
      require('sqmeow.pickers').open(args[1])
    end,
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, require('sqmeow.pickers').names())
    end,
  },

  update = {
    desc = 'Download the engine this plugin needs',
    run = function(args)
      notify('fetching the engine…')

      local path, err = require('sqmeow.install').ensure({ force = true, version = args[1] })
      if not path then
        return notify(err, vim.log.levels.ERROR)
      end

      -- The old one is still running and still speaking the old protocol, so it has to go.
      require('sqmeow.rpc').stop()
      require('sqmeow.state').reset()
      require('sqmeow.ui.drawer').reset()
      notify('installed ' .. path)
    end,
  },

  health = {
    desc = 'Run the health check',
    run = function()
      vim.cmd.checkhealth('sqmeow')
    end,
  },

  log = {
    desc = 'Choose a past query and show its result again',
    run = function()
      require('sqmeow.pickers').history()
    end,
  },

  messages = {
    desc = 'Show what the engine has been saying',
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
