-- Subcommands for one domain; required directly by sqmeow.commands.
-- No re-export.

local M = {}

local notify = require('sqmeow.core.utils').notify

--- Discard a return value.
local function void(_) end

M.subcommands = {
  float = {
    desc = 'Toggle between a floating result window and a split',
    run = function()
      require('sqmeow.api.view').toggle_float()
    end,
  },
  review = {
    desc = 'Review the changes staged in the result, and apply them',
    run = function()
      require('sqmeow.api.view').review()
    end,
  },
  scratch = {
    desc = 'Create a scratchpad',
    run = function(args)
      void(require('sqmeow.api.view').scratchpad(args[1]))
    end,
  },
  export = {
    desc = 'Export the result to a file or `clipboard`',
    run = function(args)
      if args[2] == 'clipboard' then
        return require('sqmeow.api.export').export({ format = args[1], clipboard = true })
      end
      require('sqmeow.api.export').export({ format = args[1], path = args[2] })
    end,
    complete = function(lead)
      return vim.tbl_filter(function(format)
        return format:find(lead, 1, true) == 1
      end, { 'csv', 'json', 'sql' })
    end,
  },
  toggle = {
    desc = 'Toggle the schema drawer',
    run = function()
      require('sqmeow.api.view').toggle()
    end,
  },
  drawer = {
    desc = 'Show the schema drawer',
    run = function()
      require('sqmeow.api.view').open_drawer()
    end,
  },
  open = {
    desc = 'Show the result window',
    run = function()
      require('sqmeow.api.view').open()
    end,
  },
  close = {
    desc = 'Hide the result window',
    run = function()
      require('sqmeow.api.view').close()
    end,
  },
  log = {
    desc = 'Reopen a query result, or use `clear` to erase history',
    run = function(args)
      if args[1] == 'clear' then
        require('sqmeow.server.history').clear()
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
}

return M
