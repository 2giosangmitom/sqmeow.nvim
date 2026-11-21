-- Headless Neovim for the Node integration suite: the plugin from this checkout, an isolated data
-- directory, and the blocking helpers in `helpers.lua` as the module `integration`.
--
-- `nvim.mjs` starts Neovim with `--clean -u` this file and its working directory set to the data
-- directory, so no user config, project source or earlier run leaks in.

local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local root = vim.fs.normalize(vim.fs.joinpath(here, '..', '..'))

vim.opt.runtimepath:prepend(root)
-- The routine popup and the row detail use nui.nvim. The UI suite installs it under `.tests`;
-- cases that need it skip when it is not there.
local nui = vim.fs.joinpath(root, '.tests', 'data', 'nvim', 'lazy', 'nui.nvim')
if vim.uv.fs_stat(nui) then
  vim.opt.runtimepath:append(nui)
end

vim.opt.swapfile = false
vim.opt.more = false
vim.opt.shadafile = 'NONE'

local data = assert(vim.env.SQMEOW_IT_DATA, 'nvim.mjs sets SQMEOW_IT_DATA')

require('sqmeow').setup({
  core = { path = vim.fs.joinpath(data, 'sqmeow'), log_level = 'warn' },
  -- Nothing here reads the log back, and the archive writes would only slow the cases down.
  query = { persist_history = false, confirm_destructive = false },
})

local helpers = dofile(vim.fs.joinpath(here, 'helpers.lua'))
helpers.root = root
helpers.nui = vim.uv.fs_stat(nui) ~= nil
package.loaded.integration = helpers
