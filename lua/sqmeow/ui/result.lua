--- The result grid window.
---
--- The buffer's lines are written by the engine, not from here. This module only decides that the
--- buffer exists, where its window is, and what the winbar above it says.

local M = {}

local buf = nil
local win = nil

local function valid_buf()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Round a duration for display, keeping it short without lying about the magnitude.
---@param ms integer
---@return string
function M.format_duration(ms)
  if ms < 1000 then
    return ('%dms'):format(ms)
  end
  return ('%.2fs'):format(ms / 1000)
end

--- Describe a result for the winbar.
---
---@param summary sqmeow.CallSummary|nil
---@return string
function M.describe(summary)
  if not summary then
    return 'sqmeow'
  end

  if summary.state == 'executing' then
    return 'running…'
  end
  if summary.state == 'error' then
    return 'error: ' .. (summary.error or 'unknown')
  end
  if summary.state == 'cancelled' then
    return 'cancelled'
  end

  local parts = {}

  if summary.rows and summary.rows > 0 then
    table.insert(parts, ('%d row%s'):format(summary.rows, summary.rows == 1 and '' or 's'))
  elseif summary.affected then
    table.insert(
      parts,
      ('%d row%s affected'):format(summary.affected, summary.affected == 1 and '' or 's')
    )
  else
    table.insert(parts, 'no rows')
  end

  if summary.truncated then
    table.insert(parts, 'truncated')
  end
  if summary.pages and summary.pages > 1 then
    table.insert(parts, ('page %d/%d'):format(summary.page, summary.pages))
  end
  if summary.elapsed_ms then
    table.insert(parts, M.format_duration(summary.elapsed_ms))
  end

  return table.concat(parts, '  ')
end

--- The result buffer, created on first use.
---@return integer buf
function M.buffer()
  if valid_buf() then
    return buf
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'sqmeow://result')

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'sqmeow-result'
  -- The engine lifts this around each paint. Between paints the grid is not something to type in.
  vim.bo[buf].modifiable = false

  M.apply_keymaps(buf)
  return buf
end

--- Bind the result buffer's keys.
---
--- Buffer-local only: the plugin takes no key outside its own windows. These move into the
--- declarative keymap table when the drawer lands and there is more than one surface to keep
--- consistent.
---@param target integer Buffer handle.
function M.apply_keymaps(target)
  local api = require('sqmeow.api')
  local maps = {
    { 'L', api.next_page, 'Next page' },
    { 'H', api.prev_page, 'Previous page' },
    { 'gg', api.first_page, 'First page' },
    { 'G', api.last_page, 'Last page' },
    { 'q', M.close, 'Close the result window' },
  }

  for _, entry in ipairs(maps) do
    vim.keymap.set('n', entry[1], entry[2], {
      buffer = target,
      nowait = true,
      desc = 'sqmeow: ' .. entry[3],
    })
  end
end

--- Show the result window, creating it if needed.
---@return integer win
function M.open()
  if valid_win() then
    return win
  end

  local config = require('sqmeow.config').get()
  local previous = vim.api.nvim_get_current_win()

  vim.cmd(('botright %dsplit'):format(config.ui.result.height))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M.buffer())

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  -- Other splits must not squash the grid, which would silently hide columns.
  vim.wo[win].winfixheight = true

  -- Opening a result should not steal the cursor from the query being written.
  vim.api.nvim_set_current_win(previous)
  return win
end

--- Hide the result window, keeping the buffer and its contents.
function M.close()
  if valid_win() then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

--- Whether the result window is showing.
---@return boolean
function M.is_open()
  return valid_win()
end

--- Update the line above the grid.
---
---@param summary sqmeow.CallSummary|nil
function M.update_winbar(summary)
  if not valid_win() or not require('sqmeow.config').get().ui.winbar then
    return
  end

  local connection = require('sqmeow.state').current_connection()
  local label = connection and ('%s (%s)'):format(connection.name, connection.dialect or '?')
    or 'not connected'

  vim.wo[win].winbar = ('%%#SqmeowWinbar# %s  %%*%s'):format(label, M.describe(summary))
end

return M
