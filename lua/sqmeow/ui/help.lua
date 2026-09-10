--- The `?` cheatsheet.
---
--- Built from the same table the mappings come from, so it cannot describe a key the surface does
--- not actually have, and a user's override shows up here without anything else being touched.

local M = {}

local win = nil

--- The lines describing one surface's mappings.
---
---@param surface string
---@return string[]
function M.lines(surface)
  local entries = vim.tbl_filter(function(entry)
    return #entry.lhs > 0
  end, require('sqmeow.keymap').resolve(surface))

  local widest = 0
  local keys = {}
  for index, entry in ipairs(entries) do
    keys[index] = table.concat(entry.lhs, ', ')
    widest = math.max(widest, vim.fn.strdisplaywidth(keys[index]))
  end

  local lines = {}
  for index, entry in ipairs(entries) do
    local padding = (' '):rep(widest - vim.fn.strdisplaywidth(keys[index]))
    table.insert(lines, (' %s%s   %s'):format(keys[index], padding, entry.desc))
  end
  return lines
end

--- Close the cheatsheet, if it is showing.
function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

--- Show one surface's mappings in a float.
---
---@param surface string
function M.open(surface)
  M.close()

  local lines = M.lines(surface)
  if #lines == 0 then
    vim.notify('sqmeow: this surface has no mappings')
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(width + 2, vim.o.columns - 4),
    height = math.min(#lines, vim.o.lines - 4),
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = require('sqmeow.config').get().ui.border,
    title = ' ' .. surface .. ' ',
  })

  -- Any of the usual ways of dismissing a float works, so nobody has to guess.
  for _, lhs in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', lhs, M.close, { buffer = buf, nowait = true, desc = 'sqmeow: Close' })
  end
end

return M
