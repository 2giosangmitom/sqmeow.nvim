-- Subcommands for one domain; required directly by sqmeow.commands.
-- No re-export.

local M = {}

local notify = require('sqmeow.core.utils').notify

--- Discard a return value.
local function void(_) end

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
      if args[1] and args[2] then
        return void(require('sqmeow.api.connection').save(args[1], args[2]))
      end

      local current = require('sqmeow.core.state').current_connection()
      if not current then
        return notify('connect first, or pass a name and a url', vim.log.levels.WARN)
      end

      vim.ui.input({ prompt = 'Save as: ', default = current.name }, function(name)
        if name and name ~= '' then
          void(require('sqmeow.api.connection').save(name, current.url))
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
            require('sqmeow.api.connection').edit(spec.name, { name = name, url = url })
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
        local icon, highlight = require('sqmeow.core.icons').get('connection')
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
      end, (require('sqmeow.api.connection').available()))

      table.sort(names)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
    end,
  },
  disconnect = {
    desc = 'Close the current connection',
    run = function()
      require('sqmeow.api.connection').disconnect()
    end,
  },
  remove = {
    desc = 'Delete a saved connection, closing it while it is open',
    run = function(args)
      local name = args[1]
      if not name or name == '' then
        return notify('name a connection to delete', vim.log.levels.WARN)
      end
      local spec = require('sqmeow.sources').find(name)
      if require('sqmeow.api.connection').remove(name) then
        -- A connection from any other source is only closed, since its entry cannot be removed.
        if spec and spec.source ~= 'file' then
          notify(('disconnected from %s'):format(name))
        else
          notify(('deleted the connection %s'):format(name))
        end
      end
    end,
    complete = function(lead)
      local names = {}
      for _, spec in ipairs((require('sqmeow.sources').load())) do
        table.insert(names, spec.name)
      end
      for _, connection in ipairs(require('sqmeow.api.connection').connections()) do
        table.insert(names, connection.name)
      end

      table.sort(names)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
    end,
  },
  use = {
    desc = 'Choose the connection queries run against',
    run = function(args)
      local state = require('sqmeow.core.state')

      local function activate(id)
        local connection = require('sqmeow.api.connection').use(id)
        if connection then
          notify(('queries now run on %s'):format(connection.name))
        end
      end

      local function is_cluster(connection)
        if connection.parent or connection.database then
          return false
        end
        local url = require('sqmeow.core.url').split(connection.url)
        if not url or url.dialect == 'sqlite' or url.dialect == 'duckdb' then
          return false
        end
        return not url.database or url.database == ''
      end

      local function activate_child(parent, database)
        local child = state.child_connection(parent.id, database)
        if child and (child.state == 'connected' or child.state == 'connecting') then
          return activate(child.id)
        end

        local id = require('sqmeow.api.connection').connect(parent.url, {
          name = ('%s/%s'):format(parent.name, database),
          parent = parent.id,
          database = database,
          read_only = parent.read_only,
          ssh = parent.ssh,
        })
        if id then
          activate(id)
        end
      end

      local function choose_database(cluster)
        require('sqmeow.api.connection').databases(cluster.id, function(dbs, err)
          if err or not dbs or #dbs == 0 then
            return notify(
              err or ('no databases found for %s'):format(cluster.name),
              vim.log.levels.WARN
            )
          end

          if #dbs == 1 then
            return activate_child(cluster, dbs[1])
          end

          local db_items = vim.tbl_map(function(db)
            local icon, highlight = require('sqmeow.core.icons').get('database')
            return { label = db, icon = icon, highlight = highlight, value = db }
          end, dbs)

          local opened, menu_err = require('sqmeow.ui.form').menu({
            title = cluster.name,
            items = db_items,
            on_choice = function(db)
              activate_child(cluster, db)
            end,
          })
          if not opened then
            notify(menu_err or 'the menu could not be opened', vim.log.levels.ERROR)
          end
        end)
      end

      if args[1] then
        for _, connection in ipairs(require('sqmeow.api.connection').connections()) do
          if connection.name == args[1] then
            if is_cluster(connection) then
              return choose_database(connection)
            end
            return activate(connection.id)
          end
        end

        local parent_name, child_db = args[1]:match('^([^/]+)/(.+)$')
        if parent_name and child_db then
          local parent = state.connection_by_name(parent_name)
          if parent and parent.state == 'connected' then
            return activate_child(parent, child_db)
          end
        end

        return notify(('nothing open is called `%s`'):format(args[1]), vim.log.levels.WARN)
      end

      local items = vim.tbl_map(function(connection)
        local icon, highlight = require('sqmeow.core.icons').get('connected')
        local label = connection.name
        if
          not is_cluster(connection)
          and not connection.parent
          and not connection.name:find('/')
        then
          local url = require('sqmeow.core.url').split(connection.url)
          if url and url.database and url.database ~= '' and url.database ~= connection.name then
            label = ('%s / %s'):format(connection.name, url.database)
          end
        end
        return { label = label, icon = icon, highlight = highlight, value = connection }
      end, require('sqmeow.api.connection').connections())

      if #items == 0 then
        return notify('nothing is connected', vim.log.levels.WARN)
      end

      local opened, err = require('sqmeow.ui.form').menu({
        title = 'Use',
        items = items,
        on_choice = function(connection)
          if is_cluster(connection) then
            return choose_database(connection)
          end
          activate(connection.id)
        end,
      })
      if not opened then
        notify(err or 'the menu could not be opened', vim.log.levels.ERROR)
      end
    end,
    complete = function(lead)
      local names = {}
      local seen = {}
      for _, connection in ipairs(require('sqmeow.api.connection').connections()) do
        if not seen[connection.name] then
          seen[connection.name] = true
          table.insert(names, connection.name)
        end
        local ok, drawer = pcall(require, 'sqmeow.ui.drawer')
        local dbs = ok and drawer.databases(connection.id)
        for _, db in ipairs(dbs or {}) do
          local child_name = ('%s/%s'):format(connection.name, db)
          if not seen[child_name] then
            seen[child_name] = true
            table.insert(names, child_name)
          end
        end
      end

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
        and not require('sqmeow.core.state').connection_by_name(name)
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
      for _, connection in ipairs(require('sqmeow.api.connection').connections()) do
        table.insert(names, connection.name)
      end

      table.sort(names)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
    end,
  },
}

return M
