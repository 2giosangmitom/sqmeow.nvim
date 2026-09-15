--- Connections a command prints as a JSON array, such as a secret manager's.

local M = {}

--- What each command printed last, by the command, filled in when it finishes.
---@type table<string, { connections: sqmeow.ConnectionSpec[], error: string|nil }>
local cache = {}

--- The command as a list of arguments.
---@param command string|string[]
---@return string[]
local function argv(command)
  if type(command) == 'string' then
    return { vim.o.shell, vim.o.shellcmdflag, command }
  end
  return command
end

--- Run the command in the background, and redraw the drawer with what it prints.
---@param command string[]
---@param entry table
local function run(command, entry)
  local ok, err = pcall(vim.system, command, { text = true }, function(done)
    vim.schedule(function()
      if done.code ~= 0 then
        entry.error = ('`%s` failed: %s'):format(table.concat(command, ' '), vim.trim(done.stderr))
      else
        local decoded, value = pcall(vim.json.decode, done.stdout)
        if decoded and type(value) == 'table' then
          entry.connections, entry.error = value, nil
        else
          entry.error = ('`%s` did not print a JSON array of connections'):format(
            table.concat(command, ' ')
          )
        end
      end
      require('sqmeow.ui.drawer').render()
    end)
  end)
  if not ok then
    entry.error = ('`%s` could not be run: %s'):format(table.concat(command, ' '), err)
  end
end

--- The connections the command printed. The first call starts it and answers with none.
---@param opts table|nil Source options: `command`, a shell string or a list of arguments.
---@return sqmeow.ConnectionSpec[]
---@return string|nil error
function M.load(opts)
  local command = (opts or {}).command
  if type(command) ~= 'string' and type(command) ~= 'table' then
    return {}, 'a command source needs a `command`'
  end
  command = argv(command)
  local key = table.concat(command, '\0')
  local entry = cache[key]
  if not entry then
    entry = { connections = {} }
    cache[key] = entry
    run(command, entry)
  end
  return entry.connections, entry.error
end

--- Run every command again the next time its connections are asked for.
function M.reload()
  cache = {}
end

return M
