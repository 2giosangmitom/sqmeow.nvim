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

T['non-row statements render summary in result buffer when result winbar is disabled'] = function()
  config.apply({ ui = { winbar = false } })
  result.open()
  local handle = result.buffer()
  local ns = vim.api.nvim_create_namespace('sqmeow')

  -- Executing state renders with Comment highlight.
  state.call = {
    call_id = 10,
    conn_id = 1,
    state = 'executing',
  }
  result.render(state.call)
  eq(vim.api.nvim_buf_get_lines(handle, 0, -1, false), { 'running…' })
  local marks = vim.api.nvim_buf_get_extmarks(handle, ns, 0, -1, { details = true })
  eq(#marks, 1)
  eq(marks[1][4].hl_group, 'Comment')

  -- Completed DML (UPDATE/DELETE/INSERT) renders affected row count and duration with SqmeowSignAdded.
  state.call = {
    call_id = 11,
    conn_id = 1,
    state = 'done',
    affected = 2,
    elapsed_ms = 5,
    columns = {},
  }
  result.render(state.call)
  local lines = vim.api.nvim_buf_get_lines(handle, 0, -1, false)
  eq(#lines, 1)
  eq(lines[1]:find('2 rows affected', 1, true) ~= nil, true)
  eq(lines[1]:find('5ms', 1, true) ~= nil, true)
  marks = vim.api.nvim_buf_get_extmarks(handle, ns, 0, -1, { details = true })
  eq(#marks, 1)
  eq(marks[1][4].hl_group, 'SqmeowSignAdded')

  -- Transitioning from a non-grid line ("running…" / "2 rows affected" / error) to a grid result
  -- replaces the buffer cleanly without leaving the previous text underneath the table.
  config.apply({ ui = { winbar = false } })
  state.call = {
    call_id = 12,
    conn_id = 1,
    state = 'executing',
  }
  result.render(state.call)
  eq(vim.api.nvim_buf_get_lines(handle, 0, -1, false), { 'running…' })

  local rpc = require('sqmeow.rpc.client')
  local orig_request = rpc.request
  rpc.request = function(method)
    if method == 'rows' then
      return { rows = { { '1' } }, indices = { 1 }, total = 1 }
    end
  end
  state.call = {
    call_id = 12,
    conn_id = 1,
    state = 'done',
    rows = 1,
    elapsed_ms = 2,
    columns = {
      { name = 'id', type_name = 'int4', class = 'number', nulls = false, numeric = true },
    },
  }
  result.render(state.call)
  rpc.request = orig_request

  local grid_lines = vim.api.nvim_buf_get_lines(handle, 0, -1, false)
  for _, line in ipairs(grid_lines) do
    eq(line:find('running…', 1, true), nil)
    eq(line:find('rows affected', 1, true), nil)
  end

  -- Re-enabling the result winbar clears the fallback line from the buffer body on non-row calls.
  state.call = {
    call_id = 13,
    conn_id = 1,
    state = 'done',
    affected = 1,
    elapsed_ms = 3,
    columns = {},
  }
  result.render(state.call)
  config.apply({ ui = { winbar = true } })
  result.update_winbar(state.call)
  eq(vim.api.nvim_buf_get_lines(handle, 0, -1, false), { '' })
end

return T
