local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local config = require('sqmeow.config')
local edit = require('sqmeow.ui.edit')
local editor = require('sqmeow.ui.editor')
local result = require('sqmeow.ui.result')
local state = require('sqmeow.core.state')
local statusline = require('sqmeow.statusline')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      pcall(result.close)
      result.forget()
      edit.reset()
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

T['statusline is inactive on ordinary non-database buffers'] = function()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].filetype = 'lua'
  eq(statusline.active(buf), false)
  eq(statusline.status(buf), nil)
  eq(statusline.component(buf), '')
end

T['statusline reports connection and query telemetry for SQL editor buffers'] = function()
  state.add_connection({
    id = 1,
    name = 'analytics',
    url = 'postgres://localhost/analytics',
    dialect = 'postgres',
    state = 'connected',
    read_only = true,
  })
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].filetype = 'sql'
  vim.b[buf].sqmeow_connection = 'analytics'

  eq(statusline.active(buf), true)
  eq(statusline.component(buf), '󰆼 analytics 󰌾')

  state.call = {
    call_id = 10,
    conn_id = 1,
    state = 'executing',
  }
  eq(statusline.component(buf), '󰆼 analytics 󰌾 ·  running…')

  state.call = {
    call_id = 10,
    conn_id = 1,
    state = 'done',
    rows = 142,
    elapsed_ms = 12,
    columns = { { name = 'id', type_name = 'int4', class = 'number' } },
  }
  eq(statusline.component(buf), '󰆼 analytics 󰌾 · 142 rows · 12ms · p1/2')

  -- A buffer bound to a different connection does not show another connection's call telemetry.
  local other = vim.api.nvim_create_buf(true, true)
  vim.bo[other].filetype = 'sql'
  vim.b[other].sqmeow_connection = 'staging'
  eq(statusline.component(other), '󰆼 staging')
end

T['statusline reports column under cursor and filter/edit badges in result grid'] = function()
  state.add_connection({
    id = 1,
    name = 'dev',
    url = 'sqlite://:memory:',
    dialect = 'sqlite',
    state = 'connected',
  })
  local win = result.open()
  vim.api.nvim_set_current_win(win)

  state.call = {
    call_id = 1,
    conn_id = 1,
    state = 'done',
    rows = 10,
    view_rows = 4,
    elapsed_ms = 5,
    columns = {
      { name = 'user_id', type_name = 'INTEGER', class = 'number' },
      { name = 'email', type_name = 'TEXT', class = 'text' },
    },
  }
  result.spec().where = 'user_id > 2'
  result.redraw()
  vim.api.nvim_win_set_cursor(win, { 1, 2 })

  eq(statusline.column(), '󰠵 user_id (integer)')
  result.goto_column(2)
  eq(statusline.column(), '󰠵 email (text)')
  eq(statusline.component(), '󰆼 dev · 4/10 rows · 5ms · 󰈲')

  edit.set({ row = 0 }, 1, 'new@example.com')
  eq(statusline.component(), '󰆼 dev · 4/10 rows · 5ms · 󰈲 · ●')
end

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
    columns = { { name = 'id', type_name = 'int4', class = 'number' } },
  }
  result.update_winbar(state.call)
  eq(vim.wo[rwin].winbar:find('SqmeowWinbar', 1, true), nil)
  eq(vim.wo[rwin].winbar:find('3 rows', 1, true) ~= nil, true)
end

return T
