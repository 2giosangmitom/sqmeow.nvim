--- sqmeow.nvim, a database client for Neovim.
---
--- A Lua frontend over a Rust engine. The engine connects to databases, runs queries and holds
--- their results; the plugin asks it for rows a page at a time and draws everything itself: the
--- drawer, the grid, windows, buffers and keymaps.
---
---@tag sqmeow.nvim
---@toc_entry Introduction

--- Contents ~
---@toc

--- Making a connection ~
---
--- `:Sqmeow add` opens a dialog: a menu of the databases the engine speaks, and then a form of
--- named fields. The URL is assembled from the answers, so a password holding a `#` needs no
--- escaping and nobody has to remember where the colon goes. A password is drawn as asterisks
--- both while it is typed and afterwards.
---
--- The same dialog is on `A` in the drawer, and `e` there opens the connection under the cursor
--- for editing. A saved URL is taken apart into the same fields, so what opens is the connection
--- as it stands.
---
--- The dialog is built on nui.nvim, which is the plugin's one optional dependency.
---
--- The first thing it asks for is a name, and it suggests nothing: the name is what the drawer
--- will call this database from now on, so it is yours to choose. The URL is never shown. >lua
---   { 'sqmeow.nvim', dependencies = { 'MunifTanjim/nui.nvim' } }
--- <
---@tag sqmeow-connecting
---@toc_entry Making a connection

--- Which database a query runs on ~
---
--- One connection is active, and it is the one whose name is highlighted in the drawer. `u` in the
--- drawer makes the connection under the cursor active, and `:Sqmeow use [name]` does the same
--- from the command line. `<CR>` only opens a row out, so reading a schema never changes where the
--- next query goes.
---
--- A scratchpad overrides that. It is created for one database, with `a` on that connection in the
--- drawer or `:Sqmeow scratch [name]`, and kept in a folder named after it, so it runs there
--- whatever else is active, and the line above it says which database that is. Two scratchpads
--- side by side therefore reach two databases without anything being switched between them. One
--- for Redis is a `.redis` file rather than a `.sql` one, and opens with that filetype.
---
--- `:Sqmeow bind <name>` ties any other buffer to a connection the same way, and `:Sqmeow bind
--- none` unties it. A buffer tied to a database that is not open refuses to run rather than
--- falling back to the active one, because running `staging.sql` against production is the mistake
--- worth being loud about.
---@tag sqmeow-active
---@toc_entry Which database a query runs on

--- The query log ~
---
--- Every query you submit is written to a log under `core.path`, together with the rows it
--- returned, so both are still there after a restart. Only what you ran is recorded: a preview from
--- the drawer, and everything the plugin asks the database for itself, stays out of it.
---
--- The drawer shows the most recent under `history`, and `:Sqmeow log` opens that section.
--- Choosing one shows the result that query returned, not the statement to run again. Nothing is
--- run, because a log holds deletes as readily as selects and picking a line out of a list is not
--- the same as asking for it to happen again. A result from this session comes from the engine's
--- memory, and an older one is read back from the copy saved with the log, with the winbar saying
--- how long ago it ran. A query that failed shows its error.
---
--- Every run is an entry of its own, because two runs of the same select can answer differently.
---
--- `:Sqmeow log clear` empties the log and deletes the saved results, and so does `d` on the
--- section in the drawer. Saved results are readable by their owner only. Set
--- `query.persist_history` to false to keep the log and its results to the session.
---@tag sqmeow-history
---@toc_entry The query log

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

--- Install the engine binary.
---
--- Nothing installs it on its own, so this is the call to put in a plugin manager's build hook,
--- where fetching several megabytes happens at a moment you chose: >lua
---   {
---     '2giosangmitom/sqmeow.nvim',
---     dependencies = { 'MunifTanjim/nui.nvim' },
---     build = function()
---       require('sqmeow').install()
---     end,
---     opts = {},
---   }
--- <
--- With no argument it works out how to install on its own: a release build is downloaded with
--- whichever tool the machine has, and cargo compiles the checkout if there is no release for this
--- target or the download fails. Name a method to decide instead. `'cargo'` is how to run a commit
--- that has not been released; `'curl'`, `'wget'` and `'powershell'` each name a download tool, for
--- a machine where the detected one does not work: >lua
---   require('sqmeow').install('cargo')
---   require('sqmeow').install('wget')
---   require('sqmeow').install({ version = '1.0.2' })
--- <
--- Both ways put the engine in the same place, so switching between them replaces what was there
--- rather than leaving two builds behind.
---
--- Waits until the install is over, because a build hook that returned early would have the plugin
--- manager report success over an engine that is not there yet. Pass a `callback` to be handed the
--- result instead and not wait, which is what `:Sqmeow install` does from inside a session. The
--- waiting uses |vim.wait()|, so the editor still redraws and the progress line still moves.
---
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
