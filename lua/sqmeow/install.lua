--- Finding, and when asked, fetching the engine binary.

local M = {}

--- Where releases are published.
M.repository = '2giosangmitom/sqmeow.nvim'

--- Name of the engine executable on this platform.
M.binary = vim.fn.has('win32') == 1 and 'sqmeow-core.exe' or 'sqmeow-core'

--- The ways an engine can be obtained, as |sqmeow.install()| accepts them.
M.methods = { 'curl', 'wget', 'powershell', 'cargo' }

--- How long |sqmeow.install()| waits when it was given no callback, in milliseconds.
M.timeout = 10 * 60 * 1000

--- The install now running, if there is one.
---@type table|nil
local running = nil

local root = vim.fs.normalize(
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
)

local notify = require('sqmeow.utils').notify

--- Show how far the install has got, on the message line rather than in the notification history.
---@param message string|nil nil clears the line.
local function progress(message)
  if not message then
    return vim.api.nvim_echo({}, false, {})
  end
  vim.api.nvim_echo({ { 'sqmeow: ' .. message, 'MoreMsg' } }, false, {})
end

--- Start a program and answer when it is done, without waiting for it.
---@param command string[]
---@param opts table
---@param callback fun(result: table)
local function spawn(command, opts, callback)
  local ok, err = pcall(vim.system, command, opts, vim.schedule_wrap(callback))
  if not ok then
    -- `vim.system` throws when the program cannot be started at all.
    vim.schedule(function()
      callback({ code = -1, stderr = tostring(err) })
    end)
  end
end

--- Where a downloaded engine is kept.
---@return string
function M.managed_path()
  return vim.fs.joinpath(require('sqmeow.paths').bin(), M.binary)
end

--- Where `cargo build` inside the plugin puts an engine, release before debug.
---@return string|nil
function M.dev_path()
  for _, profile in ipairs({ 'release', 'debug' }) do
    local path = vim.fs.joinpath(root, 'target', profile, M.binary)
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  return nil
end

--- Find an engine to run.
---@return string|nil path Absolute path to the engine.
---@return string source One of 'managed', 'dev', or 'missing'.
function M.resolve()
  local managed = M.managed_path()
  if vim.uv.fs_stat(managed) then
    return managed, 'managed'
  end

  local dev = M.dev_path()
  if dev then
    return dev, 'dev'
  end

  return nil, 'missing'
end

--- Whether an install is under way, and what it is doing.
---@return string|nil step One of 'downloading', 'unpacking' or 'building', or nil when idle.
function M.installing()
  return running and running.step or nil
end

--- The Rust target triple for this machine.
---@return string|nil triple
---@return string|nil error
function M.triple()
  local uname = vim.uv.os_uname()
  local machine = uname.machine

  local architectures = {
    x86_64 = 'x86_64',
    amd64 = 'x86_64',
    arm64 = 'aarch64',
    aarch64 = 'aarch64',
  }
  local systems = {
    Linux = 'unknown-linux-musl',
    Darwin = 'apple-darwin',
    Windows_NT = 'pc-windows-msvc',
  }

  local architecture = architectures[machine]
  local system = systems[uname.sysname]

  if not (architecture and system) then
    return nil, ('no prebuilt engine for %s %s'):format(uname.sysname, machine)
  end
  return ('%s-%s'):format(architecture, system)
end

--- Name of the archive that holds the engine for a target.
---@param triple string Rust target triple.
---@return string
function M.archive_name(triple)
  local extension = triple:find('windows', 1, true) and '.zip' or '.tar.gz'
  return 'sqmeow-core-' .. triple .. extension
end

--- Where the archive for a release lives.
---@param version string|nil Defaults to this plugin's version.
---@param triple string Rust target triple.
---@return string
function M.archive_url(version, triple)
  return ('https://github.com/%s/releases/download/v%s/%s'):format(
    M.repository,
    version or require('sqmeow.rpc').version,
    M.archive_name(triple)
  )
end

