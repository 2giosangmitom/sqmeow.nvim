local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = vim.api
local result = require('sqmeow.ui.result')
local state = require('sqmeow.core.state')
local config = require('sqmeow.config')
local grid, previous, windows

local function update()
  local previous_error = vim.v.errmsg
  vim.v.errmsg = ''
  api.nvim_exec_autocmds('WinScrolled', {
    group = 'sqmeow_result_' .. result.buffer(),
    pattern = tostring(grid),
  })
  local err = vim.v.errmsg
  vim.v.errmsg = previous_error
  eq(err, '')
end

local function scroll(topline)
  api.nvim_win_call(grid, function()
    api.nvim_win_set_cursor(grid, { topline, 0 })
    vim.fn.winrestview({ topline = topline })
  end)
end

local function preview(anchor)
  local id = api.nvim_open_win(result.buffer(), false, {
    relative = 'win',
    win = anchor,
    row = 0,
    col = 0,
    width = api.nvim_win_get_width(grid),
    height = 1,
    focusable = false,
    border = 'none',
    noautocmd = true,
    zindex = 45,
  })
  vim.wo[id].winbar = ''
  return id
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      windows = api.nvim_list_wins()
      previous = api.nvim_get_current_win()
      state.reset()
      result.render(nil)
      config.apply({
        ui = {
          result = { height = 8, page_size = 100, max_column_width = 200, sticky_header = false },
        },
      })
      helpers.stub(require('sqmeow.rpc.events'), 'ensure', function() end)
      local rows = {}
      for i = 1, 100 do
        rows[i] = { ('row %d %s'):format(i, string.rep('x', 160)) }
      end
      helpers.stub(require('sqmeow.rpc.client'), 'request', function(method)
        eq(method, 'rows')
        return { rows = rows, indices = vim.fn.range(0, 99), total = #rows }
      end)
      state.call = {
        call_id = 1,
        state = 'done',
        rows = #rows,
        columns = {
          { name = 'text', type_name = 'text', class = 'text', numeric = false, nulls = false },
        },
      }
      result.render(state.call)
      grid = result.open()
      vim.wo[grid].winbar = 'grid winbar'
      scroll(1)
      config.get().ui.result.sticky_header = true
    end,
    post_case = function()
      result.close()
      for _, id in ipairs(api.nvim_list_wins()) do
        if not vim.tbl_contains(windows, id) then
          api.nvim_win_close(id, true)
        end
      end
      state.reset()
      config.apply({})
    end,
  },
})

T['opens one row from the grid context without moving focus'] = function()
  local open = api.nvim_open_win
  helpers.stub(api, 'nvim_open_win', function(buf, enter, opts)
    eq(api.nvim_get_current_win(), grid)
    eq(opts.height, 1)
    eq(opts.style, nil)
    return open(buf, enter, opts)
  end)

  scroll(20)
  update()

  local header = assert(result.sticky_window())
  eq(api.nvim_win_get_height(header), 1)
  eq(vim.wo[header].winbar, '')
  eq(vim.wo[grid].winbar, 'grid winbar')
  eq(api.nvim_win_get_buf(header), result.buffer())
  eq(api.nvim_get_current_win(), previous)
end

T['reuses the header and copies the grid gutter and horizontal scroll'] = function()
  vim.wo[grid].number = true
  vim.wo[grid].numberwidth = 6
  vim.wo[grid].signcolumn = 'yes'
  api.nvim_win_call(grid, function()
    api.nvim_win_set_cursor(grid, { 20, 30 })
    vim.fn.winrestview({ topline = 20, leftcol = 12 })
  end)
  update()
  local header = assert(result.sticky_window())
  local count = #api.nvim_list_wins()

  update()

  eq(result.sticky_window(), header)
  eq(#api.nvim_list_wins(), count)
  eq(api.nvim_win_get_width(header), api.nvim_win_get_width(grid))
  eq(vim.wo[header].number, true)
  eq(vim.wo[header].numberwidth, 6)
  eq(vim.wo[header].signcolumn, 'yes')
  local view = api.nvim_win_call(grid, vim.fn.winsaveview)
  local pinned = api.nvim_win_call(header, vim.fn.winsaveview)
  eq(view.leftcol, 12)
  eq(pinned.topline, 1)
  eq(pinned.leftcol, view.leftcol)
end

T['resizing the grid resizes the existing header'] = function()
  scroll(20)
  update()
  local header = assert(result.sticky_window())
  local width = api.nvim_win_get_width(grid)
  api.nvim_win_call(grid, function()
    vim.cmd('vsplit')
  end)

  update()

  eq(result.sticky_window(), header)
  eq(api.nvim_win_get_width(header), api.nvim_win_get_width(grid))
  eq(api.nvim_win_get_width(header) < width, true)
end

T['closing the header preserves an identical pre-existing float'] = function()
  local unrelated = api.nvim_win_call(grid, function()
    return preview(grid)
  end)
  scroll(20)
  update()
  local header = assert(result.sticky_window())

  scroll(1)
  update()

  eq(result.sticky_window(), nil)
  eq(api.nvim_win_is_valid(header), false)
  eq(api.nvim_win_is_valid(unrelated), true)
end

T['a refused open leaves existing floats alone on repeated updates'] = function()
  local unrelated = api.nvim_win_call(grid, function()
    return preview(grid)
  end)
  eq(result.sticky_window(), nil)
  local count = #api.nvim_list_wins()
  helpers.stub(api, 'nvim_open_win', function()
    error('Vim:E36: Not enough room')
  end)

  scroll(20)
  for _ = 1, 3 do
    update()
    eq(result.sticky_window(), nil)
    eq(#api.nvim_list_wins(), count)
    eq(api.nvim_win_is_valid(unrelated), true)
    eq(api.nvim_get_current_win(), previous)
  end
end

T['a failed open removes only the new header and can retry'] = function()
  local unrelated = api.nvim_win_call(grid, function()
    return preview(grid)
  end)
  local count = #api.nvim_list_wins()
  local open = api.nvim_open_win
  helpers.stub(api, 'nvim_open_win', function(...)
    open(...)
    error('Vim:E36: Not enough room')
  end)

  scroll(20)
  for _ = 1, 3 do
    update()
    eq(result.sticky_window(), nil)
    eq(#api.nvim_list_wins(), count)
    eq(api.nvim_win_is_valid(unrelated), true)
    eq(api.nvim_get_current_win(), previous)
  end

  api.nvim_open_win = open
  update()
  eq(result.sticky_window() ~= nil, true)
end

T['failure recovery preserves new floats anchored elsewhere'] = function()
  local open = api.nvim_open_win
  local unrelated
  helpers.stub(api, 'nvim_open_win', function(...)
    open(...)
    api.nvim_open_win = open
    unrelated = preview(previous)
    error('Vim:E36: Not enough room')
  end)

  scroll(20)
  update()

  eq(result.sticky_window(), nil)
  eq(api.nvim_win_is_valid(unrelated), true)
end

T['disabling sticky headers closes the tracked window'] = function()
  scroll(20)
  update()
  local header = assert(result.sticky_window())
  config.apply({ ui = { result = { sticky_header = false } } })

  update()

  eq(result.sticky_window(), nil)
  eq(api.nvim_win_is_valid(header), false)
end

return T
