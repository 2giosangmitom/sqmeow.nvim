--- Everything the plugin says out loud.
---
--- One function, `M.notify`, so a message can be turned off by configuration in one place and so
--- progress can replace itself rather than stack. Replacement is what nvim-notify and
--- snacks.notifier both offer through the same mechanism: pass back the handle the previous call
--- returned. Frontends that do not support it ignore the extra field, and the messages stack, so
--- there is nothing to detect.

local M = {}

--- Handles of the progress messages currently on screen, keyed by whatever named them.
local handles = {}

local function enabled()
  return require('sqmeow.config').get().integrations.notify
end

--- Say something once.
---
---@param message string
---@param level integer|nil A `vim.log.levels` value. Defaults to INFO.
function M.notify(message, level)
  level = level or vim.log.levels.INFO
  -- An error is never suppressed. Turning notifications off means "stop telling me about
  -- progress", not "fail silently".
  if not enabled() and level < vim.log.levels.ERROR then
    return
  end

  vim.notify('sqmeow: ' .. message, level)
end

--- Report an operation that is still going, replacing its previous message.
---
--- The first call with a given key creates the message and the rest update it, so a connection
--- attempt and then its outcome occupy one line rather than two.
---
---@param key string Names the operation, such as `'connect:3'`.
---@param message string
---@param opts table|nil `level`, and `done` to release the handle after this message.
function M.progress(key, message, opts)
  opts = opts or {}
  -- With notifications off there is no handle to replace, but an error still has to be heard, so
  -- the plain path decides what happens to it.
  if not enabled() then
    return M.notify(message, opts.level)
  end

  local handle = vim.notify('sqmeow: ' .. message, opts.level or vim.log.levels.INFO, {
    title = 'sqmeow',
    -- nvim-notify and snacks both read this and rewrite the message in place.
    replace = handles[key],
    hide_from_history = not opts.done,
  })

  if opts.done then
    handles[key] = nil
  else
    handles[key] = handle
  end
end

--- Forget every in-flight message. Used when the engine restarts.
function M.reset()
  handles = {}
end

return M
