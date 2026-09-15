--- The `:Sqmeow` command.

local M = {}

local notify = require('sqmeow.utils').notify

--- Discard a return value.
local function void(_) end

---@class sqmeow.Subcommand
---@field desc string Shown in completion and in the help file.
---@field run fun(args: string[], opts: table)
---@field complete nil|fun(lead: string): string[]

--- Subcommands, each a description and what to run.
---@type table<string, sqmeow.Subcommand>
M.subcommands = {
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
      -- The form is the way in.
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

      -- Only the saved ones: an open connection that was never saved has no entry to change.
      local saved = require('sqmeow.sources').load()
      if #saved == 0 then
        return notify('there are no saved connections', vim.log.levels.WARN)
      end

      local items = vim.tbl_map(function(spec)
        local icon, highlight = require('sqmeow.icons').get('connection')
        return { label = spec.name, icon = icon, highlight = highlight, value = spec }
      end, saved)

      local opened, err = require('sqmeow.ui.form').menu({
        title = 'Edit',
        items = items,
        on_choice = prompt,
      })
      if not opened then
        notify(err or 'the menu could not be opened', vim.log.levels.ERROR)
      end
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
      local api = require('sqmeow.api')

      local function activate(id)
        local connection = api.use(id)
        if connection then
          notify(('queries now run on %s'):format(connection.name))
        end
      end

      if args[1] then
        for _, connection in ipairs(api.connections()) do
          if connection.name == args[1] then
            return activate(connection.id)
          end
        end
        return notify(('nothing open is called `%s`'):format(args[1]), vim.log.levels.WARN)
      end

      local items = vim.tbl_map(function(connection)
        local icon, highlight = require('sqmeow.icons').get('connected')
        return { label = connection.name, icon = icon, highlight = highlight, value = connection.id }
      end, api.connections())

      if #items == 0 then
        return notify('nothing is connected', vim.log.levels.WARN)
      end

      local opened, err = require('sqmeow.ui.form').menu({
        title = 'Use',
        items = items,
        on_choice = activate,
      })
      if not opened then
        notify(err or 'the menu could not be opened', vim.log.levels.ERROR)
      end
    end,
    complete = function(lead)
      local names = vim.tbl_map(function(connection)
        return connection.name
      end, require('sqmeow.api').connections())

      table.sort(names)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
    end,
  },

  bind = {
    desc = 'Tie this buffer to one connection, or `none` to untie it',
    run = function(args)
      local name = args[1]

      if name == 'none' then
        vim.b.sqmeow_connection = nil
        require('sqmeow.ui.editor').update_winbar()
        return notify('this buffer follows the active connection again')
      end

      if not name then
        local bound = vim.b.sqmeow_connection
        return notify(
          bound and ('this buffer runs on %s'):format(bound)
            or 'this buffer follows the active connection'
        )
      end

      if
        not require('sqmeow.sources').find(name)
        and not require('sqmeow.state').connection_by_name(name)
      then
        return notify(('there is no connection called `%s`'):format(name), vim.log.levels.WARN)
      end

      vim.b.sqmeow_connection = name
      require('sqmeow.ui.editor').update_winbar()
      notify(('this buffer runs on %s'):format(name))
    end,
    complete = function(lead)
      local names = { 'none' }
      for _, spec in ipairs((require('sqmeow.sources').load())) do
        table.insert(names, spec.name)
      end
      for _, connection in ipairs(require('sqmeow.api').connections()) do
        table.insert(names, connection.name)
      end

      table.sort(names)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
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

  float = {
    desc = 'Show the result in a bigger float, or back in its split',
    run = function()
      require('sqmeow.api').toggle_float()
    end,
  },

  review = {
    desc = 'Review the changes staged in the result, and apply them',
    run = function()
      require('sqmeow.api').review()
    end,
  },

  statement = {
    desc = 'Run the statement the cursor is in',
    run = function()
      void(require('sqmeow.api').execute_statement())
    end,
  },

  scratch = {
    desc = 'Create a scratchpad for a connection',
    run = function(args)
      void(require('sqmeow.api').scratchpad(args[1]))
    end,
  },

  export = {
    desc = 'Write the result to a file, or with `clipboard` as the path copy it',
    run = function(args)
      if args[2] == 'clipboard' then
        return require('sqmeow.api').export({ format = args[1], clipboard = true })
      end
      require('sqmeow.api').export({ format = args[1], path = args[2] })
    end,
    complete = function(lead)
      return vim.tbl_filter(function(format)
        return format:find(lead, 1, true) == 1
      end, { 'csv', 'json', 'sql' })
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

  install = {
    desc = 'Install the engine this plugin needs, by download or with cargo',
    complete = function(lead)
      return vim.tbl_filter(function(method)
        return method:find(lead, 1, true) == 1
      end, require('sqmeow.install').methods)
    end,
    run = function(args)
      -- Nothing is said here, and nothing is waited for.
      local method = args[1]
      require('sqmeow.install').install({
        method = method ~= '' and method or nil,
        version = args[2],
        callback = function(path)
          if not path then
            return
          end

          -- The old engine is still running, and the new one cannot start until it has gone.
          require('sqmeow.rpc').stop()
          require('sqmeow.state').reset()
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

  log = {
    desc = 'Choose a past query and show its result again, or `clear` to forget them',
    run = function(args)
      if args[1] == 'clear' then
        require('sqmeow.history').clear()
        require('sqmeow.ui.drawer').render()
        return notify('the query log is empty')
      end
      require('sqmeow.ui.log').open()
    end,
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, { 'clear' })
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
        return notify(err or 'the engine could not be started', vim.log.levels.ERROR)
      end
      local info = assert(rpc.info(), 'a started engine has answered its handshake')
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
      notify(err or 'the engine could not be restarted', vim.log.levels.ERROR)
    end,
  },
}

local function run(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1)

  if not name then
    return require('sqmeow.api').open_all()
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
    -- A subcommand's own arguments are not subcommand names.
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
