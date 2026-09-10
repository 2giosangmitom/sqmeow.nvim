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

  saved = {
    sizes = vim.fn.winrestcmd(),
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

  -- Sizes first, then the cursor, so the window it lands in is already the right size.
  pcall(vim.cmd, restore.sizes)
  if vim.api.nvim_win_is_valid(restore.win) then
    pcall(vim.api.nvim_set_current_win, restore.win)
  end
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
