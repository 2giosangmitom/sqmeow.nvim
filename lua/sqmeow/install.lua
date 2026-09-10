--- Locating the engine binary.
---
--- Three places are checked, in order: the path the user configured, the managed copy under
--- `stdpath('data')`, and a local `cargo build` inside the plugin directory. The last one exists
--- so that working on the engine needs no install step.

local M = {}

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
