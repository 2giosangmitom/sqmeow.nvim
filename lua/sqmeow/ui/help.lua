--- The `?` cheatsheet.

local M = {}

local utils = require('sqmeow.utils')

local popup = nil

--- The lines describing one surface's mappings.
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
---@param surface string
function M.open(surface)
  M.close()

  local lines = M.lines(surface)
  if #lines == 0 then
    utils.notify('this surface has no mappings')
    return
  end

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local opened, open_err = require('sqmeow.ui.popup').open({
    title = ' ' .. surface .. ' ',
    lines = lines,
    width = math.min(width + 2, vim.o.columns - 4),
    height = math.min(#lines, vim.o.lines - 4),
    on_close = M.close,
    extra_maps = { { mode = 'n', lhs = '?', handler = M.close } },
  })
  if not opened then
    utils.notify(open_err or 'could not open the popup', vim.log.levels.ERROR)
    return
  end
  popup = opened
end

return M
