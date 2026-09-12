--- Finding, and if need be fetching, the engine binary.
---
--- Three places are checked, in order: the path the user configured, the managed copy under
--- `stdpath('data')`, and a local `cargo build` inside the plugin directory. The last one exists
--- so that working on the engine needs no install step.
---
--- When none of them has one, a release build is downloaded. That is what keeps installation free
--- of a Rust toolchain: the release workflow cross-compiles for every target it supports and
--- publishes a manifest naming each archive and its checksum, and this reads that.

local M = {}

--- Where releases are published.
M.repository = '2giosangmitom/sqmeow.nvim'

--- Name of the engine executable on this platform.
M.binary = vim.fn.has('win32') == 1 and 'sqmeow-core.exe' or 'sqmeow-core'

local root = vim.fs.normalize(
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
)

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

--- The Rust target triple for this machine.
---
--- Reported the way `rustc` names it, because that is what the release archives are named after.
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
    Linux = 'unknown-linux-gnu',
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
--- built for without adding a dependency to any of them.
---
---@param url string
---@param destination string
---@return boolean ok
---@return string|nil error
function M.fetch(url, destination)
  local attempts = {
    { 'curl', '--fail', '--location', '--silent', '--show-error', '--output', destination, url },
    { 'wget', '--quiet', '--output-document', destination, url },
    {
      'powershell',
      '-NoProfile',
      '-Command',
      ("Invoke-WebRequest -Uri '%s' -OutFile '%s'"):format(url, destination),
    },
  }

  local last = 'no download tool was found; install curl or wget'
  for _, command in ipairs(attempts) do
    if vim.fn.executable(command[1]) == 1 then
      local result = vim.system(command, { text = true }):wait(120000)
      if result.code == 0 then
        return true
      end
      last = ('%s failed: %s'):format(command[1], (result.stderr or ''):gsub('%s+$', ''))
    end
  end

  return false, last
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
---@return table|nil manifest Target triple to `{ url, sha256, size }`.
---@return string|nil error
function M.manifest(version)
  local path = vim.fn.tempname()
  local ok, err = M.fetch(M.manifest_url(version), path)
  if not ok then
    return nil, err
  end

  local decoded
  ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  vim.fn.delete(path)

  if not ok or type(decoded) ~= 'table' or type(decoded.targets) ~= 'table' then
    return nil, 'the release manifest could not be read'
  end
  return decoded.targets
end

--- Unpack an archive next to itself.
---
---@param archive string
---@param directory string
---@return boolean ok
---@return string|nil error
function M.unpack(archive, directory)
  local command = archive:sub(-4) == '.zip' and { 'unzip', '-o', archive, '-d', directory }
    or { 'tar', '-xzf', archive, '-C', directory }

  if vim.fn.executable(command[1]) ~= 1 then
    return false, ('%s is needed to unpack %s'):format(command[1], archive)
  end

  local result = vim.system(command, { text = true }):wait(120000)
  if result.code ~= 0 then
    return false,
      ('could not unpack %s: %s'):format(archive, (result.stderr or ''):gsub('%s+$', ''))
  end
  return true
end

--- Download the engine for this machine into the managed location.
---
--- Synchronous on purpose. It runs from `:Sqmeow update` and from the first call that needs an
--- engine, both of which are moments the user is waiting on it anyway, and a download that
--- finished in the background after the command it was for had given up would be worse.
---
---@param opts table|nil `version` to fetch a particular release.
---@return string|nil path The installed engine.
---@return string|nil error
function M.download(opts)
  opts = opts or {}

  local triple, err = M.triple()
  if not triple then
    return nil, err
  end

  local targets
  targets, err = M.manifest(opts.version)
  if not targets then
    return nil, err
  end

  local entry = targets[triple]
  if not entry then
    return nil, ('this release has no engine for %s'):format(triple)
  end

  local directory = vim.fs.dirname(M.managed_path())
  vim.fn.mkdir(directory, 'p')

  local archive = vim.fs.joinpath(directory, vim.fs.basename(entry.url))
  local ok
  ok, err = M.fetch(entry.url, archive)
  if not ok then
    return nil, err
  end

  -- Checked before unpacking, not after: an archive that is not what the release says it is has
  -- no business being written anywhere but the temporary file it already occupies.
  local digest = M.checksum(archive)
  if digest ~= entry.sha256 then
    vim.fn.delete(archive)
    return nil, ('the download does not match its checksum (%s)'):format(digest or 'unreadable')
  end

  ok, err = M.unpack(archive, directory)
  vim.fn.delete(archive)
  if not ok then
    return nil, err
  end

  local path = M.managed_path()
  if not vim.uv.fs_stat(path) then
    return nil, ('the archive did not contain %s'):format(M.binary)
  end
  vim.uv.fs_chmod(path, 493) -- 0755

  return path
end

--- Build the engine from the checkout, for a target with no release build.
---
---@return string|nil path
---@return string|nil error
function M.build()
  if vim.fn.executable('cargo') ~= 1 then
    return nil, 'no prebuilt engine matched, and cargo is not installed to build one'
  end

  local result = vim
    .system({ 'cargo', 'build', '--release' }, { cwd = root, text = true })
    :wait(600000)
  if result.code ~= 0 then
    return nil, ('cargo build failed: %s'):format((result.stderr or ''):gsub('%s+$', ''))
  end

  return M.dev_path()
end

--- Get an engine, downloading or building one if there is none.
---
---@param opts table|nil `force` fetches even when one is already there.
---@return string|nil path
---@return string|nil error
function M.ensure(opts)
  opts = opts or {}

  if not opts.force then
    local path = M.resolve()
    if path and vim.uv.fs_stat(path) then
      return path
    end
  end

  local path, err = M.download(opts)
  if path then
    return path
  end

  -- Building is the fallback, not the first try: most people have no Rust toolchain, and the ones
  -- who do would still rather not spend two minutes on it.
  local built, build_err = M.build()
  if built then
    return built
  end
  return nil, ('%s; %s'):format(err, build_err)
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
