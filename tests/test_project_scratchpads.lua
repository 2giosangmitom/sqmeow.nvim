local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local editor = require('sqmeow.ui.editor')
local paths = require('sqmeow.core.paths')
local root
local cwd

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      root = vim.fn.tempname()
      cwd = vim.fn.getcwd()
      vim.fn.mkdir(vim.fs.joinpath(root, 'project', '.sqmeow'), 'p')
      vim.fn.mkdir(vim.fs.joinpath(root, 'project', 'src'), 'p')
      vim.cmd.lcd(root)
    end,
    post_case = function()
      vim.cmd.lcd(cwd)
      vim.fn.delete(root, 'rf')
    end,
  },
})

T['no project returns no query store and creates nothing'] = function()
  eq(editor.project(), nil)
  eq(vim.uv.fs_stat(vim.fs.joinpath(root, '.sqmeow')), nil)
end

T['discovers ancestors without a connections file and respects directory changes'] = function()
  vim.cmd.lcd(vim.fs.joinpath(root, 'project', 'src'))
  local project = assert(editor.project())
  eq(paths.project(), vim.fs.joinpath(root, 'project', '.sqmeow'))
  eq(project.directory(), vim.fs.joinpath(root, 'project', '.sqmeow', 'scratchpads'))
  eq(project.list(), {})
  eq(vim.uv.fs_stat(project.directory()), nil)

  vim.fn.mkdir(vim.fs.joinpath(root, 'project', 'src', '.sqmeow'), 'p')
  eq(
    assert(editor.project()).directory(),
    vim.fs.joinpath(root, 'project', 'src', '.sqmeow', 'scratchpads')
  )
  -- Existing operations remain tied to their original project, including pending prompts.
  eq(project.directory(), vim.fs.joinpath(root, 'project', '.sqmeow', 'scratchpads'))
  vim.cmd.lcd(root)
  eq(editor.project(), nil)
end

T['lists nested supported files and empty groups without touching global scratchpads'] = function()
  vim.cmd.lcd(vim.fs.joinpath(root, 'project'))
  local project = assert(editor.project())
  local buf, err = project.create('reports/2026/')
  eq(buf, nil)
  eq(err, nil)
  eq(project.folders(), { 'reports', 'reports/2026' })
  for _, name in ipairs({ 'a.sql', 'reports/b.redis', 'reports/c.json', 'reports/2026/d.surql' }) do
    vim.fn.writefile({}, project.path(name))
  end
  vim.fn.writefile({}, project.path('ignored.txt'))
  eq(#project.list(), 4)
  eq(project.relative(project.path('reports/b.redis')), 'reports/b.redis')
  eq(project.path('../outside.sql'), vim.fs.joinpath(project.directory(), 'outside.sql'))
  local renamed = project.rename_dir(project.path('reports'), 'archive')
  eq(renamed, project.path('archive'))
  eq(project.remove_dir(project.path('archive')), true)
  eq(project.remove(editor.path('a.sql')), false)
end

T['refuses writes and folder operations through symlinks'] = function()
  vim.cmd.lcd(vim.fs.joinpath(root, 'project'))
  local project = assert(editor.project())
  project.create('reports/')
  vim.fn.mkdir(vim.fs.joinpath(root, 'outside'))
  assert(vim.uv.fs_symlink(vim.fs.joinpath(root, 'outside'), project.path('linked')))
  local buf, err = project.create('linked/query.sql')
  eq(buf, nil)
  eq(type(err), 'string')
  eq(project.rename_dir(project.path('reports'), 'linked/reports'), nil)
  eq(project.remove_dir(project.path('linked')), false)
  eq(vim.uv.fs_stat(vim.fs.joinpath(root, 'outside', 'query.sql')), nil)
end

return T
