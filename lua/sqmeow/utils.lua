--- Shared helpers used across the plugin.

local M = {}

--- Notifies the user with a `sqmeow:` prefix.
---@param message string
---@param level integer|nil One of `vim.log.levels`; defaults to `INFO`.
function M.notify(message, level)
  vim.notify('sqmeow: ' .. message, level or vim.log.levels.INFO)
end

--- Returns whether `buf` is a valid buffer handle.
---@param buf integer|nil
---@return boolean
function M.buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Returns whether `win` still shows `buf`.
---@param win integer|nil
---@param buf integer|nil
---@return boolean
function M.shows(win, buf)
  return win ~= nil
    and M.buf_valid(buf)
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == buf
end

--- Loads `nui.nvim` components.
---@param names string[] Component modules without the `nui.` prefix (e.g. `{ 'popup', 'line' }`).
---@param surface string Human-readable caller name used in the error message.
---@return table<string, any>|nil components Keyed by capitalised name (e.g. `Popup`).
---@return string error Empty when every component loaded; otherwise the failure reason.
function M.nui(names, surface)
  local components = {}
  for _, name in ipairs(names) do
    local ok, module = pcall(require, 'nui.' .. name)
    if not ok then
      return nil, ('%s needs nui.nvim (MunifTanjim/nui.nvim)'):format(surface)
    end
    components[name:sub(1, 1):upper() .. name:sub(2)] = module
  end
  return components, ''
end

return M
