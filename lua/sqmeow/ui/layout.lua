--- Putting the user's windows back.
---
--- The plugin only ever adds windows, so restoring means closing what it opened and giving the
--- surrounding windows their sizes back. Leaving someone's carefully arranged splits resized after
--- they close a database client is the kind of small rudeness that makes a plugin unwelcome.

local M = {}

local saved = nil

--- Whether any plugin window is showing.
---@return boolean
function M.anything_open()
  return require('sqmeow.ui.drawer').is_open() or require('sqmeow.ui.result').is_open()
end

--- Record the current layout, if this is the first plugin window to open.
---
--- Only the first one records: opening the result window after the drawer must not overwrite the
--- layout that existed before either of them.
function M.remember()
  if saved or M.anything_open() then
    return
  end

  -- By window rather than with `winrestcmd()`, which names windows by number and counts floats. A
  -- notification open now and gone later shifts every number after it, and the command then sizes
  -- the wrong window: `2resize 1` meant for that notification lands on the editor, squeezing it to
  -- one line.
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

  -- Only the arrangement that was recorded is put back. A window opened or closed since then means
  -- the sizes describe some other layout, and a lone window already fills the screen: forcing a
  -- size on it only hands the rest to the command line.
  local now = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ''
  end, vim.api.nvim_tabpage_list_wins(0))
  local same = #now == vim.tbl_count(restore.sizes)
    and vim.iter(now):all(function(win)
      return restore.sizes[win] ~= nil
    end)

  -- Sizes first, then the cursor, so the window it lands in is already the right size. Twice, as
  -- `winrestcmd()` does, because setting one window's size moves its neighbours'.
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
---
--- The plugin's own surfaces all name themselves in their filetype, and none of them is a place
--- for a file: the drawer is a sidebar and the result is a grid, and opening a file in either
--- replaces a surface the user still wants to see. A float belongs to whoever opened it, and a
--- window pinned to its buffer refuses a new one outright. Another tab is not this tab, and
--- opening a file should not move anyone between them.
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
---
--- Opening a scratchpad from the drawer must not put it in the drawer, which is what a plain
--- `:edit` does, because the drawer is the window the key was pressed in.
---
--- A dashboard is a fair target: replacing one is what opening a file in it has always done.
---
---@return integer win Focused, and guaranteed to accept a file.
function M.editing_window()
  -- The current window first, because someone who ran a command from a window they can type in
  -- meant that window. Then the one the plugin was opened from, which is where they were before a
  -- surface took the focus. Then anything else in this tab.
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

  -- Every window in this tab belongs to the plugin, so there is nowhere to put a file but a new
  -- one. `vnew` and `new` rather than a split, which would clone the surface being avoided.
  if vim.bo.filetype == 'sqmeow-drawer' then
    -- Beside the sidebar, which is where an editor sits in the layout the sidebar is part of.
    vim.cmd('rightbelow vnew')
  else
    vim.cmd('topleft new')
  end

  return vim.api.nvim_get_current_win()
end

--- Close one of the plugin's windows, or empty it when it is the last one left.
---
--- Neovim refuses to close the last window in a tab, and `q` in a result grid that happens to be
--- the only window should not throw. Putting an ordinary buffer there instead leaves the user
--- somewhere they can type, which is what closing the surface was for.
---
---@param win integer
function M.close_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  -- Floats do not count: a tab whose only other windows float over this one still has this as its
  -- last window, and Neovim refuses to close it.
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
