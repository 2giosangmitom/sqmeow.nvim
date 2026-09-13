--- Adding and editing a connection without typing a URL.
---
--- Two steps, the way a graphical client does it: choose which database, then fill in a form of
--- named fields. The URL is assembled from the answers, so nobody has to remember where the colon
--- goes or how to escape a `#` in a password.
---
--- Editing works the same way in reverse. A saved URL is taken apart into the same fields, so what
--- opens is the connection as it stands rather than a string to edit in place.

local M = {}

--- What is wrong with the answers, if anything.
---
---@param dialect string
---@param existing string|nil The name being edited, which may keep its own name.
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
---
---@param dialect string
---@param values table<string, string> What the fields start as.
---@param existing string|nil The name of the saved connection being changed, if it is one.
local function form(dialect, values, existing)
  local spec = assert(require('sqmeow.dialects').get(dialect), 'the menu offers known dialects')
  local opened, err = require('sqmeow.ui.form').open({
    title = existing and ('Edit %s'):format(existing) or ('New %s connection'):format(spec.label),
    fields = require('sqmeow.dialects').fields(dialect),
    values = values,
    -- A new connection is a run of questions with no answers yet, so the dialog starts asking.
    -- An existing one is opened to be looked at, and jumping straight into a field would fight
    -- whoever only wanted to change the port.
    wizard = existing == nil,
    validate = validator(dialect, existing),
    on_submit = function(answers)
      -- The form refuses to submit until `validator` accepts the answers, so this cannot fail.
      local url = assert(require('sqmeow.url').build(dialect, answers))
      local name = vim.trim(answers.name)

      local api = require('sqmeow.api')
      if existing then
        api.edit(existing, { name = name, url = url })
        return
      end

      if api.save(name, url) then
        api.connect(url, { name = name })
      end
    end,
  })

  if not opened then
    vim.notify(err or 'sqmeow: the dialog could not open', vim.log.levels.ERROR)
  end
end

--- Ask which database, then ask for its details.
---
--- The entry point behind `:Sqmeow add` and `A` in the drawer.
function M.create()
  local icons = require('sqmeow.icons')

  local items = vim.tbl_map(function(dialect)
    local icon, highlight = icons.get(dialect.id)
    return { label = dialect.label, icon = icon, highlight = highlight, value = dialect.id }
  end, require('sqmeow.dialects').list)

  local opened, err = require('sqmeow.ui.form').menu({
    title = 'Connect to',
    items = items,
    on_choice = function(dialect)
      form(dialect, {}, nil)
    end,
  })

  if not opened then
    vim.notify(err or 'sqmeow: the dialog could not open', vim.log.levels.ERROR)
  end
end

--- Open a saved connection in the form.
---
--- A URL the plugin cannot take apart, such as one holding a `{{ exec }}` template for a password,
--- is left to the older prompt: rewriting it through fields would throw the template away.
---
---@param spec sqmeow.ConnectionSpec
---@return boolean opened
function M.edit(spec)
  -- A template is expanded by the engine at connect time. Splitting one into fields and writing it
  -- back would percent encode the braces and leave a connection that reaches nothing.
  if spec.url:find('{{', 1, true) then
    return false
  end

  local values = require('sqmeow.url').parse(spec.url)
  if not values then
    return false
  end

  values.name = spec.name
  form(values.dialect, values, spec.name)
  return true
end

return M
