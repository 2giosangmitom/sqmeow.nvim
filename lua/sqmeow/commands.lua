--- The `:Sqmeow` command.
---
--- Subcommand implementations live in `sqmeow.commands.*` grouped by domain.
--- This file only merges those tables into one registry and dispatches.

local M = {}

local notify = require('sqmeow.core.utils').notify

---@class sqmeow.Subcommand
---@field desc string Shown in completion and in the help file.
---@field run fun(args: string[], opts: table)
---@field complete nil|fun(lead: string): string[]

--- Subcommands, merged from the domain modules above.
---@type table<string, sqmeow.Subcommand>
M.subcommands = vim.tbl_extend(
  'error',
  require('sqmeow.commands.connection').subcommands,
  require('sqmeow.commands.query').subcommands,
  require('sqmeow.commands.view').subcommands,
  require('sqmeow.commands.engine').subcommands
)

local function run(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1)

  if not name then
    return require('sqmeow.api.view').open_all()
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
