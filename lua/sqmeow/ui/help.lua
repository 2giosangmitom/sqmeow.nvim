--- The `?` cheatsheet.
---
--- Built from the same table the mappings come from, so it cannot describe a key the surface does
--- not actually have, and a user's override shows up here without anything else being touched.

local M = {}

local utils = require('sqmeow.utils')

local popup = nil

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
    -- Two surfaces bind `<CR>` twice, once per mode, and a list that showed them as the same key
    -- twice would be a puzzle rather than a reference.
    if entry.mode ~= 'n' then
      keys[index] = ('%s (%s)'):format(keys[index], entry.mode)
    end
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
  if popup then
    popup:unmount()
  end
  popup = nil
end

--- Show one surface's mappings in a float.
---
---@param surface string
function M.open(surface)
  M.close()

  local lines = M.lines(surface)
  if #lines == 0 then
    utils.notify('this surface has no mappings')
    return
  end

  local nui, err = utils.nui({ 'popup' }, 'the help float')
  if not nui then
    utils.notify(err, vim.log.levels.ERROR)
    return
  end
  local Popup = nui.Popup

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  popup = Popup({
    enter = true,
    focusable = true,
    position = '50%',
    size = {
      width = math.min(width + 2, vim.o.columns - 4),
      height = math.min(#lines, vim.o.lines - 4),
    },
    border = {
      style = require('sqmeow.config').border(),
      text = { top = ' ' .. surface .. ' ' },
    },
    buf_options = { modifiable = true, readonly = false },
    win_options = { number = false, relativenumber = false, signcolumn = 'no' },
  })

  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.bo[popup.bufnr].modifiable = false

  -- Any of the usual ways of dismissing a float works, so nobody has to guess.
  popup:on('BufLeave', M.close, { once = true })
  for _, lhs in ipairs({ 'q', '<Esc>', '?' }) do
    popup:map('n', lhs, M.close, { nowait = true })
  end
end

return M
