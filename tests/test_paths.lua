local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local config = require('sqmeow.config')
local paths = require('sqmeow.paths')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
    end,
  },
})

T['default to a directory under the data directory'] = function()
  eq(paths.root(), vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow'))
end

T['keep every file under core.path'] = function()
  config.apply({ core = { path = '/srv/sqmeow' } })

  eq(paths.bin(), '/srv/sqmeow/bin')
  eq(paths.connections(), '/srv/sqmeow/connections.json')
  eq(paths.scratch(), '/srv/sqmeow/scratch')
  eq(paths.history(), '/srv/sqmeow/history/log.jsonl')
  eq(paths.results(), '/srv/sqmeow/history/results')
end

T['expand a home directory'] = function()
  config.apply({ core = { path = '~/sqmeow' } })
  eq(paths.root(), vim.fs.joinpath(vim.fs.normalize('~'), 'sqmeow'))
end

T['move everything that reads them'] = function()
  config.apply({ core = { path = '/srv/sqmeow' } })
  local install = require('sqmeow.install')
  local file = require('sqmeow.sources.file')
  local editor = require('sqmeow.ui.editor')
  local history = require('sqmeow.history')

  eq(install.managed_path(), '/srv/sqmeow/bin/' .. install.binary)
  eq(file.default_path(), '/srv/sqmeow/connections.json')
  eq(editor.directory(), '/srv/sqmeow/scratch')
  eq(history.path(), '/srv/sqmeow/history/log.jsonl')
end

return T
