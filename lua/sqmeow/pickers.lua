--- The lists the plugin offers.
---
--- Every one of them goes through |sqmeow.integrations.picker|, so each is written once and shown
--- with whichever of telescope, fzf-lua and snacks.picker the user has, or with `vim.ui.select`
--- when they have none. Nothing here knows which picker it is talking to.
---
---@tag sqmeow-pickers
---@toc_entry Pickers

local M = {}

local function pick(items, opts)
  return require('sqmeow.integrations.picker').pick(items, opts)
end

local function notify(message, level)
  require('sqmeow.integrations.notify').notify(message, level)
end

--- Switch the current connection, or open one that is configured but not yet open.
---
--- Open connections come first, since switching between them is the common case, and a configured
--- one is offered below so a connection is never more than one list away.
---
---@param opts table|nil Passed through to the picker, plus `only = 'saved'` to leave out the open
--- ones and `on_choice` to do something other than switch to what was chosen.
function M.connections(opts)
  opts = opts or {}
  local api = require('sqmeow.api')
  local url = require('sqmeow.url')

  local items = {}
  for _, connection in ipairs(opts.only == 'saved' and {} or api.connections()) do
    table.insert(items, {
      kind = 'open',
      id = connection.id,
      name = connection.name,
      url = connection.url,
      detail = connection.dialect or connection.state,
    })
  end

  local open = {}
  for _, item in ipairs(items) do
    open[item.name] = true
  end

  local available, problems = api.available()
  for _, problem in ipairs(problems) do
    notify(problem, vim.log.levels.WARN)
  end
  for _, spec in ipairs(available) do
    if not open[spec.name] then
      table.insert(items, {
        kind = 'saved',
        name = spec.name,
        url = spec.url,
        detail = 'not connected',
      })
    end
  end

  pick(items, {
    prompt = opts.prompt or 'Connections',
    empty = 'there are no connections, saved or open',
    format = function(item)
      return ('%-24s %s'):format(item.name, item.detail)
    end,
    preview = function(item)
      return { item.name, url.display(item.url), item.detail }
    end,
    on_choice = opts.on_choice or function(item)
      if item.kind == 'open' then
        return api.use(item.id)
      end
      api.connect(item.url, { name = item.name })
    end,
  })
end

--- Find a table or a view anywhere in the current connection.
---
--- The list is read once per connection and then held, so the second time it opens instantly. A
--- schema the user cannot read is left out rather than failing the list.
---
---@param opts table|nil `schema` limits the list to one schema; `refresh` re-reads it.
function M.relations(opts)
  opts = opts or {}
  local state = require('sqmeow.state')
  local connection = state.current_connection()

  if not connection then
    return notify('connect to a database first', vim.log.levels.WARN)
  end
  if opts.refresh then
    state.forget_catalog(connection.id)
  end

  require('sqmeow.events').ensure()
  state.await_catalog(connection.id, function(relations, err)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end

    local items = relations
    if opts.schema then
      items = vim.tbl_filter(function(relation)
        return relation.schema == opts.schema
      end, relations)
    end

    pick(items, {
      prompt = opts.prompt or ('Relations in ' .. connection.name),
      empty = 'this connection has no tables or views to show',
      filetype = 'sql',
      format = function(relation)
        return ('%s.%s%s'):format(
          relation.schema,
          relation.name,
          relation.kind == 'table' and '' or ('  ' .. relation.kind)
        )
      end,
      preview = function(relation)
        return {
          require('sqmeow.sql').select_from(
            connection.dialect,
            { relation.schema, relation.name },
            require('sqmeow.config').get().ui.result.page_size
          ),
        }
      end,
      on_choice = function(relation)
        require('sqmeow.api').execute(
          require('sqmeow.sql').select_from(
            connection.dialect,
            { relation.schema, relation.name },
            require('sqmeow.config').get().ui.result.page_size
          )
        )
      end,
    })
  end)
end

--- Reopen a past result.
---
--- Nothing is run again. The engine still holds the rows, so choosing an entry only asks it to
--- paint them, which is what makes going back to an expensive query free.
---
---@param opts table|nil
function M.history(opts)
  opts = opts or {}
  local log = require('sqmeow.ui.log')

  pick(log.entries(), {
    prompt = opts.prompt or 'Query log',
    empty = 'nothing has been run yet',
    filetype = 'sql',
    format = log.describe,
    preview = function(summary)
      local lines = vim.split(summary.statement or '', '\n', { plain = true })
      table.insert(lines, '')
      table.insert(lines, '-- ' .. log.describe(summary))
      return lines
    end,
    on_choice = function(summary)
      require('sqmeow.api').reopen(summary.call_id)
    end,
  })
end

--- Open one of the saved scratchpads.
---
---@param opts table|nil
function M.scratchpads(opts)
  opts = opts or {}
  local editor = require('sqmeow.ui.editor')

  pick(editor.list(), {
    prompt = opts.prompt or 'Scratchpads',
    empty = 'there are no saved scratchpads',
    filetype = 'sql',
    format = function(item)
      return item.name
    end,
    preview = function(item)
      local ok, lines = pcall(vim.fn.readfile, item.path, '', 200)
      return ok and lines or { 'could not read ' .. item.path }
    end,
    on_choice = function(item)
      editor.open_path(item.path)
    end,
  })
end

--- Jump to a column of the current result.
---
--- A wide result is the reason this exists: scrolling sideways to find a column is exactly the
--- kind of thing a fuzzy list is better at.
---
---@param opts table|nil
function M.columns(opts)
  opts = opts or {}
  local call = require('sqmeow.state').call
  local result = require('sqmeow.ui.result')

  local spans = call and call.column_spans or {}
  local items = {}
  for index, span in ipairs(spans) do
    table.insert(items, { index = index, name = span.name, type_name = span.type_name })
  end

  pick(items, {
    prompt = opts.prompt or 'Columns',
    empty = 'there is no result to look through',
    format = function(item)
      return ('%-32s %s'):format(item.name, item.type_name or '')
    end,
    preview = function(item)
      local lines = { item.name, item.type_name or '', '' }
      return vim.list_extend(lines, result.column_values(item.index, 20))
    end,
    on_choice = function(item)
      result.goto_column(item.index)
    end,
  })
end

--- Every picker, by the name `:Sqmeow find` and the telescope extension use.
---@type table<string, fun(opts: table|nil)>
M.all = {
  connections = M.connections,
  relations = M.relations,
  history = M.history,
  scratchpads = M.scratchpads,
  columns = M.columns,
}

--- The picker names, sorted, for completion.
---@return string[]
function M.names()
  local names = vim.tbl_keys(M.all)
  table.sort(names)
  return names
end

--- Show a picker by name, or ask which one.
---
---@param name string|nil
---@param opts table|nil
function M.open(name, opts)
  if not name then
    return pick(M.names(), {
      prompt = 'sqmeow',
      format = function(item)
        return item
      end,
      on_choice = function(item)
        M.all[item](opts)
      end,
    })
  end

  local picker = M.all[name]
  if not picker then
    return notify(('there is no `%s` picker'):format(name), vim.log.levels.ERROR)
  end
  picker(opts)
end

return M
