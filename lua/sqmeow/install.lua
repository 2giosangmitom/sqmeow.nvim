--- Finding, and if need be fetching, the engine binary.
---
--- Three places are checked, in order: the path the user configured, the managed copy under
--- `stdpath('data')`, and a local `cargo build` inside the plugin directory. The last one exists
--- so that working on the engine needs no install step.
---
--- When none of them has one, a release build is downloaded. That is what keeps installation free
--- of a Rust toolchain: the release workflow cross-compiles for every target it supports and
--- publishes a manifest naming each archive and its checksum, and this reads that.
---
--- Nothing here ever waits. A download is minutes of work on a slow connection, and an editor that
--- cannot be typed in for those minutes is indistinguishable from one that has hung. Every step
--- that runs a program hands back a callback instead, so the install happens while the editor goes
--- on being an editor.

local M = {}

--- Where releases are published.
M.repository = '2giosangmitom/sqmeow.nvim'

--- Name of the engine executable on this platform.
M.binary = vim.fn.has('win32') == 1 and 'sqmeow-core.exe' or 'sqmeow-core'

--- The install now running, if there is one.
---
--- Held so that a second one is not started alongside it: both write to the same paths, and the
--- one thing worse than waiting for a download is two of them unpacking over each other.
---@type table|nil
local running = nil

local root = vim.fs.normalize(
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
)

local function notify(message, level)
  vim.notify('sqmeow: ' .. message, level or vim.log.levels.INFO)
end

--- Show how far the install has got, on the message line rather than in the notification history.
---
--- A notification per percent would bury everything else that happened today. This writes over
--- itself instead, and the last one is cleared when the install ends.
---
---@param message string|nil nil clears the line.
local function progress(message)
  if not message then
    return vim.api.nvim_echo({}, false, {})
  end
  vim.api.nvim_echo({ { 'sqmeow: ' .. message, 'MoreMsg' } }, false, {})
end

--- Start a program and answer when it is done, without waiting for it.
---
---@param command string[]
---@param opts table
---@param callback fun(result: table)
local function spawn(command, opts, callback)
  local ok, err = pcall(vim.system, command, opts, vim.schedule_wrap(callback))
  if not ok then
    -- `vim.system` throws when the program cannot be started at all, which is a failure like any
    -- other to everything upstream of here.
    vim.schedule(function()
      callback({ code = -1, stderr = tostring(err) })
    end)
  end
end

--- Directory the plugin was installed into.
---@return string
function M.plugin_root()
  return root
end

--- Where a downloaded engine is kept.
---@return string
function M.managed_path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow', 'bin', M.binary)
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
---
---@return string|nil path Absolute path to the engine.
---@return string source One of 'config', 'managed', 'dev', or 'missing'.
function M.resolve()
  local configured = require('sqmeow.config').get().core.path
  if configured then
    return vim.fs.normalize(configured), 'config'
  end

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
---
--- The engine cannot be started while this is true, so callers use it to tell a user who is
--- waiting on a download from one who has no engine at all.
---
---@return string|nil step One of 'downloading', 'unpacking' or 'building', or nil when idle.
function M.installing()
  return running and running.step or nil
end

--- The Rust target triple for this machine.
---
--- Named the way the release archives are, since matching one of them is the only thing this is
--- for. Linux is musl rather than gnu: the release workflow builds statically against musl so the
--- binary is not tied to a distribution newer than the one running it, and a triple of `gnu` here
--- would match nothing in the manifest and send every Linux user to a cargo build instead.
---
--- An unrecognised pair answers with nil rather than a guess: downloading the wrong binary fails
--- in a much more confusing way than not downloading one at all.
---
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

--- Where the manifest for a release lives.
---
--- The release asked for is the plugin's own version, which lives in |sqmeow.rpc| next to the
--- protocol version. A plugin manager may have checked out a commit that is not a tag at all, so
--- it is written down rather than read from the checkout.
---
---@param version string|nil Defaults to this plugin's version.
---@return string
function M.manifest_url(version)
  return ('https://github.com/%s/releases/download/v%s/manifest.json'):format(
    M.repository,
    version or require('sqmeow.rpc').version
  )
end

