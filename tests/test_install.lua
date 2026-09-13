local eq = MiniTest.expect.equality
local install = require('sqmeow.install')

local T = MiniTest.new_set()

T['triple'] = MiniTest.new_set()

T['triple']['names this machine the way rustc does'] = function()
  local triple = assert(install.triple())
  eq(triple:find('%-') ~= nil, true)

  local architecture, system = triple:match('^([^%-]+)%-(.+)$')
  eq(vim.tbl_contains({ 'x86_64', 'aarch64' }, architecture), true)
  -- These are the systems the release workflow builds for, and the manifest is keyed by them.
  -- Linux is musl, not gnu: asking for gnu matches nothing and sends every Linux user to a build.
  eq(vim.tbl_contains({ 'unknown-linux-musl', 'apple-darwin', 'pc-windows-msvc' }, system), true)
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

T['resolve']['finds the engine installed under core.path'] = function()
  local config = require('sqmeow.config')
  local root = vim.fn.tempname()
  config.apply({ core = { path = root } })
  MiniTest.finally(function()
    config.apply({})
    vim.fn.delete(root, 'rf')
  end)

  local managed = install.managed_path()
  eq(managed, vim.fs.joinpath(root, 'bin', install.binary))

  vim.fn.mkdir(vim.fs.dirname(managed), 'p')
  vim.fn.writefile({}, managed)

  local path, source = install.resolve()
  eq(path, managed)
  eq(source, 'managed')
end

T['resolve']['finds the checkout build, so a clone needs no install step'] = function()
  local path, source = install.resolve()
  eq(source, 'dev')
  eq(path:find('target/', 1, true) ~= nil, true)
end

T['managed_path'] = MiniTest.new_set()

T['managed_path']['is under core.path, not the plugin'] = function()
  local path = install.managed_path()
  eq(vim.fs.dirname(path), require('sqmeow.paths').bin())
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

T['install'] = MiniTest.new_set()

T['install']['builds with cargo when asked for it'] = function()
  local build, download, notify = install.build, install.download, vim.notify
  MiniTest.finally(function()
    install.build, install.download, vim.notify = build, download, notify
  end)
  vim.notify = function() end

  local downloaded = false
  install.download = function(_, callback)
    downloaded = true
    callback(nil, 'should not have been asked')
  end
  install.build = function(callback)
    callback('/somewhere/sqmeow-core')
  end

  local ok, err = install.install('cargo')
  eq(ok, true)
  eq(err, nil)
  -- Naming a method decides it. Falling back to a download would install something other than the
  -- commit the user asked to build.
  eq(downloaded, false)
end

T['install']['falls back to cargo only when no method was named'] = function()
  local build, download, notify = install.build, install.download, vim.notify
  MiniTest.finally(function()
    install.build, install.download, vim.notify = build, download, notify
  end)
  vim.notify = function() end

  local built = false
  install.download = function(_, callback)
    callback(nil, 'no release for this target')
  end
  install.build = function(callback)
    built = true
    callback('/somewhere/sqmeow-core')
  end

  eq(install.install(), true)
  eq(built, true)

  -- A named download tool is not quietly turned into a build: the caller asked for that tool.
  built = false
  local ok, err = install.install('wget')
  eq(ok, false)
  eq(err, 'no release for this target')
  eq(built, false)
end

T['install']['refuses a method it does not have'] = function()
  local notify = vim.notify
  MiniTest.finally(function()
    vim.notify = notify
  end)
  vim.notify = function() end

  local ok, err = install.install('bitsadmin')
  eq(ok, false)
  eq(err:find('bitsadmin', 1, true) ~= nil, true)
  -- The message lists what it does take, since the point of naming one is that detection was wrong.
  eq(err:find('cargo', 1, true) ~= nil, true)
end

T['install']['answers through a callback without waiting'] = function()
  local download, notify = install.download, vim.notify
  MiniTest.finally(function()
    install.download, vim.notify = download, notify
  end)
  vim.notify = function() end

  local release
  install.download = function(_, callback)
    release = callback
  end

  local answered
  local returned = install.install({
    callback = function(path)
      answered = path
    end,
  })

  -- Still running: a callback means the caller is not waiting, so there is nothing to report yet.
  eq(returned, nil)
  eq(answered, nil)
  eq(install.installing(), 'downloading')

  release('/somewhere/sqmeow-core')
  eq(answered, '/somewhere/sqmeow-core')
  eq(install.installing(), nil)
end

T['install']['turns away a second install while one is running'] = function()
  local download, build, notify = install.download, install.build, vim.notify
  MiniTest.finally(function()
    install.download, install.build, vim.notify = download, build, notify
  end)
  vim.notify = function() end

  local nested, release
  install.download = function(_, callback)
    install.install({
      callback = function(_, e)
        nested = e
      end,
    })
    release = function()
      callback(nil, 'the download failed')
    end
  end
  install.build = function(callback)
    callback(nil, 'no cargo')
  end

  local err
  install.install({
    callback = function(_, e)
      err = e
    end,
  })

  eq(nested, 'an engine is already being installed (downloading)')
  release()
  eq(err, 'the download failed; no cargo')

  -- The flag has to come back down, or nothing could be installed again without a restart.
  eq(install.installing(), nil)
end

T['install']['gives up rather than waiting for ever'] = function()
  local download, notify = install.download, vim.notify
  MiniTest.finally(function()
    install.download, vim.notify = download, notify
  end)
  vim.notify = function() end

  -- A download that never answers, which is what a hung connection looks like from here.
  install.download = function() end

  local ok, err = install.install({ timeout = 50 })
  eq(ok, false)
  eq(err:find('timed out', 1, true) ~= nil, true)
  -- The guard must come back down, or a timeout would cost the user their session: every later
  -- install would be turned away as a duplicate of one that is never going to finish.
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

  install.install({ callback = function() end })
  eq(install.installing(), 'downloading')
  release('/somewhere/sqmeow-core')
  eq(install.installing(), nil)
end

T['methods'] = MiniTest.new_set()

T['methods']['names cargo, so the latest commit can be run'] = function()
  eq(vim.tbl_contains(install.methods, 'cargo'), true)
end

return T
