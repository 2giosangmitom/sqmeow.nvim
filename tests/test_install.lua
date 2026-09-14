local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local install = require('sqmeow.install')
local config = require('sqmeow.config')
local paths = require('sqmeow.paths')
local rpc = require('sqmeow.rpc')

--- Swallow notifications for the rest of the case.
local function silence()
  helpers.stub(vim, 'notify', function() end)
end

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
  helpers.contains(install.manifest_url(), '/v' .. rpc.version .. '/')
end

T['checksum'] = MiniTest.new_set()

T['checksum']['is the SHA-256 of the file contents'] = function()
  local path = helpers.temp_file({ 'sqmeow' })

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
  eq(assert(path, 'the checkout build should be found'):find('target/', 1, true) ~= nil, true)
end

T['managed_path'] = MiniTest.new_set()

T['managed_path']['is under core.path, not the plugin'] = function()
  local path = install.managed_path()
  eq(vim.fs.dirname(path), paths.bin())
  eq(vim.fs.basename(path), install.binary)
end

T['download'] = MiniTest.new_set()

T['download']['answers through the callback instead of waiting'] = function()
  helpers.stub(install, 'fetch', function(_, _, _, callback)
    -- Answering later is what a real download does, and is the whole point of the callback.
    vim.defer_fn(function()
      callback(false, 'no network')
    end, 10)
  end)

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
  silence()

  local downloaded = false
  helpers.stub(install, 'download', function(_, callback)
    downloaded = true
    callback(nil, 'should not have been asked')
  end)
  helpers.stub(install, 'build', function(callback)
    callback('/somewhere/sqmeow-core')
  end)

  local ok, err = install.install('cargo')
  eq(ok, true)
  eq(err, nil)
  -- Naming a method decides it. Falling back to a download would install something other than the
  -- commit the user asked to build.
  eq(downloaded, false)
end

T['install']['falls back to cargo only when no method was named'] = function()
  silence()

  local built = false
  helpers.stub(install, 'download', function(_, callback)
    callback(nil, 'no release for this target')
  end)
  helpers.stub(install, 'build', function(callback)
    built = true
    callback('/somewhere/sqmeow-core')
  end)

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
  silence()

  local ok, err = install.install('bitsadmin')
  eq(ok, false)
  helpers.contains(assert(err, 'there should be an error'), 'bitsadmin')
  -- The message lists what it does take, since the point of naming one is that detection was wrong.
  helpers.contains(assert(err, 'there should be an error'), 'cargo')
end

T['install']['answers through a callback without waiting'] = function()
  silence()

  local release
  helpers.stub(install, 'download', function(_, callback)
    release = callback
  end)

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
  silence()

  local nested, release
  helpers.stub(install, 'download', function(_, callback)
    install.install({
      callback = function(_, e)
        nested = e
      end,
    })
    release = function()
      callback(nil, 'the download failed')
    end
  end)
  helpers.stub(install, 'build', function(callback)
    callback(nil, 'no cargo')
  end)

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
  silence()

  -- A download that never answers, which is what a hung connection looks like from here.
  helpers.stub(install, 'download', function() end)

  local ok, err = install.install({ timeout = 50 })
  eq(ok, false)
  helpers.contains(assert(err, 'there should be an error'), 'timed out')
  -- The guard must come back down, or a timeout would cost the user their session: every later
  -- install would be turned away as a duplicate of one that is never going to finish.
  eq(install.installing(), nil)
end

T['installing'] = MiniTest.new_set()

T['installing']['names the step, so a caller can say what is holding it up'] = function()
  silence()
  eq(install.installing(), nil)

  local release
  helpers.stub(install, 'download', function(_, callback)
    release = callback
  end)

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
