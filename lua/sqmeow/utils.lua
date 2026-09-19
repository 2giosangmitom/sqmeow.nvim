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

--- Cuts `text` to `limit` display columns, ending in `marker` when cut.
---@param text string
---@param limit integer
---@param marker string
---@return string
function M.truncate(text, limit, marker)
  if vim.api.nvim_strwidth(text) <= limit then
    return text
  end
  if limit <= 0 then
    return ''
  end
  -- A marker wider than the room left would overflow the column itself.
  if vim.api.nvim_strwidth(marker) > limit then
    marker = ''
  end

  local budget = limit - vim.api.nvim_strwidth(marker)
  local out, at = {}, 0

  -- One character at a time, because cutting by byte would split a wide one in half.
  for char in M.characters(text) do
    local step = vim.api.nvim_strwidth(char)
    if at + step > budget then
      break
    end
    at = at + step
    table.insert(out, char)
  end

  return table.concat(out) .. marker
end

--- Iterates the UTF-8 characters of `text`.
---@param text string
---@return fun(): string|nil
function M.characters(text)
  return text:gmatch('[%z\1-\127\194-\244][\128-\191]*')
end

--- Byte offset of a display column on a line.
---@param line string
---@param display integer
---@return integer bytes
function M.byte_at(line, display)
  local at, bytes = 0, 0
  for char in M.characters(line) do
    if at >= display then
      break
    end
    at = at + vim.api.nvim_strwidth(char)
    bytes = bytes + #char
  end
  return bytes
end

--- Display column of a byte offset on a line.
---@param line string
---@param bytes integer Zero-based byte column.
---@return integer display
function M.display_at(line, bytes)
  return vim.fn.strdisplaywidth(line:sub(1, bytes))
end

return M
