local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = require('tests.helpers')
local install = require('sqmeow.server.install')

local T = MiniTest.new_set()

T['archive_url points at the requested release and target'] = function()
  for _, target in ipairs({
    { 'x86_64-unknown-linux-musl', 'tar.gz' },
    { 'aarch64-apple-darwin', 'tar.gz' },
    { 'x86_64-pc-windows-msvc', 'zip' },
  }) do
    eq(
      install.archive_url('1.2.3', target[1]),
      ('https://github.com/2giosangmitom/sqmeow.nvim/releases/download/v1.2.3/sqmeow-core-%s.%s'):format(
        target[1],
        target[2]
      )
    )
  end
end

T['install_binary replaces an existing binary and leaves no temporary file'] = function()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, 'p')
  MiniTest.finally(function()
    vim.fn.delete(directory, 'rf')
  end)

  local source = helpers.temp_file({ 'the new build' })
  local destination = vim.fs.joinpath(directory, install.binary)
  helpers.writefile(destination, { 'the old build' })

  local ok, err = install.install_binary(source, destination)
  eq(ok, true)
  eq(err, nil)
  eq(vim.fn.readfile(destination), { 'the new build' })
  eq(vim.fn.glob(destination .. '.new.*'), '')
end

T['install_binary replaces a binary that is still running'] = function()
  -- Writing through a running executable is a Linux behavior; elsewhere there is nothing
  -- to reproduce.
  if vim.fn.has('linux') ~= 1 then
    return
  end
  local sleep = vim.fn.exepath('sleep')
  if sleep == '' then
    return
  end

  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, 'p')
  local source = helpers.temp_file({ 'the new build' })
  local destination = vim.fs.joinpath(directory, 'busy')
  if not vim.uv.fs_copyfile(sleep, destination) then
    vim.fn.delete(directory, 'rf')
    return
  end
  vim.uv.fs_chmod(destination, 493)

  local process = vim.system({ destination, '30' }, { text = true })
  MiniTest.finally(function()
    pcall(function()
      process:kill(15)
    end)
    vim.fn.delete(directory, 'rf')
  end)

  -- Wait for exec, not merely for the child to exist.
  local running = vim.wait(2000, function()
    return vim.uv.fs_readlink('/proc/' .. process.pid .. '/exe') == destination
  end, 10)
  if not running then
    return
  end

  local direct, direct_err = vim.uv.fs_copyfile(source, destination)
  eq(direct, nil)
  eq(direct_err and direct_err:match('^ETXTBSY'), 'ETXTBSY')

  local ok, err = install.install_binary(source, destination)
  eq(ok, true)
  eq(err, nil)
  eq(vim.fn.readfile(destination), { 'the new build' })
end

return T
