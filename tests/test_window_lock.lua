local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = vim.api
local layout = require('sqmeow.ui.layout')
local drawer = require('sqmeow.ui.drawer')
local result = require('sqmeow.ui.result')
local previous

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      previous = layout.editing_window()
      require('sqmeow.core.state').reset()
      helpers.stub(require('sqmeow.rpc.events'), 'ensure', function() end)
      result.render(nil)
    end,
    post_case = function()
      result.close()
      drawer.close()
      if api.nvim_win_is_valid(previous) then
        layout.fixbuf(previous, false)
        api.nvim_set_current_win(previous)
      end
      layout.forget()
    end,
  },
})

local function needs_lock()
  if vim.fn.exists('&winfixbuf') ~= 1 then
    MiniTest.skip('winfixbuf needs Neovim 0.11+')
  end
end

local function refuses_edit(win)
  needs_lock()
  local buf = api.nvim_win_get_buf(win)
  local path = helpers.temp_file({ 'ordinary file' })
  local ok, err = pcall(api.nvim_win_call, win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  eq(ok, false)
  helpers.contains(err, 'E1513')
  eq(api.nvim_win_get_buf(win), buf)
end

T['drawer refuses edit'] = function()
  refuses_edit(drawer.open())
end

T['result split refuses edit'] = function()
  refuses_edit(result.open())
end

T['result float refuses edit'] = function()
  refuses_edit(result.open_float())
end

T['own swaps preserve the lock unless released'] = function()
  needs_lock()
  layout.fixbuf(previous)
  local buf = helpers.temp_buf()
  layout.set_buffer(previous, buf)
  eq(api.nvim_win_get_buf(previous), buf)
  eq(vim.wo[previous].winfixbuf, true)
  layout.set_buffer(previous, helpers.temp_buf(), { release = true })
  eq(vim.wo[previous].winfixbuf, false)
end

T['failed swaps restore the lock even when release was requested'] = function()
  needs_lock()
  for _, opts in ipairs({ {}, { release = true } }) do
    layout.fixbuf(previous)
    local buf = api.nvim_win_get_buf(previous)
    local ok, err = pcall(layout.set_buffer, previous, -1, opts)
    eq(ok, false)
    helpers.contains(err, 'buffer')
    eq(api.nvim_win_get_buf(previous), buf)
    eq(vim.wo[previous].winfixbuf, true)
  end
end

T['current-window swaps restore the original window after focus changes'] = function()
  needs_lock()
  local win = result.open()
  api.nvim_set_current_win(win)
  local set_buf = api.nvim_win_set_buf
  helpers.stub(api, 'nvim_win_set_buf', function(target, buf)
    set_buf(target, buf)
    api.nvim_set_current_win(previous)
  end)
  layout.set_buffer(0, helpers.temp_buf())
  eq(vim.wo[win].winfixbuf, true)
  eq(vim.wo[previous].winfixbuf, false)
end

T['swaps tolerate a window closed during buffer assignment'] = function()
  needs_lock()
  local win = result.open()
  local set_buf = api.nvim_win_set_buf
  helpers.stub(api, 'nvim_win_set_buf', function(target, buf)
    set_buf(target, buf)
    api.nvim_win_close(target, true)
  end)
  layout.set_buffer(win, helpers.temp_buf())
  eq(api.nvim_win_is_valid(win), false)
end

T['reopening and toggling the result keep its lock'] = function()
  needs_lock()
  local win = result.open()
  eq(result.open(), win)
  result.toggle_float()
  eq(result.is_float(), true)
  refuses_edit(result.open_float())
  result.toggle_float()
  eq(result.is_float(), false)
  refuses_edit(result.open())
end

T['last plugin window is released for editing'] = function()
  needs_lock()
  local win = result.open()
  api.nvim_win_close(previous, true)
  previous = win
  result.close()
  eq(api.nvim_win_is_valid(win), true)
  eq(vim.wo[win].winfixbuf, false)
  local path = helpers.temp_file({ 'ordinary file' })
  vim.cmd.edit(vim.fn.fnameescape(path))
  eq(api.nvim_buf_get_name(0), path)
end

T['editing from a plugin window leaves its buffer locked'] = function()
  needs_lock()
  local win = result.open()
  api.nvim_win_close(previous, true)
  api.nvim_set_current_win(win)
  previous = layout.editing_window()
  eq(previous ~= win, true)
  eq(vim.wo[previous].winfixbuf, false)
  eq(vim.wo[win].winfixbuf, true)
end

T['unsupported option leaves buffer switching unchanged'] = function()
  local exists = vim.fn.exists
  helpers.stub(vim.fn, 'exists', function(name)
    return name == '&winfixbuf' and 0 or exists(name)
  end)
  layout.fixbuf(previous)
  local buf = helpers.temp_buf()
  layout.set_buffer(previous, buf)
  eq(api.nvim_win_get_buf(previous), buf)
end

return T
