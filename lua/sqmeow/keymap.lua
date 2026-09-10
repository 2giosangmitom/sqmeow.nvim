--- Every mapping the plugin makes.
---
--- One table, keyed by surface and then by action name. It is the only source: the mappings that
--- get applied, the `?` cheatsheet, and the help file all read from here, so none of the three can
--- drift from the others.
---
--- The plugin takes no key outside its own windows. Mappings are buffer-local, applied when a
--- surface's buffer is created. Anything worth putting on a global key is offered as a `<Plug>`
--- mapping instead, for the user to bind or ignore.

local M = {}

---@class sqmeow.Keymap
---@field action string The name the configuration overrides it by.
---@field lhs string|string[] One key, or several that do the same thing.
---@field mode string|string[] Defaults to normal mode.
---@field desc string Shown by which-key, by `:map`, and in the cheatsheet.

--- Built-in mappings, per surface.
---
--- A list rather than a table, so the cheatsheet and the help file present them in a deliberate
--- order rather than whatever order Lua happens to iterate in.
---@type table<string, sqmeow.Keymap[]>
M.defaults = {
  drawer = {
    { action = 'toggle', lhs = { '<CR>', 'o' }, desc = 'Expand or collapse the node' },
    { action = 'preview', lhs = 'p', desc = 'Show the first page of this relation' },
    { action = 'refresh', lhs = 'r', desc = 'Reload this subtree' },
    { action = 'yank_name', lhs = 'y', desc = 'Yank the qualified name' },
    { action = 'yank_select', lhs = 's', desc = 'Yank a SELECT for this relation' },
    { action = 'help', lhs = '?', desc = 'Show these mappings' },
    { action = 'close', lhs = 'q', desc = 'Close the drawer' },
  },

  result = {
    { action = 'next_page', lhs = 'L', desc = 'Next page' },
    { action = 'prev_page', lhs = 'H', desc = 'Previous page' },
    { action = 'first_page', lhs = 'gg', desc = 'First page' },
    { action = 'last_page', lhs = 'G', desc = 'Last page' },
    { action = 'help', lhs = '?', desc = 'Show these mappings' },
    { action = 'close', lhs = 'q', desc = 'Close the result window' },
  },
}

--- Actions that are worth a key of the user's own choosing.
---
--- Defined globally as `<Plug>` mappings and bound to nothing. Offering them this way is what lets
--- the plugin be convenient without taking a key someone else is using.
---@type table<string, { desc: string, run: fun() }>
M.plug = {
  ['sqmeow-toggle'] = {
    desc = 'Toggle the sqmeow drawer',
    run = function()
      require('sqmeow.api').toggle()
    end,
  },
  ['sqmeow-execute'] = {
    desc = 'Run the current buffer',
    run = function()
      require('sqmeow.api').execute_buffer()
    end,
  },
  ['sqmeow-execute-selection'] = {
    desc = 'Run the selection',
    run = function()
      require('sqmeow.api').execute_selection()
    end,
  },
  ['sqmeow-cancel'] = {
    desc = 'Stop the running query',
    run = function()
      require('sqmeow.api').cancel()
    end,
  },
}

local function as_list(value)
  if value == nil or value == false then
    return {}
  end
  if type(value) == 'string' then
    return { value }
  end
  return value
end

--- The mappings for one surface, after the user's overrides.
---
--- Overriding one action does not require restating the rest, because the merge is by action name
--- rather than by position.
---
---@param surface string 'drawer' or 'result'.
---@return sqmeow.Keymap[] # In presentation order. An action the user disabled has no keys.
function M.resolve(surface)
  local overrides = (require('sqmeow.config').get().keymaps or {})[surface] or {}

  return vim.tbl_map(function(entry)
    -- Written out rather than as an `and`/`or` expression: `false` is a meaningful override here,
    -- and that idiom cannot express it.
    local lhs = entry.lhs
    if overrides[entry.action] ~= nil then
      lhs = overrides[entry.action]
    end

    return {
      action = entry.action,
      lhs = as_list(lhs),
      mode = entry.mode or 'n',
      desc = entry.desc,
    }
  end, M.defaults[surface] or {})
end

--- Overrides that name an action the surface does not have.
---
--- Reported by `:checkhealth` rather than silently ignored: a mistyped action name would otherwise
--- look exactly like a mapping that refuses to work.
---
---@return string[]
function M.problems()
  local problems = {}
  local configured = require('sqmeow.config').get().keymaps or {}

  for surface, overrides in pairs(configured) do
    local defaults = M.defaults[surface]
    if not defaults then
      table.insert(problems, ('there is no `%s` surface to map keys on'):format(surface))
    else
      local known = {}
      for _, entry in ipairs(defaults) do
        known[entry.action] = true
      end
      for action in pairs(overrides) do
        if not known[action] then
          table.insert(problems, ('`%s` has no action named `%s`'):format(surface, action))
        end
      end
    end
  end

  table.sort(problems)
  return problems
end

--- Bind a surface's mappings in one buffer.
---
---@param surface string
---@param buf integer
---@param actions table<string, fun()> Action name to what it does. An action with no function is
--- skipped, so a surface can leave one unimplemented without breaking the rest.
function M.apply(surface, buf, actions)
  for _, entry in ipairs(M.resolve(surface)) do
    local run = actions[entry.action]
    if run then
      for _, lhs in ipairs(entry.lhs) do
        vim.keymap.set(entry.mode, lhs, run, {
          buffer = buf,
          nowait = true,
          -- which-key and `:map` both read this, so every mapping is self-describing.
          desc = 'sqmeow: ' .. entry.desc,
        })
      end
    end
  end
end

--- Define the `<Plug>` mappings.
function M.register_plug()
  for name, entry in pairs(M.plug) do
    vim.keymap.set('n', '<Plug>(' .. name .. ')', entry.run, {
      desc = 'sqmeow: ' .. entry.desc,
    })
  end
end

return M
