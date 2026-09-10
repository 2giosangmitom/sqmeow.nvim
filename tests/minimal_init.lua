-- Minimal runtime for the test suite and for repro sessions:
--   nvim --headless -u tests/minimal_init.lua
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

vim.opt.runtimepath:prepend(root)

-- mini.nvim supplies both the test harness and the documentation generator. `just deps` clones it.
local mini = vim.fs.joinpath(root, '.deps', 'mini.nvim')
if vim.uv.fs_stat(mini) then
  vim.opt.runtimepath:prepend(mini)
end

vim.opt.swapfile = false
vim.opt.more = false
vim.g.mapleader = ' '
