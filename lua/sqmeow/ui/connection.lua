--- Adding and editing a connection without typing a URL.

local M = {}

local utils = require('sqmeow.utils')

--- The box every connection dialog ends with.
local READ_ONLY = { key = 'read_only', label = 'Read only', checkbox = true }

--- The SSH host a server is reached through, which a database in a file has no use for.
local SSH = { key = 'ssh', label = 'SSH', optional = true, hint = 'user@bastion' }

--- The tunnel the answers name, or nil for none.
---@param answers table<string, string>
---@return string|nil
local function tunnel(answers)
  local ssh = vim.trim(answers.ssh or '')
  return ssh ~= '' and ssh or nil
end

--- What is wrong with the answers, if anything.
---@param dialect string
---@param existing string|nil The name being edited.
---@return fun(values: table<string, string>): string|nil
local function validator(dialect, existing)
  return function(values)
    local url, err = require('sqmeow.url').build(dialect, values)
    if not url then
      return err
    end

    for _, field in ipairs(require('sqmeow.dialects').fields(dialect)) do
      if not field.optional and vim.trim(values[field.key] or '') == '' then
        return ('%s cannot be empty'):format(field.label)
      end
    end

    local name = vim.trim(values.name or '')
    if name ~= '' and name ~= existing and require('sqmeow.sources').find(name) then
      return ('there is already a connection called `%s`'):format(name)
    end
    return nil
  end
end

--- Open the form for one dialect.
---@param dialect string
---@param values table<string, string> What the fields start as.
---@param existing string|nil The name of the saved connection being changed, if it is one.
local function form(dialect, values, existing)
  local spec = assert(require('sqmeow.dialects').get(dialect), 'the menu offers known dialects')
  local opened, err = require('sqmeow.ui.form').open({
    title = existing and ('Edit %s'):format(existing) or ('New %s connection'):format(spec.label),
    fields = vim.list_extend(
      require('sqmeow.dialects').fields(dialect),
      spec.port and { SSH, READ_ONLY } or { READ_ONLY }
    ),
    values = vim.tbl_extend('keep', values, { read_only = 'no' }),
    -- A new connection is a run of questions with no answers yet.
    wizard = existing == nil,
    validate = validator(dialect, existing),
    on_submit = function(answers)
      -- The form refuses to submit until `validator` accepts the answers, so this cannot fail.
      local url = assert(require('sqmeow.url').build(dialect, answers))
      local name = vim.trim(answers.name)
      local read_only = answers.read_only == 'yes'

      local api = require('sqmeow.api')
      if existing then
        api.edit(
          existing,
          { name = name, url = url, read_only = read_only, ssh = tunnel(answers) or '' }
        )
        return
      end

      local ssh = tunnel(answers)
      if api.save(name, url, { read_only = read_only, ssh = ssh }) then
        api.connect(url, { name = name, read_only = read_only, ssh = ssh })
      end
    end,
  })

  if not opened then
    utils.notify(err or 'the dialog could not open', vim.log.levels.ERROR)
  end
end

--- Ask for a name and a whole URL, for someone who already has one.
---@param values table<string, string>|nil What the fields start as.
function M.from_url(values)
  local opened, err = require('sqmeow.ui.form').open({
    title = 'New connection from a URL',
    fields = {
      { key = 'name', label = 'Name' },
      { key = 'url', label = 'URL', hint = 'postgres://user@localhost/app' },
      SSH,
      READ_ONLY,
    },
    values = vim.tbl_extend('keep', values or {}, { read_only = 'no' }),
    wizard = values == nil,
    validate = function(answers)
      local name, url = vim.trim(answers.name or ''), vim.trim(answers.url or '')
      if name == '' then
        return 'Name cannot be empty'
      end
      if not require('sqmeow.dialects').of_url(url) then
        return 'the URL has to start with a database the plugin speaks, such as postgres://'
      end
      if require('sqmeow.sources').find(name) then
        return ('there is already a connection called `%s`'):format(name)
      end
      return nil
    end,
    on_submit = function(answers)
      local name, url = vim.trim(answers.name), vim.trim(answers.url)
      local read_only = answers.read_only == 'yes'
      local api = require('sqmeow.api')
      local ssh = tunnel(answers)
      if api.save(name, url, { read_only = read_only, ssh = ssh }) then
        api.connect(url, { name = name, read_only = read_only, ssh = ssh })
      end
    end,
  })

  if not opened then
    utils.notify(err or 'the dialog could not open', vim.log.levels.ERROR)
  end
end

--- Ask which database, then ask for its details.
function M.create()
  local icons = require('sqmeow.icons')

  local items = vim.tbl_map(function(dialect)
    local icon, highlight = icons.get(dialect.id)
    return { label = dialect.label, icon = icon, highlight = highlight, value = dialect.id }
  end, require('sqmeow.dialects').list)
  -- Last, for someone holding a URL who would rather paste it than take it apart into fields.
  local icon, highlight = icons.get('connection')
  table.insert(
    items,
    { label = 'Connection string', icon = icon, highlight = highlight, value = 'url' }
  )

  local opened, err = require('sqmeow.ui.form').menu({
    title = 'Connect to',
    items = items,
    on_choice = function(choice)
      if choice == 'url' then
        return M.from_url()
      end
      form(choice, {}, nil)
    end,
  })

  if not opened then
    utils.notify(err or 'the dialog could not open', vim.log.levels.ERROR)
  end
end

--- Open a saved connection in the form.
---@param spec sqmeow.ConnectionSpec
---@return boolean opened
function M.edit(spec)
  local values = require('sqmeow.url').parse(spec.url)
  if not values then
    return false
  end

  values.name = spec.name
  values.read_only = spec.read_only and 'yes' or 'no'
  values.ssh = spec.ssh
  form(values.dialect, values, spec.name)
  return true
end

return M
