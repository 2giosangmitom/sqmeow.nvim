--- Connections from an environment variable.

local M = {}

--- The variable read when the source does not name one.
M.default_variable = 'SQMEOW_CONNECTIONS'

--- Read connections from the environment.
---@param opts table|nil Source options: `var` names the variable to read.
---@return sqmeow.ConnectionSpec[]
---@return string|nil error
function M.load(opts)
  local variable = (opts or {}).var or M.default_variable
  local raw = vim.env[variable]

  if not raw or raw == '' then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then
    return {}, ('%s does not hold valid JSON: %s'):format(variable, decoded)
  end
  if type(decoded) ~= 'table' then
    return {}, ('%s must hold a JSON array of connections'):format(variable)
  end

  return decoded
end

return M
