--- Every mapping the plugin makes.
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
---@eval return require('sqmeow.keymap').summary()
---@type table<string, sqmeow.Keymap[]>
M.defaults = {
  drawer = {
    { action = 'toggle', lhs = { '<CR>', 'o' }, desc = 'Expand or collapse the node' },
    { action = 'preview', lhs = 'p', desc = 'Show the first page of this relation' },
    { action = 'structure', lhs = 'K', desc = 'Show the structure of this table or key' },
    { action = 'filter_keys', lhs = 'f', desc = 'Show only the Redis keys matching a pattern' },
    { action = 'refresh', lhs = 'r', desc = 'Reload this subtree' },
    { action = 'yank_name', lhs = 'y', desc = 'Yank the qualified name' },
    { action = 'yank_select', lhs = 's', desc = 'Yank a SELECT for this relation' },
    -- `r` refreshes on every surface.
    { action = 'rename', lhs = 'R', desc = 'Rename the connection or scratchpad under the cursor' },
    { action = 'use', lhs = 'u', desc = 'Run queries against this connection' },
    { action = 'add', lhs = 'A', desc = 'Add a connection' },
    {
      action = 'new_scratchpad',
      lhs = 'a',
      desc = 'Create a scratchpad',
    },
    { action = 'edit', lhs = 'e', desc = 'Edit the connection under the cursor' },
    {
      action = 'delete',
      lhs = 'd',
      desc = 'Delete the connection or scratchpad, or empty the query log',
    },
    { action = 'help', lhs = '?', desc = 'Show these mappings' },
    { action = 'close', lhs = 'q', desc = 'Close the drawer' },
  },

  result = {
    { action = 'next_page', lhs = 'L', desc = 'Next page' },
    { action = 'prev_page', lhs = 'H', desc = 'Previous page' },
    { action = 'first_page', lhs = '[H', desc = 'First page' },
    { action = 'last_page', lhs = ']H', desc = 'Last page' },
    { action = 'detail', lhs = 'K', desc = 'Show this row down the page' },
    {
      action = 'structure',
      lhs = 'gK',
      desc = 'Show the columns and indexes of the table this column is from',
    },
    { action = 'next_result', lhs = ']r', desc = "Show the next statement's result" },
    { action = 'prev_result', lhs = '[r', desc = "Show the previous statement's result" },
    -- Not `e`, which is a word motion.
    { action = 'export', lhs = 'x', desc = 'Export the result to a file' },
    { action = 'export_selection', lhs = 'x', mode = 'x', desc = 'Export the selected rows' },
    -- How rows are shown.
    {
      action = 'filter_cell',
      lhs = '=',
      desc = 'Show only rows holding this value in this column',
    },
    { action = 'filter', lhs = 'gf', desc = 'Filter the rows with a WHERE condition' },
    { action = 'order', lhs = 'go', desc = 'Order the rows with an ORDER BY list' },
    { action = 'sort', lhs = 's', desc = 'Sort by this column: ascending, descending, off' },
    { action = 'sort_add', lhs = 'S', desc = 'Add this column to the sort' },
    { action = 'hide_column', lhs = '-', desc = 'Hide this column' },
    { action = 'show_columns', lhs = 'g-', desc = 'Show every hidden column' },
    {
      action = 'reset_view',
      lhs = 'R',
      desc = 'Clear filters, sort and hidden columns',
    },
    {
      action = 'toggle_float',
      lhs = 'Z',
      desc = 'Show the result in a float, or back in its split',
    },
    { action = 'edit_cell', lhs = { 'i', '<CR>' }, desc = 'Change this cell' },
    { action = 'set_null', lhs = 'X', desc = 'Set this cell to NULL' },
    {
      action = 'set_expression',
      lhs = 'g=',
      desc = 'Set this cell to a SQL expression, such as now()',
    },
    { action = 'add_row', lhs = 'o', desc = 'Add a row' },
    { action = 'duplicate_row', lhs = 'D', desc = 'Add a copy of this row' },
    { action = 'delete_row', lhs = 'dd', desc = 'Delete this row, or keep it after all' },
    { action = 'delete_selection', lhs = 'd', mode = 'x', desc = 'Delete the selected rows' },
    { action = 'undo', lhs = 'u', desc = 'Undo the last change' },
    { action = 'discard', lhs = 'U', desc = 'Discard every change' },
    {
      action = 'review',
      lhs = { 'gs', '<C-s>' },
      desc = 'Review the changes; <C-s> there applies them',
    },
    { action = 'help', lhs = '?', desc = 'Show these mappings' },
    { action = 'close', lhs = 'q', desc = 'Close the result window' },
  },

  -- The WHERE and ORDER BY bar above the result.
  filter = {
    { action = 'apply', lhs = '<CR>', desc = 'Filter the result with what the bar holds' },
    {
      action = 'apply',
      lhs = '<CR>',
      mode = 'i',
      desc = 'Filter the result with what the bar holds',
    },
    { action = 'close', lhs = { 'q', '<Esc>' }, desc = 'Close the bar without filtering' },
    { action = 'older', lhs = '<C-p>', desc = 'Show the filter used before this one' },
    { action = 'newer', lhs = '<C-n>', desc = 'Show the filter used after this one' },
  },

  -- A scratchpad is an ordinary editing buffer.
  editor = {
    { action = 'execute_statement', lhs = '<CR>', desc = 'Run the statement under the cursor' },
    { action = 'execute_selection', lhs = '<CR>', mode = 'x', desc = 'Run the selection' },
    { action = 'execute_buffer', lhs = '<leader>E', desc = 'Run the whole buffer' },
    { action = 'cancel', lhs = '<C-c>', desc = 'Stop the running query' },
  },
}

--- Actions that are worth a key of the user's own choosing.
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
  ['sqmeow-result-float'] = {
    desc = 'Show the result in a float, or back in its split',
    run = function()
      require('sqmeow.api').toggle_float()
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
    desc = 'Create a scratchpad',
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
---@param surface string 'drawer' or 'result'.
---@return sqmeow.ResolvedKeymap[] # In presentation order.
function M.resolve(surface)
  local overrides = (require('sqmeow.config').get().keymaps or {})[surface] or {}

  return vim.tbl_map(function(entry)
    -- Written out rather than as an `and`/`or` expression.
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

--- The first key an action is mapped to on a surface, or nil when it is unmapped.
---@param surface string
---@param action string
---@return string|nil
function M.lhs(surface, action)
  for _, entry in ipairs(M.resolve(surface)) do
    if entry.action == action and entry.lhs[1] then
      return entry.lhs[1]
    end
  end
end

--- Actions that were taken out, and what took their place.
local REMOVED = {
  yank_cell = 'yanking was replaced by exporting: `x`, or `x` on a visual selection',
  yank_row = 'yanking was replaced by exporting: `x`, or `x` on a visual selection',
  yank_page = 'yanking was replaced by exporting: `x`, or `x` on a visual selection',
}

--- Overrides that name an action the surface does not have.
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
---@param surface string
---@param buf integer
---@param actions table<string, fun()> Action name to what it does.
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
---@return string[]
function M.summary()
  local lines = {}

  for _, surface in ipairs({ 'drawer', 'result', 'filter', 'editor' }) do
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