--- Download something, with whichever tool this machine has.
---@param url string
---@param destination string
---@param opts table|nil `label` names the download in the progress line.
---@param callback fun(ok: boolean, err: string|nil)
function M.fetch(url, destination, opts, callback)
  opts = opts or {}

  -- curl draws a progress bar when its output is a file and it is not asked to be silent.
  local attempts = {
    {
      'curl',
      '--fail',
      '--location',
      '--show-error',
      opts.label and '--progress-bar' or '--silent',
      '--output',
      destination,
      url,
    },
    { 'wget', '--quiet', '--output-document', destination, url },
    {
      'powershell',
      '-NoProfile',
      '-Command',
      ("Invoke-WebRequest -Uri '%s' -OutFile '%s'"):format(url, destination),
    },
  }

  if opts.method then
    attempts = vim.tbl_filter(function(command)
      return command[1] == opts.method
    end, attempts)
  end

  local index = 0
  local last = opts.method and ('%s is not installed'):format(opts.method)
    or 'no download tool was found; install curl or wget'

  local function attempt()
    index = index + 1
    local command = attempts[index]
    if not command then
      return callback(false, last)
    end
    if vim.fn.executable(command[1]) ~= 1 then
      return attempt()
    end

    -- Reading stderr as it arrives is what turns curl's bar into a percentage.
    local tail = {}

    -- curl redraws its bar by returning to the start of the line.
    local carry = ''
    local function on_stderr(_, data)
      if not data then
        return
      end
      table.insert(tail, data)
      if #tail > 4 then
        table.remove(tail, 1)
      end
      if not opts.label then
        return
      end

      carry = carry .. data
      local latest
      for bar in carry:gmatch('([^\r\n]*)[\r\n]') do
        latest = bar:match('(%d+%.%d)%%%s*$') or latest
      end
      carry = carry:match('[^\r\n]*$') or ''

      if latest then
        vim.schedule(function()
          -- Right-aligned, so the line does not jitter as the number grows.
          progress(('%s %5s%%'):format(opts.label, latest))
        end)
      end
    end

    spawn(command, { text = true, stderr = on_stderr }, function(result)
      if result.code == 0 then
        return callback(true)
      end
      local stderr = result.stderr or table.concat(tail, '')
      last = ('%s failed: %s'):format(command[1], stderr:gsub('%s+$', ''))
      attempt()
    end)
  end

  attempt()
end

--- The SHA-256 of a file, as lowercase hex.
---@param path string
---@return string|nil digest
---@return string|nil error
function M.checksum(path)
  local file = io.open(path, 'rb')
  if not file then
    return nil, 'could not read ' .. path
  end

  local contents = file:read('*a')
  file:close()

  return vim.fn.sha256(contents)
end

--- Unpack an archive next to itself.
---@param archive string
---@param directory string
---@param callback fun(ok: boolean, err: string|nil)
function M.unpack(archive, directory, callback)
  local command = archive:sub(-4) == '.zip' and { 'unzip', '-o', archive, '-d', directory }
    or { 'tar', '-xzf', archive, '-C', directory }

  if vim.fn.executable(command[1]) ~= 1 then
    return callback(false, ('%s is needed to unpack %s'):format(command[1], archive))
  end

  spawn(command, { text = true }, function(result)
    if result.code ~= 0 then
      return callback(
        false,
        ('could not unpack %s: %s'):format(archive, (result.stderr or ''):gsub('%s+$', ''))
      )
    end
    callback(true)
  end)
end

--- Download the engine for this machine into the managed location.
---@param opts table|nil `version` to fetch a particular release, `method` to name a download tool.
---@param callback fun(path: string|nil, err: string|nil)
function M.download(opts, callback)
  opts = opts or {}

  local triple, err = M.triple()
  if not triple then
    return callback(nil, err)
  end

  if running then
    running.step = 'downloading'
  end
  progress('downloading ' .. M.binary)

  local url = M.archive_url(opts.version, triple)
  local directory = vim.fs.dirname(M.managed_path())
  vim.fn.mkdir(directory, 'p')

  local archive = vim.fs.joinpath(directory, M.archive_name(triple))
  local label = 'downloading ' .. M.binary

  M.fetch(url, archive, { label = label, method = opts.method }, function(ok, fetch_err)
    if not ok then
      return callback(nil, fetch_err)
    end

    -- Verify against the .sha256 sidecar published alongside the archive.
    local sha_path = vim.fn.tempname()
    M.fetch(url .. '.sha256', sha_path, { method = opts.method }, function(sha_ok, sha_err)
      if not sha_ok then
        vim.fn.delete(archive)
        vim.fn.delete(sha_path)
        return callback(nil, sha_err)
      end

      local ok_read, lines = pcall(vim.fn.readfile, sha_path)
      vim.fn.delete(sha_path)
      if not ok_read or not lines[1] then
        vim.fn.delete(archive)
        return callback(nil, 'could not read checksum for ' .. M.archive_name(triple))
      end

      local expected = lines[1]:match('^%S+'):lower()
      local digest = M.checksum(archive)
      if digest ~= expected then
        vim.fn.delete(archive)
        return callback(
          nil,
          ('the download does not match its checksum (%s)'):format(digest or 'unreadable')
        )
      end

      if running then
        running.step = 'unpacking'
      end
      progress('unpacking ' .. M.binary)

      M.unpack(archive, directory, function(unpacked, unpack_err)
        vim.fn.delete(archive)
        if not unpacked then
          return callback(nil, unpack_err)
        end

        local path = M.managed_path()
        if not vim.uv.fs_stat(path) then
          return callback(nil, ('the archive did not contain %s'):format(M.binary))
        end
        vim.uv.fs_chmod(path, 493) -- 0755

        callback(path)
      end)
    end)
  end)
