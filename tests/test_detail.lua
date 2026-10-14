-- Popup tests temporarily replace RPC to avoid needing an engine.
---@diagnostic disable: duplicate-set-field
local MiniTest = require('mini.test')
-- The row details popup view.

local eq = MiniTest.expect.equality
local detail = require('sqmeow.ui.detail')

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup()
    end,
  },
})

T['detail lines preserves single-line values and formats types'] = function()
  local columns = {
    { name = 'id', declared_type = 'integer', value = 42, key = 'primary_key' },
    { name = 'name', declared_type = 'varchar(255)', value = 'alice' },
    { name = 'active', declared_type = 'boolean', is_null = true },
  }
  local lines = detail.lines(columns, 80)
  eq(#lines, 3)
  eq(lines[1]:content(), 'id      integer (PK)  42')
  eq(lines[2]:content(), 'name    varchar(255)  alice')
  eq(lines[3]:content(), 'active  boolean       NULL')
end

T['detail lines displays full multiline values indented under the value column'] = function()
  local json_payload = '{\n  "name": "data",\n  "count": 10\n}'
  local columns = {
    { name = 'id', declared_type = 'integer', value = 1 },
    { name = 'payload', declared_type = 'json', value = json_payload },
  }
  local lines = detail.lines(columns, 80)
  eq(#lines, 5)
  eq(lines[1]:content(), 'id       integer  1')
  eq(lines[2]:content(), 'payload  json     {')
  eq(lines[3]:content(), '                    "name": "data",')
  eq(lines[4]:content(), '                    "count": 10')
  eq(lines[5]:content(), '                  }')
end

T['detail lines normalizes CRLF and preserves long un-truncated values'] = function()
  local long_text = string.rep('x', 200)
  local columns = {
    { name = 'crlf', declared_type = 'text', value = 'line1\r\nline2' },
    { name = 'long', declared_type = 'text', value = long_text },
  }
  local lines = detail.lines(columns, 80)
  eq(#lines, 3)
  eq(lines[1]:content(), 'crlf  text  line1')
  eq(lines[2]:content(), '            line2')
  eq(lines[3]:content():find(long_text, 1, true) ~= nil, true)
  eq(#lines[3]:content() >= 200, true)
end

T['detail lines displays embedded NUL safely without losing surrounding text'] = function()
  local value = string.rep('x', 200) .. '\0end\nnext\0line'
  local lines = detail.lines({ { name = 'v', declared_type = 'text', value = value } }, 24)
  eq(#lines, 2)
  eq(lines[1]:content(), 'v  text  ' .. string.rep('x', 200) .. '^@end')
  eq(lines[2]:content(), '         next^@line')
end

T['detail lines preserves bare carriage returns and empty lines'] = function()
  local lines = detail.lines({ { name = 'v', value = 'a\rb\r\n\nend\n' } }, 80)
  eq(
    vim.tbl_map(function(line)
      return line:content()
    end, lines),
    { 'v    a\rb', '     ', '     end', '     ' }
  )
end

T['detail lines aligns tab control and wide column names'] = function()
  for _, name in ipairs({ 'a\tb', 'a\001b', '界' }) do
    local lines =
      detail.lines({ { name = name, declared_type = 'text', value = 'first\nsecond' } }, 80)
    local prefix = lines[1]:content():match('^(.*)first$')
    eq(lines[2]:content(), string.rep(' ', vim.fn.strdisplaywidth(prefix)) .. 'second')
  end
end

local rpc = require('sqmeow.rpc.client')
local state = require('sqmeow.core.state')
local original_request, original_call, original_tabstop
T['popup'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_request, original_call, original_tabstop = rpc.request, state.call, vim.bo.tabstop
      state.call = { call_id = 1, state = 'done' }
      vim.bo.tabstop = 4
      rpc.request = function()
        return {
          { name = 'a\tb', declared_type = 'text', value = string.rep('x', 200) .. '\nnext' },
        }
      end
    end,
    post_case = function()
      detail.close()
      rpc.request, state.call = original_request, original_call
      vim.bo.tabstop = original_tabstop
    end,
  },
})

T['popup']['row details wraps full values in a read-only buffer'] = function()
  detail.open(0)
  eq(vim.bo.filetype, 'sqmeow-row')
  eq(vim.wo.wrap, true)
  eq(vim.bo.modifiable, false)
  eq(vim.bo.tabstop, 4)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(#lines, 2)
  eq(lines[1]:sub(-200), string.rep('x', 200))
  eq(lines[2], string.rep(' ', vim.fn.strdisplaywidth(lines[1]:sub(1, -201))) .. 'next')
end

T['popup']['other popups remain unwrapped by default'] = function()
  local popup = require('sqmeow.ui.popup').open({
    title = ' Test ',
    lines = { 'text' },
    width = 20,
    height = 1,
    close_maps = false,
    on_close = function() end,
  })
  local wrap = vim.wo[popup.winid].wrap
  popup:unmount()
  eq(wrap, false)
end

T['popup']['NUL and bare carriage returns render without errors'] = function()
  rpc.request = function()
    return { { name = 'v', declared_type = 'text', value = 'before\0after\nwith\rcarriage' } }
  end
  detail.open(0)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    'v  text  before^@after',
    '         with\rcarriage',
  })
  eq(vim.api.nvim_win_get_height(0), 2)
end

return T
