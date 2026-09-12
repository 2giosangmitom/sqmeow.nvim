-- Minimal runtime for the test suite and for repro sessions:
--   nvim --headless -u tests/minimal_init.lua
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

vim.opt.runtimepath:prepend(root)

-- mini.nvim supplies the test harness and the documentation generator, and nui.nvim is what the
-- connection dialog is built on. `just deps` clones both.
for _, plugin in ipairs({ 'mini.nvim', 'nui.nvim' }) do
  local path = vim.fs.joinpath(root, '.deps', plugin)
  if vim.uv.fs_stat(path) then
    vim.opt.runtimepath:prepend(path)
  end
end

vim.opt.swapfile = false
vim.opt.more = false
vim.g.mapleader = ' '
