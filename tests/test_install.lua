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

T['download'] = MiniTest.new_set()

T['download']['answers through the callback instead of waiting'] = function()
  local fetch = install.fetch
  MiniTest.finally(function()
    install.fetch = fetch
  end)

  install.fetch = function(_, _, _, callback)
    -- Answering later is what a real download does, and is the whole point of the callback.
    vim.defer_fn(function()
      callback(false, 'no network')
    end, 10)
  end

  local answered, path, err = false, nil, nil
  install.download(nil, function(p, e)
    answered, path, err = true, p, e
  end)

  -- Nothing has been decided yet, which is what makes the editor usable while it runs.
  eq(answered, false)

  vim.wait(1000, function()
    return answered
  end)
  eq(path, nil)
  eq(err, 'no network')
end

T['ensure'] = MiniTest.new_set()

T['ensure']['answers at once when an engine is already there'] = function()
  local answered
  install.ensure({}, function(path)
    answered = path
  end)

  -- The checkout build is found by `resolve`, so nothing is fetched.
  eq(type(answered), 'string')
  eq(answered:find('target/', 1, true) ~= nil, true)
end

T['ensure']['turns away a second install while one is running'] = function()
  local download, build, notify = install.download, install.build, vim.notify
  MiniTest.finally(function()
    install.download, install.build, vim.notify = download, build, notify
  end)

  vim.notify = function() end

  local nested, release
  install.download = function(_, callback)
    install.ensure({ force = true }, function(_, e)
      nested = e
    end)
    release = function()
      callback(nil, 'the download failed')
    end
  end
  install.build = function(callback)
    callback(nil, 'no cargo')
  end

  local err
  install.ensure({ force = true }, function(_, e)
    err = e
  end)

  eq(nested, 'an engine is already being installed (starting)')
  release()
  eq(err, 'the download failed; no cargo')

  -- The flag has to come back down, or nothing could be installed again without a restart.
  eq(install.installing(), nil)
end

T['installing'] = MiniTest.new_set()

T['installing']['names the step, so a caller can say what is holding it up'] = function()
  local download, notify = install.download, vim.notify
  MiniTest.finally(function()
    install.download, vim.notify = download, notify
  end)

  vim.notify = function() end
  eq(install.installing(), nil)

  local release
  install.download = function(_, callback)
    release = callback
  end

  install.ensure({ force = true }, function() end)
  eq(install.installing(), 'starting')
  release('/somewhere/sqmeow-core')
  eq(install.installing(), nil)
end

return T
