--- Putting the user's windows back.

local M = {}

local saved = nil

--- Whether any plugin window is showing.
---@return boolean
function M.anything_open()
  return require('sqmeow.ui.drawer').is_open() or require('sqmeow.ui.result').is_open()
end

--- Record the current layout, if this is the first plugin window to open.
function M.remember()
  if saved or M.anything_open() then
    return
  end

  -- By window rather than with `winrestcmd()`.
  local sizes = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      sizes[win] =
        { height = vim.api.nvim_win_get_height(win), width = vim.api.nvim_win_get_width(win) }
    end
  end

  saved = {
    sizes = sizes,
    win = vim.api.nvim_get_current_win(),
  }
end

--- Put the layout back, once no plugin window is left.
function M.restore()
  if not saved or M.anything_open() then
    return
  end

  local restore = saved
  saved = nil

  -- Only the arrangement that was recorded is put back.
  local now = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ''
  end, vim.api.nvim_tabpage_list_wins(0))
  local same = #now == vim.tbl_count(restore.sizes)
    and vim.iter(now):all(function(win)
      return restore.sizes[win] ~= nil
    end)

  -- Sizes first, then the cursor.
  if same and #now > 1 then
    for _ = 1, 2 do
      for win, size in pairs(restore.sizes) do
        pcall(vim.api.nvim_win_set_height, win, size.height)
        pcall(vim.api.nvim_win_set_width, win, size.width)
      end
    end
  end
  if vim.api.nvim_win_is_valid(restore.win) then
    pcall(vim.api.nvim_set_current_win, restore.win)
  end
end

--- Whether a window is somewhere an ordinary file could be opened.
---@param win integer
---@return boolean
local function usable(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return false
  end
  -- `winfixbuf` only exists from Neovim 0.11, and reading it on an older one would error.
  if vim.fn.exists('&winfixbuf') == 1 and vim.wo[win].winfixbuf then
    return false
  end

  return vim.bo[vim.api.nvim_win_get_buf(win)].filetype:sub(1, 7) ~= 'sqmeow-'
end

--- A window an ordinary file belongs in.
---@return integer win Focused, and guaranteed to accept a file.
function M.editing_window()
  -- The current window first.
  local candidates = { vim.api.nvim_get_current_win() }
  if saved then
    table.insert(candidates, saved.win)
  end
  vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(0))

  for _, win in ipairs(candidates) do
    if usable(win) then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end

  -- Every window in this tab belongs to the plugin.
  if vim.bo.filetype == 'sqmeow-drawer' then
    -- Beside the sidebar, which is where an editor sits in the layout the sidebar is part of.
    vim.cmd('rightbelow vnew')
  else
    vim.cmd('topleft new')
  end

  return vim.api.nvim_get_current_win()
end

--- Close one of the plugin's windows, or empty it when it is the last one left.
---@param win integer
function M.close_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  -- Floats do not count.
  local others = vim.tbl_filter(function(other)
    return other ~= win and vim.api.nvim_win_get_config(other).relative == ''
  end, vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)))
  if #others > 0 then
    return vim.api.nvim_win_close(win, true)
  end
  vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
end

--- Forget the recorded layout without applying it.
function M.forget()
  saved = nil
end

--- Whether a layout is waiting to be restored.
---@return boolean
function M.is_remembered()
  return saved ~= nil
end

return M
