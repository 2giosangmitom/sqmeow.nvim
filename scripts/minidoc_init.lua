-- Runtime for `just docs`:
--   nvim --headless -u scripts/minidoc_init.lua -c "lua require('mini.doc').generate()" -c "qa!"
--
-- The plugin itself has to be on the runtime path, not only mini.nvim: the help file inlines the
-- default configuration and the keymap table by evaluating them, so generation loads the real
-- modules rather than reading their source.
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

vim.opt.runtimepath:prepend(root)

local mini = vim.fs.joinpath(root, '.deps', 'mini.nvim')
if not vim.uv.fs_stat(mini) then
  error('mini.nvim is missing; run `just deps`')
end
vim.opt.runtimepath:prepend(mini)

vim.opt.swapfile = false
vim.opt.more = false
-- The keymap table names `<leader>E`, and the help file should say what it will actually be for
-- someone reading the defaults.
vim.g.mapleader = ' '
