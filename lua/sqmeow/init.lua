--- sqmeow.nvim, a database client for Neovim.
---
--- A Lua frontend over a Rust engine. The engine owns connections, queries, and the layout of
--- result grids; the plugin owns windows, buffers, and keymaps. Nothing in the plugin ever
--- touches a row of data, which is what keeps a large result from stalling the editor.
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
--- drawer makes the connection under the cursor active, `<CR>` does it as well as opening the row
--- out, and `:Sqmeow use [name]` does it from the command line.
---
--- A scratchpad overrides that. It is opened for one database and named after it, so it runs there
--- whatever else is active, and the line above it says which database that is. Two scratchpads
--- side by side therefore reach two databases without anything being switched between them.
---
--- `:Sqmeow bind <name>` ties any other buffer to a connection the same way, and `:Sqmeow bind
--- none` unties it. A buffer tied to a database that is not open refuses to run rather than
--- falling back to the active one, because running `staging.sql` against production is the mistake
--- worth being loud about.
---@tag sqmeow-active
---@toc_entry Which database a query runs on

--- The query log ~
---
--- Every finished query is written to a file of JSON lines under `stdpath('state')`, so the log is
--- still there after a restart. It holds the statement, which connection it ran on, how it went
--- and how long it took. It does not hold the rows: a cached grid goes stale as soon as the table
--- changes, and a statement you can see is cheap to run again.
---
--- The drawer shows the most recent under `history`, and `:Sqmeow log` opens that section.
--- Choosing one puts its rows back on screen when the engine still has them, which is true for
--- anything run since Neovim started. Otherwise the statement opens in a buffer of its own, ready
--- to run, because a log holds deletes as readily as selects and picking a line out of a list is
--- not the same as asking for it to happen again.
---
--- The same statement run twenty times is one line, and the line is the most recent run of it.
---
--- `:Sqmeow log clear` empties the log, and so does `d` on the section in the drawer. Set
--- `query.persist_history` to false to keep the log to the session, and `query.history_file` to
--- put it somewhere else.
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

--- Stop the engine. It restarts on the next call that needs it.
function M.stop()
  require('sqmeow.rpc').stop()
end

return M
