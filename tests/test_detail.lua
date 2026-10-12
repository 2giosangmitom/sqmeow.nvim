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
    { name = 'crlf', declared_type = 'text', value = "line1\r\nline2" },
    { name = 'long', declared_type = 'text', value = long_text },
  }
  local lines = detail.lines(columns, 80)
  eq(#lines, 3)
  eq(lines[1]:content(), 'crlf  text  line1')
  eq(lines[2]:content(), '            line2')
  eq(lines[3]:content():find(long_text, 1, true) ~= nil, true)
  eq(#lines[3]:content() >= 200, true)
end

return T
