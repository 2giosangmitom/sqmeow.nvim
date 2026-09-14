--- sqmeow.nvim, a database client for Neovim.
---@tag sqmeow.nvim
---@toc_entry Introduction

--- Contents ~
---@toc

--- Making a connection ~
---
--- `:Sqmeow add` (or `A` in the drawer) opens a dialog that builds the URL from named fields; `e`
--- in the drawer edits the connection under the cursor. `Connection string` takes a whole URL,
--- such as one holding `{{ env "PGPASSWORD" }}`. The dialog needs nui.nvim: >lua
---   { 'sqmeow.nvim', dependencies = { 'MunifTanjim/nui.nvim' } }
--- <
--- Leave the database empty to reach every database on the server. In PostgreSQL, `<CR>` on one
--- opens it as its own connection, `connection/database`.
---@tag sqmeow-connecting
---@toc_entry Making a connection

--- Which database a query runs on ~
---@tag sqmeow-active
---@toc_entry Which database a query runs on

--- The query log ~
---@tag sqmeow-history
---@toc_entry The query log

local M = {}

--- The configuration the user passed, kept unmerged for `:checkhealth`.
---@type table|nil
M.user_config = nil

--- Configure the plugin. Optional; a partial table overrides only what it names.
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
    require('sqmeow.utils').notify(err, vim.log.levels.ERROR)
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

--- Install the engine binary. Nothing installs it automatically; call it from a build hook: >lua
---   {
---     '2giosangmitom/sqmeow.nvim',
---     dependencies = { 'MunifTanjim/nui.nvim' },
---     build = function()
---       require('sqmeow').install()
---     end,
---     opts = {},
---   }
--- <
--- Without a method it downloads a release, falling back to a cargo build. Methods are `'cargo'`,
--- `'curl'`, `'wget'` and `'powershell'`: >lua
---   require('sqmeow').install('cargo')
---   require('sqmeow').install('wget')
---   require('sqmeow').install({ version = '1.0.2' })
--- <
--- Blocks until done unless a `callback` is given.
---@param opts string|table|nil A method name, or a table of `method`, `version`, `callback` and
---  `timeout` in milliseconds.
---@return boolean|nil ok Whether an engine was installed, or nil when a `callback` was given.
---@return string|nil err
function M.install(opts)
  return require('sqmeow.install').install(opts)
end

--- Stop the engine. It restarts on the next call that needs it.
function M.stop()
  require('sqmeow.rpc').stop()
end

return M
