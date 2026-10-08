--- Manages the msgpack-rpc channel to the engine.
---
--- One job is shared by all connections. Requests wait only for the RPC reply;
--- long-running methods report completion later through events dispatched here.
--- This module owns process lifetime and transport errors, not database state.

local M = {}

--- Plugin version, sent at handshake.
M.version = '2.5.0' -- x-release-please-version

---@class sqmeow.EngineInfo
---@field core_version string
---@field pid integer
---@field adapters string[]

local channel = nil
local info = nil
local subscribers = {}
local log = {}
local requesting = 0
local pending_events = {}
local dispatching = false
local scheduled = false

-- Jobs we asked to stop.
local expected_exit = {}

--- Most recent engine log lines, oldest first.
M.log_limit = 200

local function warn(message)
  require('sqmeow.core.utils').notify(message, vim.log.levels.WARN)
end

local function drain_events()
  if requesting > 0 or dispatching or scheduled then
    return
  end
  dispatching = true
  while #pending_events > 0 do
    local event = table.remove(pending_events, 1)
    for _, callback in ipairs(subscribers[event[1]] or {}) do
      local ok, err = pcall(callback, event[2])
      if not ok then
        warn(('a handler for `%s` failed: %s'):format(event[1], err))
      end
    end
  end
  dispatching = false
end

local function record(line)
  table.insert(log, line)
  if #log > M.log_limit then
    table.remove(log, 1)
  end
end

local function forget(job)
  -- Only the current engine's exit clears the state.
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

--- Returns engine log lines collected from stderr, oldest first.
---@return string[]
function M.messages()
  return vim.deepcopy(log)
end

--- Returns whether the engine is running.
---@return boolean
function M.is_running()
  return channel ~= nil
end

--- Returns the handshake info reported by the running engine.
---@return sqmeow.EngineInfo|nil
function M.info()
  return info
end

--- Starts the engine if it is not already running.
--- Resolves a managed/development binary, performs the handshake, and mirrors
--- query settings before returning. It never downloads a missing binary.
---@return integer|nil channel
---@return string|nil error
function M.start()
  if channel then
    return channel
  end

  local install = require('sqmeow.server.install')
  local config = require('sqmeow.config').get()

  local path, source = install.resolve()
  if not path then
    -- Nothing is installed from here.
    local step = install.installing()
    if step then
      return nil, 'the engine is ' .. step
    end

    return nil, 'no engine binary found; run `:Sqmeow install` or `require("sqmeow").install()`'
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

  -- Leaving the editor would kill the job outright.
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
  ---@cast handshake sqmeow.EngineInfo

  info = handshake
  -- A new engine numbers its calls from one again, so nothing kept by call id still holds.
  require('sqmeow.rpc.events').on_engine_restart()
  M.configure()
  return channel
end

--- Mirrors the plugin's configuration into the engine.
---@return table|nil applied What the engine applied, after clamping.
function M.configure()
  if not channel then
    return nil
  end

  local config = require('sqmeow.config').get()
  local ok, applied = pcall(vim.rpcrequest, channel, 'configure', {
    max_rows = config.query.max_rows,
    history_size = config.query.history_size,
    timeout_ms = config.query.timeout_ms,
  })

  if not ok then
    warn(('the engine refused the configuration: %s'):format(applied))
    return nil
  end
  return applied
end

--- Stops the engine gracefully.
function M.stop()
  pending_events = {}
  if not channel then
    return
  end

  -- Ask first, so the engine can close its pools, then make sure it is gone.
  local job = channel
  expected_exit[job] = true
  pcall(vim.rpcrequest, job, 'shutdown', vim.empty_dict())
  pcall(vim.fn.jobstop, job)
  forget(job)
  -- Shutdown can receive more events while waiting for the RPC reply.
  pending_events = {}
end

--- Restarts the engine.
---@return integer|nil channel
---@return string|nil error
function M.restart()
  M.stop()
  return M.start()
end

--- Calls an engine method and waits for its answer.
--- Starts the engine lazily and catches transport/RPC errors. A successful reply
--- may acknowledge queued work; wait for the method's completion event
--- before using results. Database and UI state are managed by callers/events.
---@param method string
---@param args table|nil Keyword arguments for the method.
---@return any|nil result
---@return string|nil error
function M.request(method, args)
  local chan, err = M.start()
  if not chan then
    return nil, err
  end

  requesting = requesting + 1
  local ok, result = pcall(vim.rpcrequest, chan, method, args or vim.empty_dict())
  requesting = requesting - 1
  if requesting == 0 and #pending_events > 0 and not dispatching and not scheduled then
    -- Let the caller record the accepted call id before handling its events.
    scheduled = true
    vim.schedule(function()
      scheduled = false
      drain_events()
    end)
  end
  if not ok then
    return nil, tostring(result)
  end
  return result
end

--- Calls an engine method without waiting.
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

--- Subscribes to an engine event.
--- Listeners run in registration order during dispatch. A failing listener is
--- reported without preventing the remaining listeners from running.
---@param event string Event name (e.g. `'call:state'`).
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

--- Delivers an engine event to subscribers.
---@param event string
---@param payload any
function M.dispatch(event, payload)
  -- A handler can redraw the drawer and parse project sources through RPC. Calling
  -- back while an earlier request is waiting can violate Neovim's reply ordering.
  table.insert(pending_events, { event, payload })
  drain_events()
end

return M