--- Download something, with whichever tool this machine has.
---
--- curl first, then wget, then PowerShell, which between them covers every platform the engine is
--- built for without adding a dependency to any of them. They are tried in turn, and only a tool
--- that is installed and then fails moves on to the next.
---
---@param url string
---@param destination string
---@param opts table|nil `label` names the download in the progress line.
---@param callback fun(ok: boolean, err: string|nil)
function M.fetch(url, destination, opts, callback)
  opts = opts or {}

  -- curl draws a progress bar when its output is a file and it is not asked to be silent, which is
  -- the only one of the three that can say how far along it is.
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

  local index = 0
  local last = 'no download tool was found; install curl or wget'

  local function attempt()
    index = index + 1
    local command = attempts[index]
    if not command then
      return callback(false, last)
    end
    if vim.fn.executable(command[1]) ~= 1 then
      return attempt()
    end

    -- Reading stderr as it arrives is what turns curl's bar into a percentage, so it cannot also
    -- be collected into the result; the tail of it is kept by hand for the error message.
    local tail = {}

    -- curl redraws its bar by returning to the start of the line, so a carriage return is what
    -- ends one. A chunk can arrive split through the middle of a number, and reading that half
    -- would show 5.9% in the middle of a download that is really at 65.9%, so an unfinished tail
    -- is carried over to the next chunk instead of being matched.
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
---
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

--- Read the manifest for a release.
---
---@param version string|nil
---@param callback fun(targets: table|nil, err: string|nil) Target triple to `{ url, sha256, size }`.
function M.manifest(version, callback)
  local path = vim.fn.tempname()

  M.fetch(M.manifest_url(version), path, nil, function(ok, err)
    if not ok then
      return callback(nil, err)
    end

    local decoded
    ok, decoded = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    end)
    vim.fn.delete(path)

    if not ok or type(decoded) ~= 'table' or type(decoded.targets) ~= 'table' then
      return callback(nil, 'the release manifest could not be read')
    end
    callback(decoded.targets)
  end)
end

--- Unpack an archive next to itself.
---
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
---
---@param opts table|nil `version` to fetch a particular release.
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

  M.manifest(opts.version, function(targets, manifest_err)
    if not targets then
      return callback(nil, manifest_err)
    end

    local entry = targets[triple]
    if not entry then
      return callback(nil, ('this release has no engine for %s'):format(triple))
    end

    local directory = vim.fs.dirname(M.managed_path())
    vim.fn.mkdir(directory, 'p')

    local archive = vim.fs.joinpath(directory, vim.fs.basename(entry.url))
    local label = 'downloading ' .. M.binary

    M.fetch(entry.url, archive, { label = label }, function(ok, fetch_err)
      if not ok then
        return callback(nil, fetch_err)
      end

      -- Checked before unpacking, not after: an archive that is not what the release says it is
      -- has no business being written anywhere but the file it already occupies.
      local digest = M.checksum(archive)
      if digest ~= entry.sha256 then
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

--- Build the engine from the checkout, for a target with no release build.
---
---@param callback fun(path: string|nil, err: string|nil)
function M.build(callback)
  if vim.fn.executable('cargo') ~= 1 then
    return callback(nil, 'no prebuilt engine matched, and cargo is not installed to build one')
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
    callback(M.dev_path())
  end)
end

--- Get an engine, downloading or building one if there is none.
---
--- Answers through the callback, which may be called before this returns when an engine is already
--- there and nothing has to be fetched.
---
---@param opts table|nil `force` fetches even when one is already there.
---@param callback fun(path: string|nil, err: string|nil)|nil
function M.ensure(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  if not opts.force then
    local path = M.resolve()
    if path and vim.uv.fs_stat(path) then
      return callback(path)
    end
  end

  if running then
    return callback(nil, ('an engine is already being installed (%s)'):format(running.step))
  end
  running = { step = 'downloading' }

  local function finish(path, err)
    running = nil
    progress(nil)
    if path then
      notify(M.binary .. ' installed')
    else
      notify(err or ('%s could not be installed'):format(M.binary), vim.log.levels.ERROR)
    end
    callback(path, err)
  end

  -- Nothing is said at the start. The progress line is already saying what is happening, and a
  -- notification as well would be the same thing twice in two places.
  M.download(opts, function(path, download_err)
    if path then
      return finish(path)
    end

    -- Building is the fallback, not the first try: most people have no Rust toolchain, and the
    -- ones who do would still rather not spend two minutes on it.
    M.build(function(built, build_err)
      if built then
        return finish(built)
      end
      finish(nil, ('%s; %s'):format(download_err, build_err))
    end)
  end)
end

--- Ask an engine binary what version it is.
---
--- Runs `--version`, which the engine answers without opening a channel, so this is safe to call
--- from `:checkhealth` on a binary that is never started.
---
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
    return nil, (result.stderr or ''):gsub('%s+$', '')
  end

  return (result.stdout or ''):match('([%d%.]+)')
end

return M