end

--- Build the engine from the checkout with cargo.
---@param callback fun(path: string|nil, err: string|nil)
function M.build(callback)
  if vim.fn.executable('cargo') ~= 1 then
    return callback(nil, 'cargo is not installed, so the engine cannot be built from source')
  end

  if running then
    running.step = 'building'
  end
  progress(('building %s with cargo, which takes a few minutes'):format(M.binary))

  spawn({ 'cargo', 'build', '--release' }, { cwd = root, text = true }, function(result)
    if result.code ~= 0 then
      return callback(
        nil,
        ('cargo build failed: %s'):format((result.stderr or ''):gsub('%s+$', ''))
      )
    end

    local built = vim.fs.joinpath(root, 'target', 'release', M.binary)
    if not vim.uv.fs_stat(built) then
      return callback(nil, ('cargo reported success but %s is not there'):format(built))
    end

    local destination = M.managed_path()
    vim.fn.mkdir(vim.fs.dirname(destination), 'p')

    local copied, copy_err = vim.uv.fs_copyfile(built, destination)
    if not copied then
      return callback(nil, ('could not install the build: %s'):format(copy_err or 'unknown error'))
    end
    vim.uv.fs_chmod(destination, 493) -- 0755

    callback(destination)
  end)
end

--- Install the engine. See |sqmeow.install()|.
---@param opts string|table|nil A method name, or `method`, `version`, `callback` and `timeout`.
---@return boolean|nil ok Whether an engine was installed, or nil when a `callback` was given.
---@return string|nil err
function M.install(opts)
  opts = type(opts) == 'string' and { method = opts } or opts or {}
  ---@cast opts table

  if opts.method and not vim.tbl_contains(M.methods, opts.method) then
    local err = ('`%s` is not a way to install the engine; pick one of %s'):format(
      opts.method,
      table.concat(M.methods, ', ')
    )
    if opts.callback then
      opts.callback(nil, err)
      return
    end
    notify(err, vim.log.levels.ERROR)
    return false, err
  end

  if running then
    local err = ('an engine is already being installed (%s)'):format(running.step)
    if opts.callback then
      opts.callback(nil, err)
      return
    end
    return false, err
  end
  running = { step = opts.method == 'cargo' and 'building' or 'downloading' }

  local function finish(path, err)
    running = nil
    progress(nil)
    if path then
      notify(('%s installed to %s'):format(M.binary, path))
    else
      notify(err or ('%s could not be installed'):format(M.binary), vim.log.levels.ERROR)
    end
    if opts.callback then
      opts.callback(path, err)
    end
  end

  local done, installed, failure = false, nil, nil
  local function settle(path, err)
    finish(path, err)
    done, installed, failure = true, path, err
  end

  -- Nothing is said at the start.
  if opts.method == 'cargo' then
    M.build(settle)
  elseif opts.method then
    M.download(opts, settle)
  else
    M.download(opts, function(path, download_err)
      if path then
        return settle(path)
      end
      -- Building is the fallback rather than the first try.
      M.build(function(built, build_err)
        if built then
          return settle(built)
        end
        settle(nil, ('%s; %s'):format(download_err, build_err))
      end)
    end)
  end

  if opts.callback then
    return
  end

  if not vim.wait(opts.timeout or M.timeout, function()
    return done
  end, 100) then
    -- The guard comes back down even though whatever was started may still be out there.
    running = nil
    progress(nil)
    local err = ('installing %s timed out'):format(M.binary)
    notify(err, vim.log.levels.ERROR)
    return false, err
  end

  return installed ~= nil, failure
end

--- Ask an engine binary what version it is.
---@param path string Absolute path to an engine.
---@return string|nil version
---@return string|nil error
function M.version(path)
  local ok, result = pcall(function()
    return vim.system({ path, '--version' }, { text = true }):wait(5000)
  end)

  if not ok then
    return nil, tostring(result)
  end
  if result.code ~= 0 then
    local message = (result.stderr or ''):gsub('%s+$', '')
    return nil, message
  end

  return (result.stdout or ''):match('([%d%.]+)')
end

return M
