#!/usr/bin/env -S nvim -l
-- Runtime for the test suite and the help file, with its plugins installed by lazy.nvim's minit:
--   nvim -l tests/minit.lua          run the suite with mini.test
--   nvim -l tests/minit.lua --docs   regenerate doc/sqmeow.txt with mini.doc
--
-- Plugins are kept under `.tests`, so they are fetched once rather than on every run. minit also
-- updates them on every run; set LAZY_OFFLINE=1 to skip that.
vim.env.LAZY_STDPATH = '.tests'
load(vim.fn.system('curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua'))()

require('lazy.minit').setup({
  spec = {
    -- The plugin itself. The help file inlines the default configuration and the keymap table by
    -- evaluating them, so generating it loads the real modules too.
    { dir = vim.uv.cwd() },
    -- The test harness and the documentation generator.
    'nvim-mini/mini.nvim',
    -- The drawer, the grid, the row detail, the help float and the connection dialog.
    'MunifTanjim/nui.nvim',
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

-- Everything the plugin writes lives under `core.path`, which minit has pointed inside `.tests`.
-- Emptied first, so a run never inherits scratchpads, connections or a query log from the last one.
vim.fn.delete(require('sqmeow.paths').root(), 'rf')

local MiniTest = require('mini.test')
MiniTest.setup()
MiniTest.run()

-- `nvim -l` exits when this file returns, but mini.test runs its cases from the event loop. Its
-- reporter quits with the result once the last case is done, so wait for that.
vim.wait(2 ^ 31 - 1, function()
  return false
end)
