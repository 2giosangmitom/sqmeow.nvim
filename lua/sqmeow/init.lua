--- sqmeow.nvim, a database client for Neovim.
---
--- A Lua frontend over a Rust engine. The engine owns connections, queries, and the layout of
--- result grids; the plugin owns windows, buffers, and keymaps. Nothing in the plugin ever
--- touches a row of data, which is what keeps a large result from stalling the editor.
---
---@tag sqmeow.nvim
---@toc_entry Introduction

local M = {}

--- The configuration the user passed, kept unmerged for `:checkhealth`.
---@type table|nil
M.user_config = nil

--- Configure the plugin.
---
--- Optional. Every option has a default, and a partial table overrides only what it names.
---
---@param opts table|nil See |sqmeow-config|.
---@usage >lua
---   require('sqmeow').setup({
---     ui = { drawer = { width = 40 } },
---   })
--- <
function M.setup(opts)
  M.user_config = opts or {}

  local _, errors = require('sqmeow.config').apply(M.user_config)
  for _, err in ipairs(errors) do
    vim.notify('sqmeow: ' .. err, vim.log.levels.ERROR)
  end

  require('sqmeow.ui.highlights').setup()

  -- A colourscheme change wipes every group, including ours.
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('sqmeow.highlights', { clear = true }),
    desc = 'Redefine sqmeow highlight groups',
    callback = function()
      require('sqmeow.ui.highlights').setup()
    end,
  })

  -- A running engine holds the old settings, so tell it about the new ones.
  require('sqmeow.rpc').configure()
end

--- Stop the engine. It restarts on the next call that needs it.
function M.stop()
  require('sqmeow.rpc').stop()
end

return M
