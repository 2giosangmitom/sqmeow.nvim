--- Every mapping the plugin makes.
---
--- One table, keyed by surface and then by action name. It is the only source: the mappings that
--- get applied, the `?` cheatsheet, and the help file all read from here, so none of the three can
--- drift from the others.
---
--- The plugin takes no key outside its own windows. Mappings are buffer-local, applied when a
--- surface's buffer is created. Anything worth putting on a global key is offered as a `<Plug>`
--- mapping instead, for the user to bind or ignore.
---
---@tag sqmeow-keymaps
---@toc_entry Keymaps

local M = {}

---@class sqmeow.Keymap
---@field action string The name the configuration overrides it by.
---@field lhs string|string[] One key, or several that do the same thing.
---@field mode string|string[]|nil Defaults to normal mode.
---@field desc string Shown by which-key, by `:map`, and in the cheatsheet.

--- A mapping as it is applied, after the user's overrides.
---@class sqmeow.ResolvedKeymap
---@field action string
---@field lhs string[] Empty for an action the user turned off.
---@field mode string|string[]
---@field desc string

--- Built-in mappings, per surface.
---
--- A list rather than a table, so the cheatsheet and the help file present them in a deliberate
--- order rather than whatever order Lua happens to iterate in.
---
--- What follows is generated from this table when the help file is built, so it is the mappings
--- the plugin actually applies rather than a second list that can fall behind them.
---@eval return require('sqmeow.keymap').summary()
---@type table<string, sqmeow.Keymap[]>
M.defaults = {
  drawer = {
    { action = 'toggle', lhs = { '<CR>', 'o' }, desc = 'Expand or collapse the node' },
    { action = 'preview', lhs = 'p', desc = 'Show the first page of this relation' },
    { action = 'refresh', lhs = 'r', desc = 'Reload this subtree' },
    { action = 'yank_name', lhs = 'y', desc = 'Yank the qualified name' },
    { action = 'yank_select', lhs = 's', desc = 'Yank a SELECT for this relation' },
    -- `r` refreshes on every surface, so renaming takes the shifted key rather than the one a
    -- user has already learned means something harmless.
    { action = 'rename', lhs = 'R', desc = 'Rename the connection or scratchpad under the cursor' },
    { action = 'use', lhs = 'u', desc = 'Run queries against this connection' },
    { action = 'add', lhs = 'A', desc = 'Add a connection' },
    {
      action = 'new_scratchpad',
      lhs = 'a',
      desc = 'Create a scratchpad for the connection under the cursor',
    },
    { action = 'edit', lhs = 'e', desc = 'Edit the connection under the cursor' },
    { action = 'delete', lhs = 'd', desc = 'Delete the scratchpad, or empty the query log' },
    { action = 'help', lhs = '?', desc = 'Show these mappings' },
    { action = 'close', lhs = 'q', desc = 'Close the drawer' },
  },

  result = {
    { action = 'next_page', lhs = 'L', desc = 'Next page' },
    { action = 'prev_page', lhs = 'H', desc = 'Previous page' },
    { action = 'first_page', lhs = 'gg', desc = 'First page' },
    { action = 'last_page', lhs = 'G', desc = 'Last page' },
    { action = 'detail', lhs = 'K', desc = 'Show this row down the page' },
    -- Not `e`: a wide grid is crossed with the word motions, and `x` edits nothing in a buffer
    -- that cannot be edited.
    { action = 'export', lhs = 'x', desc = 'Export the result to a file' },
    { action = 'export_selection', lhs = 'x', mode = 'x', desc = 'Export the selected rows' },
    { action = 'help', lhs = '?', desc = 'Show these mappings' },
    { action = 'close', lhs = 'q', desc = 'Close the result window' },
  },

  -- A scratchpad is an ordinary editing buffer, so it gets none of the single-letter keys the
  -- read-only surfaces use. `?` and `q` in particular stay what they always are: a search and a
  -- macro recording.
  editor = {
    { action = 'execute_statement', lhs = '<CR>', desc = 'Run the statement under the cursor' },
    { action = 'execute_selection', lhs = '<CR>', mode = 'x', desc = 'Run the selection' },
    { action = 'execute_buffer', lhs = '<leader>E', desc = 'Run the whole buffer' },
    { action = 'cancel', lhs = '<C-c>', desc = 'Stop the running query' },
  },
}

--- Actions that are worth a key of the user's own choosing.
---
--- Defined globally as `<Plug>` mappings and bound to nothing. Offering them this way is what lets
--- the plugin be convenient without taking a key someone else is using.
---@type table<string, { desc: string, run: fun() }>
M.plug = {
  ['sqmeow-toggle'] = {
    desc = 'Open every sqmeow window, or close them',
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
  ['sqmeow-add-connection'] = {
    desc = 'Add a connection',
    run = function()
      require('sqmeow.ui.connection').create()
    end,
  },
  ['sqmeow-scratch'] = {
    desc = 'Create a scratchpad for this connection',
    run = function()
      require('sqmeow.api').scratchpad()
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
---@return sqmeow.ResolvedKeymap[] # In presentation order. An action the user disabled has no keys.
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

--- Actions that were taken out, and what took their place, so an override naming one says why it
--- no longer does anything.
local REMOVED = {
  yank_cell = 'yanking was replaced by exporting: `x`, or `x` on a visual selection',
  yank_row = 'yanking was replaced by exporting: `x`, or `x` on a visual selection',
  yank_page = 'yanking was replaced by exporting: `x`, or `x` on a visual selection',
}

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
          local problem = ('`%s` has no action named `%s`'):format(surface, action)
          if REMOVED[action] then
            problem = problem .. '; ' .. REMOVED[action]
          end
          table.insert(problems, problem)
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

--- Every surface's mappings, as lines, for the help file.
---
--- The same lines the `?` cheatsheet shows, so the two cannot disagree and neither can disagree
--- with what is bound: all three read `M.resolve`.
---
---@return string[]
function M.summary()
  local lines = {}

  for _, surface in ipairs({ 'drawer', 'result', 'editor' }) do
    table.insert(lines, surface)
    vim.list_extend(lines, require('sqmeow.ui.help').lines(surface))
    table.insert(lines, '')
  end

  -- The trailing blank would become an extra line in the help file.
  table.remove(lines)
  return lines
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
