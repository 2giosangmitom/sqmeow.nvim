local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local state = require('sqmeow.core.state')
local result = require('sqmeow.ui.result')
local config = require('sqmeow.config')
local data, next_id
local original_request, original_ensure

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state.reset()
      result.render(nil)
      next_id = 1
      config.apply({ ui = { result = { page_size = 1, column_icons = false } } })
      original_ensure = helpers.swap(require('sqmeow.rpc.events'), 'ensure', function() end)
      original_request = helpers.swap(
        require('sqmeow.rpc.client'),
        'request',
        function(method, args)
          eq(method, 'rows')
          return { rows = { data[args.offset + 1] }, indices = { args.offset }, total = #data }
        end
      )
    end,
    post_case = function()
      result.close()
      require('sqmeow.rpc.client').request = original_request
      require('sqmeow.rpc.events').ensure = original_ensure
      state.reset()
      config.apply({})
    end,
  },
})

local function render(rows, nulls)
  data = rows
  state.call = {
    call_id = next_id,
    state = 'done',
    rows = #rows,
    columns = {
      { name = 'x', type_name = 'text', class = 'text', numeric = false, nulls = nulls or false },
      { name = 'y', type_name = 'integer', class = 'number', numeric = true, nulls = false },
    },
  }
  next_id = next_id + 1
  result.render(state.call)
end

local function header_width()
  return vim.api.nvim_strwidth(helpers.result_lines()[1])
end

T['Neovim measures wide characters and combining accents rather than bytes'] = function()
  render({ { 'abc', 7 } })
  local ascii = header_width()
  render({ { '中é', 7 } })
  eq(header_width(), ascii)
  helpers.contains(helpers.result_rows()[1], '中é')
  eq(vim.api.nvim_strwidth(helpers.result_rows()[1]), ascii)
end

T['loaded pages grow columns without shrinking them on return and new results reset widths'] = function()
  render({ { 'a', 1 }, { 'longer text', 2 } })
  local first = header_width()
  result.show_page(1)
  local second = header_width()
  eq(second > first, true)
  helpers.contains(helpers.result_rows()[1], 'longer text')
  result.show_page(0)
  eq(header_width(), second)
  render({ { 'a', 1 } })
  eq(header_width(), first)
end

T['NULL labels and escaped controls are measured as drawn and content obeys the width cap'] = function()
  config.apply({ ui = { result = { page_size = 1, column_icons = false, null_text = '(null)' } } })
  render({ { vim.NIL, 12 } }, true)
  local null_width = header_width()
  helpers.contains(helpers.result_rows()[1], '(null)')
  render({ { '123456', 12 } })
  eq(header_width(), null_width)
  render({ { 'a\nb\tc', 12 } })
  helpers.contains(helpers.result_rows()[1], 'a\\nb\\tc')
  eq(vim.api.nvim_strwidth(helpers.result_rows()[1]), header_width())

  config.apply({ ui = { result = { page_size = 1, column_icons = false, max_column_width = 4 } } })
  render({ { '1234', 12 } })
  local capped = header_width()
  render({ { '123456789', 12 } })
  eq(header_width(), capped)
end

return T
