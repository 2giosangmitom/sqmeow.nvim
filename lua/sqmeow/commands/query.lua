-- Subcommands for one domain; required directly by sqmeow.commands.
-- No re-export.

local M = {}

local notify = require('sqmeow.core.utils').notify

--- Discard a return value.
local function void(_) end

M.subcommands = {
  execute = {
    desc = 'Run the current buffer, the selection, or the given SQL',
    run = function(args, opts)
      if #args > 0 then
        return void(require('sqmeow.api.query').execute(table.concat(args, ' ')))
      end
      if opts.range and opts.range > 0 then
        return void(require('sqmeow.api.query').execute_range(opts.line1, opts.line2))
      end
      void(require('sqmeow.api.query').execute_buffer())
    end,
  },
  statement = {
    desc = 'Run the statement the cursor is in',
    run = function()
      void(require('sqmeow.api.query').execute_statement())
    end,
  },
  cancel = {
    desc = 'Stop the running query',
    run = function()
      if not require('sqmeow.api.query').cancel() then
        notify('there is no query running')
      end
    end,
  },
  next = {
    desc = 'Show the next page of results',
    run = function()
      require('sqmeow.api.query').next_page()
    end,
  },
  prev = {
    desc = 'Show the previous page of results',
    run = function()
      require('sqmeow.api.query').prev_page()
    end,
  },
}

return M
