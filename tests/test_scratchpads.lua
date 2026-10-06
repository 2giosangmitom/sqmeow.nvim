local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local config = require('sqmeow.config')
local editor = require('sqmeow.ui.editor')
local state = require('sqmeow.core.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.apply({ core = { path = vim.fn.tempname() } })
      vim.fn.mkdir(editor.directory(), 'p')
    end,
    post_case = function()
      state.reset()
      vim.cmd('silent! %bwipeout!')
      vim.fn.delete(require('sqmeow.core.paths').root(), 'rf')
      config.apply({})
    end,
  },
})

T['creates and lists nested query files without binding a connection'] = function()
  for _, name in ipairs({ 'reports/monthly.sql', 'cache.redis', 'docs.json' }) do
    local buf = assert(editor.create(name))
    eq(vim.fn.readfile(editor.path(name)), {})
    eq(vim.bo[buf].filetype, vim.fn.fnamemodify(name, ':e'))
    eq(vim.b[buf].sqmeow_connection, nil)
  end
  eq(#editor.list(), 3)
  eq(editor.folders(), { 'reports' })
  eq(editor.create('  '), nil)
  editor.create('empty/')
  eq(editor.folders(), { 'empty', 'reports' })
  eq(#editor.list(), 3)
end

T['renames query files and folders while carrying their open buffers'] = function()
  local buf = assert(editor.create('reports/monthly.sql'))
  local path = editor.path('reports/monthly.sql')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'select 42' })
  vim.cmd.write()
  local renamed = assert(editor.rename(path, 'reports/yearly.sql'))
  eq(vim.uv.fs_stat(path), nil)
  eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), renamed)
  eq(vim.fn.readfile(renamed), { 'select 42' })
  local folder = assert(editor.rename_dir(vim.fs.dirname(renamed), 'archive/2026'))
  eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), vim.fs.joinpath(folder, 'yearly.sql'))
  eq(vim.fn.readfile(vim.api.nvim_buf_get_name(buf)), { 'select 42' })
end

T['refuses rename collisions without changing either query file'] = function()
  editor.create('before.sql')
  editor.create('taken.sql')
  local path = editor.path('before.sql')
  eq(editor.rename(path, 'taken.sql'), nil)
  eq(vim.uv.fs_stat(path) ~= nil, true)
  eq(editor.rename(path, 'before.sql'), vim.fs.normalize(path))
end

T['deleting query files and folders unloads buffers so writes cannot restore them'] = function()
  local buf = assert(editor.create('first.sql'))
  local path = editor.path('first.sql')
  eq(editor.remove(path), true)
  eq(vim.uv.fs_stat(path), nil)
  eq(vim.api.nvim_buf_is_valid(buf), false)
  buf = assert(editor.create('reports/nested/query.sql'))
  eq(editor.remove_dir(vim.fs.joinpath(editor.directory(), 'reports')), true)
  eq(vim.api.nvim_buf_is_valid(buf), false)
  eq(editor.list(), {})
end

T['path traversal stays inside the query directory and outside files cannot be changed'] = function()
  eq(editor.path('../../evil.sql'), vim.fs.joinpath(editor.directory(), 'evil.sql'))
  editor.create('before.sql')
  local renamed = assert(editor.rename(editor.path('before.sql'), '../../escaped.sql'))
  eq(vim.fs.dirname(renamed), vim.fs.normalize(editor.directory()))
  local outside = helpers.temp_file({ 'important' })
  eq(editor.rename(outside, 'mine.sql'), nil)
  eq(editor.remove(outside), false)
  eq(editor.remove_dir(vim.fs.dirname(outside)), false)
  eq(vim.fn.readfile(outside), { 'important' })
  eq(editor.rename_dir(editor.directory(), 'archive'), nil)
  eq(editor.remove_dir(editor.directory()), false)
end

T['symlinks cannot redirect creation rename or deletion outside the query directory'] = function()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, 'p')
  helpers.writefile(vim.fs.joinpath(outside, 'kept.sql'), { 'important' })
  MiniTest.finally(function()
    vim.fn.delete(outside, 'rf')
  end)
  local link = vim.fs.joinpath(editor.directory(), 'link')
  assert(vim.uv.fs_symlink(outside, link))
  eq(editor.create('link/query.sql'), nil)
  eq(editor.create('link/folder/'), nil)
  editor.create('before.sql')
  eq(editor.rename(editor.path('before.sql'), 'link/moved.sql'), nil)
  eq(editor.rename_dir(link, 'archive'), nil)
  eq(editor.remove_dir(link), false)
  eq(vim.fn.readfile(vim.fs.joinpath(outside, 'kept.sql')), { 'important' })
  eq(vim.uv.fs_stat(vim.fs.joinpath(outside, 'query.sql')), nil)
  eq(vim.uv.fs_stat(vim.fs.joinpath(outside, 'folder')), nil)
  eq(vim.uv.fs_stat(vim.fs.joinpath(outside, 'moved.sql')), nil)
end

T['query log retains newest calls up to its limit'] = function()
  config.apply({ query = { history_size = 2 } })
  for id = 1, 5 do
    state.record_call({ call_id = id, state = 'done', rows = 0 })
  end
  eq(#state.calls, 2)
  eq(state.calls[1].call_id, 5)
  eq(state.calls[2].call_id, 4)
end

return T
