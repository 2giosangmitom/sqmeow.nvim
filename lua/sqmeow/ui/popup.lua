--- Single centered popup used by detail, structure and similar floats.
---
--- Groups the repeated nui.Popup boilerplate: border style, mount,
--- `q`/`<Esc>`/BufLeave close, and painting NuiLine or string rows.
--- Callers require this file directly; there is no re-export.

local M = {}

---@class sqmeow.PopupSpec
---@field title string Title shown in the border.
---@field lines any[] NuiLine[] (with `content()`/`highlight()`) or plain strings.
---@field width integer
---@field height integer
---@field filetype string|nil Buffer filetype.
---@field on_close fun() Close callback for mappings and BufLeave.
---@field bottom string|nil Bottom border text.
---@field zindex integer|nil Nui zindex, default 50.
---@field extra_maps table|nil Extra `{ mode, lhs, handler }` mappings.

---@param spec sqmeow.PopupSpec
---@return any|nil popup Mounted nui popup.
---@return string|nil err
function M.open(spec)
  local utils = require('sqmeow.utils')
  local nui, nui_err = utils.nui({ 'popup' }, 'the popup')
  if not nui then
    return nil, nui_err
  end

  local border_text = { top = spec.title, top_align = 'center' }
  if spec.bottom then
    border_text.bottom = spec.bottom
    border_text.bottom_align = 'center'
  end
  local popup = nui.Popup({
    enter = true,
    focusable = true,
    relative = 'editor',
    position = '50%',
    size = { width = spec.width, height = spec.height },
    zindex = spec.zindex or 50,
    border = {
      style = require('sqmeow.config').border(),
      text = border_text,
    },
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'wipe',
      swapfile = false,
      filetype = spec.filetype,
    },
    win_options = { cursorline = true, wrap = false, number = false, relativenumber = false },
  })
  popup:mount()
  popup:map('n', 'q', spec.on_close, { nowait = true })
  popup:map('n', '<Esc>', spec.on_close, { nowait = true })
  for _, map in ipairs(spec.extra_maps or {}) do
    popup:map(map.mode, map.lhs, map.handler, { nowait = true })
  end
  popup:on('BufLeave', spec.on_close, { once = true })

  local first = spec.lines[1]
  if first ~= nil and type(first) == 'table' and first.content ~= nil then
    local namespace = vim.api.nvim_create_namespace('sqmeow.popup')
    vim.api.nvim_buf_set_lines(
      popup.bufnr,
      0,
      -1,
      false,
      vim.tbl_map(function(line)
        return line:content()
      end, spec.lines)
    )
    for index, line in ipairs(spec.lines) do
      line:highlight(popup.bufnr, namespace, index)
    end
  else
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, spec.lines)
  end
  vim.bo[popup.bufnr].modifiable = false
  return popup
end

return M
