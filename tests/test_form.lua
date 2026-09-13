local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local form = require('sqmeow.ui.form')
local config = require('sqmeow.config')

--- Close whatever the dialog left open, so one case cannot leak a window into the next.
local function close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    -- Closing a dialog takes its border window with it, so a handle from this list may already be
    -- gone by the time the loop reaches it.
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= '' then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- The dialog's own window, and the lines it drew.
---@return integer|nil winid
---@return string[] lines
local function dialog()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == 'sqmeow-form' then
      return win, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  return nil, {}
end

--- The single-line editor the dialog opens over a field.
---@return integer|nil winid
local function editing()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'prompt' then
      return win
    end
  end
  return nil
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.apply({})
      if not form.available() then
        MiniTest.skip('nui.nvim is not installed')
      end
    end,
    post_case = function()
      close_floats()
      config.apply({})
    end,
  },
})

T['opens with a line per field'] = function()
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host' }, { key = 'port', label = 'Port' } },
    values = { host = 'db.internal', port = '5432' },
    on_submit = function() end,
  })

  local _, lines = dialog()
  eq(#lines, 2)
  eq(vim.trim(lines[1]), 'Host  db.internal')
  eq(vim.trim(lines[2]), 'Port  5432')
end

T['shows a hint where a value is missing'] = function()
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host', hint = 'localhost' } },
    on_submit = function() end,
  })

  local _, lines = dialog()
  eq(vim.trim(lines[1]), 'Host  localhost')
end

T['draws a masked field as asterisks'] = function()
  form.open({
    title = 'New connection',
    fields = { { key = 'password', label = 'Password', mask = true } },
    values = { password = 'hunter2' },
    on_submit = function() end,
  })

  local _, lines = dialog()
  eq(vim.trim(lines[1]), 'Password  *******')
end

T['saving'] = MiniTest.new_set()

T['saving']['hands back what was filled in'] = function()
  local got
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host' } },
    values = { host = 'db.internal' },
    on_submit = function(values)
      got = values
    end,
  })

  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'x', false)
  vim.wait(50)
  eq(got, { host = 'db.internal' })
  eq(dialog(), nil)
end

T['saving']['stays open when the answers cannot work'] = function()
  local submitted = false
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host' } },
    validate = function()
      return 'Host cannot be empty'
    end,
    on_submit = function()
      submitted = true
    end,
  })

  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'x', false)
  vim.wait(50)
  eq(submitted, false)
  MiniTest.expect.no_equality(dialog(), nil)
end

T['saving']['closes without a word when cancelled'] = function()
  local cancelled = false
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host' } },
    on_submit = function() end,
    on_cancel = function()
      cancelled = true
    end,
  })

  vim.api.nvim_feedkeys('q', 'x', false)
  vim.wait(50)
  eq(cancelled, true)
  eq(dialog(), nil)
end

T['editing'] = MiniTest.new_set()

T['editing']['starts at the first field in wizard mode'] = function()
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host' } },
    wizard = true,
    on_submit = function() end,
  })

  vim.wait(50)
  MiniTest.expect.no_equality(editing(), nil)
end

T['editing']['waits to be asked when a field is being changed'] = function()
  form.open({
    title = 'Edit',
    fields = { { key = 'host', label = 'Host' } },
    values = { host = 'db.internal' },
    on_submit = function() end,
  })

  vim.wait(50)
  eq(editing(), nil)
end

T['editing']['hides what is typed into a masked field'] = function()
  form.open({
    title = 'New connection',
    fields = { { key = 'password', label = 'Password', mask = true } },
    wizard = true,
    on_submit = function() end,
  })

  vim.wait(50)
  local win = editing()
  MiniTest.expect.no_equality(win, nil)
  eq(vim.wo[win].conceallevel, 2)
  -- Insert mode included, so the password is not on screen while it is being entered.
  eq(vim.wo[win].concealcursor, 'nvic')
  eq(vim.fn.getmatches(win)[1].conceal, '*')
end

T['editing']['leaves an ordinary field readable'] = function()
  form.open({
    title = 'New connection',
    fields = { { key = 'host', label = 'Host' } },
    wizard = true,
    on_submit = function() end,
  })

  vim.wait(50)
  eq(vim.wo[editing()].conceallevel, 0)
end

T['menu'] = MiniTest.new_set()

T['menu']['lists what it was given, with icons'] = function()
  form.menu({
    title = 'Connect to',
    items = {
      { label = 'PostgreSQL', icon = 'P', value = 'postgres' },
      { label = 'SQLite', icon = 'S', value = 'sqlite' },
    },
    on_choice = function() end,
  })

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(vim.trim(lines[1]), 'P PostgreSQL')
  eq(vim.trim(lines[2]), 'S SQLite')
end

return T
