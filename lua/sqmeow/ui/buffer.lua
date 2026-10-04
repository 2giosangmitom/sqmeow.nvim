--- Scratch buffers shared by result, drawer previews and similar views.
---
--- Groups the repeated `nvim_create_buf` + `nofile`/`hide` + `swapfile=false`
--- setup. Callers require this file directly; there is no re-export.

local M = {}

---@param name string Buffer name, e.g. `sqmeow://result`.
---@param filetype string Buffer filetype.
---@param listed boolean|nil Passed to `nvim_create_buf`, default false.
---@return integer bufnr
function M.scratch(name, filetype, listed)
  local handle = vim.api.nvim_create_buf(listed == true, true)
  vim.api.nvim_buf_set_name(handle, name)

  vim.bo[handle].buftype = 'nofile'
  vim.bo[handle].bufhidden = 'hide'
  vim.bo[handle].swapfile = false
  vim.bo[handle].filetype = filetype
  vim.bo[handle].modifiable = false

  return handle
end

---@param bufnr integer
---@param lines string[]
function M.set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

return M
