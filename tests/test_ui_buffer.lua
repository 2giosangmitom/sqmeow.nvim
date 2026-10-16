local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local buffer = require('sqmeow.ui.buffer')

local name = 'sqmeow://test-scratch-reuse'
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      local handle = vim.fn.bufnr(name)
      if handle ~= -1 then
        vim.api.nvim_buf_delete(handle, { force = true })
      end
    end,
  },
})

T['reuses a named buffer and normalizes its options'] = function()
  local handle = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(handle, name)
  vim.api.nvim_buf_set_lines(handle, 0, -1, false, { 'restored result' })
  vim.bo[handle].filetype = 'text'

  eq(buffer.scratch(name, 'sqmeow-result', true), handle)
  eq(vim.api.nvim_buf_get_lines(handle, 0, -1, false), { 'restored result' })
  eq(vim.bo[handle].buftype, 'nofile')
  eq(vim.bo[handle].bufhidden, 'hide')
  eq(vim.bo[handle].swapfile, false)
  eq(vim.bo[handle].filetype, 'sqmeow-result')
  eq(vim.bo[handle].modifiable, false)
  eq(vim.bo[handle].buflisted, true)
end

T['creates a named scratch buffer when none exists'] = function()
  local handle = buffer.scratch(name, 'sqmeow-result', false)
  eq(vim.api.nvim_buf_get_name(handle), name)
  eq(vim.bo[handle].buflisted, false)
  eq(vim.bo[handle].buftype, 'nofile')
end

return T
