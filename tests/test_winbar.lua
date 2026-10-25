local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local config = require('sqmeow.config')
local editor = require('sqmeow.ui.editor')
local result = require('sqmeow.ui.result')
local state = require('sqmeow.core.state')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      pcall(result.close)
      result.forget()
      state.reset()
      config.apply({})
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and buf ~= vim.api.nvim_get_current_buf() then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end,
  },
})

T['granular winbar toggles editor, result, and connection label independently'] = function()
  state.add_connection({
    id = 1,
    name = 'dev',
    url = 'sqlite://:memory:',
    dialect = 'sqlite',
    state = 'connected',
  })
  local ed_buf = vim.api.nvim_get_current_buf()
  editor.attach(ed_buf, 'dev')
  eq(vim.wo.winbar:find('dev', 1, true) ~= nil, true)

  config.apply({
    ui = {
      winbar = {
        editor = false,
        result = true,
        show_connection = false,
      },
    },
  })
  editor.update_winbar()
  eq(vim.wo.winbar, '')

  local rwin = result.open()
  state.call = {
    call_id = 2,
    conn_id = 1,
    state = 'done',
    rows = 3,
    elapsed_ms = 4,
    columns = {
      { name = 'id', type_name = 'int4', class = 'number', nulls = false, numeric = true },
    },
  }
  result.update_winbar(state.call)
  eq(vim.wo[rwin].winbar:find('SqmeowWinbar', 1, true), nil)
  eq(vim.wo[rwin].winbar:find('3 rows', 1, true) ~= nil, true)

  -- Disabling result winbar clears sqmeow's winbar, but preserves externally owned winbars.
  config.apply({
    ui = {
      winbar = {
        editor = true,
        result = false,
        show_connection = false,
      },
    },
  })
  result.update_winbar(state.call)
  eq(vim.wo[rwin].winbar, '')
  vim.wo[rwin].winbar = 'external-winbar'
  result.update_winbar(state.call)
  eq(vim.wo[rwin].winbar, 'external-winbar')
end

return T
