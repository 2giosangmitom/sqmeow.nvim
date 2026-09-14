--- Helpers more than one part of the plugin needs.

local M = {}

--- Tell the user something, saying which plugin it came from.
---@param message string
---@param level integer|nil One of `vim.log.levels`, INFO when left out.
function M.notify(message, level)
  vim.notify('sqmeow: ' .. message, level or vim.log.levels.INFO)
end

--- Whether a buffer handle still names a buffer.
---@param buf integer|nil
---@return boolean
function M.buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Whether a window still shows the buffer a surface put in it.
---@param win integer|nil
---@param buf integer|nil
---@return boolean
function M.shows(win, buf)
  return win ~= nil
    and M.buf_valid(buf)
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == buf
end

--- nui.nvim's components by name, or nil and a message when it is not installed.
---@param names string[] Component modules without their `nui.` prefix, such as `{ 'popup', 'line' }`.
---@param surface string What needs them, for the message, such as `the drawer`.
---@return table<string, any>|nil components Keyed by capitalised name, such as `Popup` and `Line`.
---@return string error Empty when every component loaded.
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
