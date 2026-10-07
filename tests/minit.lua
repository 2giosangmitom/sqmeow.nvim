#!/usr/bin/env -S nvim -l
-- Runtime for the test suite and the help file, with its plugins installed by lazy.nvim's minit
vim.env.LAZY_STDPATH = '.tests'
load(
  vim.fn.system(
    'curl -fsSL --proto "=https" https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua'
  )
)()

require('lazy.minit').setup({
  spec = {
    -- The plugin itself.
    { dir = vim.uv.cwd() },
    -- The test harness and the documentation generator.
    'nvim-mini/mini.nvim',
    -- The drawer, the grid, the row detail, the help float and the connection dialog.
    'MunifTanjim/nui.nvim',
    -- The SQL parser for completion tests; master supports Neovim 0.10+.
    { 'nvim-treesitter/nvim-treesitter', branch = 'master' },
  },
})

vim.opt.swapfile = false
vim.opt.more = false
-- The keymap table names `<leader>E`, and the help file should say what it will actually be.
vim.g.mapleader = ' '

if vim.tbl_contains(vim.v.argv, '--docs') then
  require('mini.doc').generate()
  return
end

-- The completion tests exercise Neovim's real SQL Tree-sitter parser.
require('nvim-treesitter.configs').setup({ ensure_installed = { 'sql' }, sync_install = true })

-- Everything the plugin writes lives under `core.path`.
vim.fn.delete(require('sqmeow.core.paths').root(), 'rf')

local MiniTest = require('mini.test')
MiniTest.setup()
MiniTest.run()

-- `nvim -l` exits when this file returns, but mini.test runs its cases from the event loop.
vim.wait(2 ^ 31 - 1, function()
  return false
end)
