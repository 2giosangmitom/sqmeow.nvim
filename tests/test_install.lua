local eq = MiniTest.expect.equality
local install = require('sqmeow.install')

local T = MiniTest.new_set()

T['triple'] = MiniTest.new_set()

T['triple']['names this machine the way rustc does'] = function()
  local triple = assert(install.triple())
  eq(triple:find('%-') ~= nil, true)

  local architecture, system = triple:match('^([^%-]+)%-(.+)$')
  eq(vim.tbl_contains({ 'x86_64', 'aarch64' }, architecture), true)
  eq(vim.tbl_contains({ 'unknown-linux-gnu', 'apple-darwin', 'pc-windows-msvc' }, system), true)
end

T['manifest_url'] = MiniTest.new_set()

T['manifest_url']['points at the release for a version'] = function()
  eq(
    install.manifest_url('1.2.3'),
    'https://github.com/2giosangmitom/sqmeow.nvim/releases/download/v1.2.3/manifest.json'
  )
end

T['manifest_url']['defaults to the version this plugin was built against'] = function()
  local version = require('sqmeow.rpc').version
  eq(install.manifest_url():find('/v' .. version .. '/', 1, true) ~= nil, true)
end

T['checksum'] = MiniTest.new_set()

T['checksum']['is the SHA-256 of the file contents'] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ 'sqmeow' }, path)
  MiniTest.finally(function()
    vim.fn.delete(path)
  end)

  -- `writefile` adds the trailing newline, so this is the digest of "sqmeow\n".
  eq(install.checksum(path), vim.fn.sha256('sqmeow\n'))
end

T['checksum']['says so when the file is not there'] = function()
  local digest, err = install.checksum('/nonexistent/engine.tar.gz')
  eq(digest, nil)
  eq(type(err), 'string')
end

T['resolve'] = MiniTest.new_set()

T['resolve']['prefers the configured path over everything else'] = function()
  local config = require('sqmeow.config')
  config.apply({ core = { path = '/opt/sqmeow-core' } })
  MiniTest.finally(function()
    config.apply({})
  end)

  local path, source = install.resolve()
  eq(path, '/opt/sqmeow-core')
  eq(source, 'config')
end

T['resolve']['finds the checkout build, so a clone needs no install step'] = function()
  local path, source = install.resolve()
  eq(source, 'dev')
  eq(path:find('target/', 1, true) ~= nil, true)
end

T['managed_path'] = MiniTest.new_set()

T['managed_path']['is under the data directory, not the plugin'] = function()
  local path = install.managed_path()
  eq(path:find(vim.fn.stdpath('data'), 1, true), 1)
  eq(vim.fs.basename(path), install.binary)
end

return T
