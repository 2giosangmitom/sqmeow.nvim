--- The channel to the engine.
---
--- The engine is started with `rpc = true`, which makes it a msgpack-rpc peer rather than a
--- process whose output we parse. Both sides can call the other: the plugin calls methods, and
--- the engine pushes events back through `dispatch` and writes result buffers itself.
---
--- Nothing here blocks for long. Engine methods answer immediately with an acknowledgement or a
--- call id, and anything that touches a database reports its progress as an event.

local M = {}

--- Plugin version, sent at handshake.
---
--- It also names the release |sqmeow.install| downloads an engine from, so it has to move
--- with the tag. release-please bumps it, finding the line by the annotation.
M.version = '0.1.0' -- x-release-please-version

--- Protocol revision this plugin speaks. An engine reporting anything else is refused.
M.protocol_version = 1

---@class sqmeow.EngineInfo
---@field core_version string
---@field protocol_version integer
---@field pid integer
---@field adapters string[]

local channel = nil
local info = nil
local subscribers = {}
local log = {}

-- Jobs we asked to stop, so their exit is not reported as a crash. Keyed by job id rather than a
-- single flag: during a restart the old engine is still exiting while the new one is starting.
local expected_exit = {}

--- Most recent engine log lines, oldest first.
M.log_limit = 200

local function warn(message)
  vim.notify('sqmeow: ' .. message, vim.log.levels.WARN)
end

local function record(line)
  table.insert(log, line)
  if #log > M.log_limit then
    table.remove(log, 1)
  end
end

local function forget(job)
  -- Only the current engine's exit clears the state. A restart starts the new engine before the
  -- old one has finished dying, and the straggler must not wipe its replacement.
  if channel == job then
    channel, info = nil, nil
  end
end

local function on_exit(job, code)
  local asked = expected_exit[job]
  expected_exit[job] = nil
  forget(job)

  -- A non-zero code after `stop()` is the signal we sent, not a failure to report.
  if code ~= 0 and not asked then
    warn(('the engine exited with code %d'):format(code))
  end
end

--- Engine log lines collected from its stderr.
---
--- The engine never writes to stdout, which carries the protocol, so this is where anything it
--- has to say ends up.
---
---@return string[]
function M.messages()
  return vim.deepcopy(log)
end

--- Whether the engine is running.
---@return boolean
function M.is_running()
  return channel ~= nil
end

--- What the running engine reported at handshake.
---@return sqmeow.EngineInfo|nil
function M.info()
  return info
end

--- Start the engine if it is not already running.
---
---@return integer|nil channel
---@return string|nil error
function M.start()
  if channel then
    return channel
  end

  local install = require('sqmeow.install')
  local config = require('sqmeow.config').get()

  local path, source = install.resolve()
  if not path and config.core.auto_install then
    -- The first call that needs an engine is the moment to fetch one. Doing it at startup would
    -- make a plugin nobody used that session pay for a download.
    vim.notify('sqmeow: downloading the engine…')
    local err
    path, err = install.ensure()
    source = 'managed'
    if not path then
      return nil, err
    end
  end
  if not path then
    return nil, 'no engine binary found; run `:Sqmeow update` to download one'
  end

  local spawned = vim.fn.jobstart({ path }, {
    rpc = true,
    env = { SQMEOW_LOG = config.core.log_level },
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line ~= '' then
          record(line)
          -- Only genuine failures interrupt the user; the rest waits in the log.
          if line:find('ERROR', 1, true) then
            warn(line)
          end
        end
      end
    end,
    on_exit = function(job, code)
      on_exit(job, code)
    end,
  })

  if spawned <= 0 then
    return nil, ('could not start the engine at %s (%s)'):format(path, source)
  end
  channel = spawned

  -- Leaving the editor would kill the job outright, which the engine would report as a crash.
  -- Asking it to stop first keeps a normal exit looking normal.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('sqmeow.engine', { clear = true }),
    desc = 'Stop the sqmeow engine',
    callback = function()
      M.stop()
    end,
  })

  local ok, handshake = pcall(vim.rpcrequest, channel, 'handshake', {
    plugin_version = M.version,
  })
  if not ok then
    M.stop()
    return nil, ('the engine did not answer the handshake: %s'):format(handshake)
  end

  if handshake.protocol_version ~= M.protocol_version then
    local message = ('engine speaks protocol %s, this plugin speaks %s; run `:Sqmeow update`'):format(
      handshake.protocol_version,
      M.protocol_version
    )
    M.stop()
    return nil, message
  end

  info = handshake
  M.configure()
  return channel
end

--- Mirror the plugin's configuration into the engine.
---
--- The engine needs the row cap, the page size, and the column width because it is the side that
--- decides what a page looks like. Sending them rather than duplicating defaults means there is
--- one place a user changes them.
---
---@return table|nil applied What the engine says it applied, after clamping.
function M.configure()
  if not channel then
    return nil
  end

  local config = require('sqmeow.config').get()
  local ok, applied = pcall(vim.rpcrequest, channel, 'configure', {
    max_rows = config.query.max_rows,
    history_size = config.query.history_size,
    page_size = config.ui.result.page_size,
    max_column_width = config.ui.result.max_column_width,
    ascii = config.integrations.icons == 'ascii',
  })

  if not ok then
    warn(('the engine refused the configuration: %s'):format(applied))
    return nil
  end
  return applied
end

--- Stop the engine.
function M.stop()
  if not channel then
    return
  end

  -- Ask first, so the engine can close its pools, then make sure it is gone.
  local job = channel
  expected_exit[job] = true
  pcall(vim.rpcrequest, job, 'shutdown', vim.empty_dict())
  pcall(vim.fn.jobstop, job)
  forget(job)
end

--- Stop and start the engine.
---
---@return integer|nil channel
---@return string|nil error
function M.restart()
  M.stop()
  return M.start()
end

--- Call an engine method and wait for its answer.
---
--- Engine methods return promptly by contract, so this does not stall the editor. Work that takes
--- real time answers with a call id and reports the rest through events.
---
---@param method string
---@param args table|nil Keyword arguments for the method.
---@return any|nil result
---@return string|nil error
function M.request(method, args)
  local chan, err = M.start()
  if not chan then
    return nil, err
  end

  local ok, result = pcall(vim.rpcrequest, chan, method, args or vim.empty_dict())
  if not ok then
    return nil, tostring(result)
  end
  return result
end

--- Call an engine method without waiting.
---
---@param method string
---@param args table|nil
---@return boolean started
---@return string|nil error
function M.notify(method, args)
  local chan, err = M.start()
  if not chan then
    return false, err
  end

  vim.rpcnotify(chan, method, args or vim.empty_dict())
  return true
end

--- Subscribe to an engine event.
---
---@param event string Event name, such as 'call:state'.
---@param callback fun(payload: any)
---@return fun() unsubscribe
function M.on(event, callback)
  subscribers[event] = subscribers[event] or {}
  local listeners = subscribers[event]
  table.insert(listeners, callback)

  return function()
    for index, listener in ipairs(listeners) do
      if listener == callback then
        table.remove(listeners, index)
        return
      end
    end
  end
end

--- Deliver an engine event. Called by the engine, not by user code.
---
--- A failing subscriber is reported and skipped. Letting it propagate would surface as an
--- unrelated error on the engine's next call, which is a miserable thing to debug.
---
---@param event string
---@param payload any
function M.dispatch(event, payload)
  for _, callback in ipairs(subscribers[event] or {}) do
    local ok, err = pcall(callback, payload)
    if not ok then
      warn(('a handler for `%s` failed: %s'):format(event, err))
    end
  end
end

return M
