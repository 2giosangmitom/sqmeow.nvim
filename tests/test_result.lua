local eq = MiniTest.expect.equality
local result = require('sqmeow.ui.result')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      result.close()
    end,
  },
})

T['format_duration'] = MiniTest.new_set()

T['format_duration']['uses milliseconds below a second'] = function()
  eq(result.format_duration(0), '0ms')
  eq(result.format_duration(999), '999ms')
end

T['format_duration']['uses seconds above one'] = function()
  eq(result.format_duration(1000), '1.00s')
  eq(result.format_duration(1500), '1.50s')
end

T['describe'] = MiniTest.new_set()

T['describe']['says the plugin name when nothing has run'] = function()
  eq(result.describe(nil), 'sqmeow')
end

T['describe']['reports a running query'] = function()
  eq(result.describe({ state = 'executing' }), 'running…')
end

T['describe']['reports an error with its message'] = function()
  eq(result.describe({ state = 'error', error = 'no such column' }), 'error: no such column')
end

T['describe']['reports a cancellation'] = function()
  eq(result.describe({ state = 'cancelled' }), 'cancelled')
end

T['describe']['counts rows, singular and plural'] = function()
  eq(result.describe({ state = 'done', rows = 1, elapsed_ms = 4 }), '1 row  4ms')
  eq(result.describe({ state = 'done', rows = 2, elapsed_ms = 4 }), '2 rows  4ms')
end

T['describe']['reports affected rows when a statement returned none'] = function()
  eq(
    result.describe({ state = 'done', rows = 0, affected = 3, elapsed_ms = 1 }),
    '3 rows affected  1ms'
  )
end

T['describe']['says so when nothing came back at all'] = function()
  eq(result.describe({ state = 'done', rows = 0, elapsed_ms = 1 }), 'no rows  1ms')
end

T['describe']['flags a truncated result'] = function()
  local text = result.describe({ state = 'done', rows = 100, truncated = true, elapsed_ms = 2 })
  eq(text:find('truncated', 1, true) ~= nil, true)
end

T['describe']['shows the page only when there is more than one'] = function()
  eq(
    result.describe({ state = 'done', rows = 5, page = 1, pages = 1, elapsed_ms = 1 }),
    '5 rows  1ms'
  )
  eq(
    result.describe({ state = 'done', rows = 500, page = 2, pages = 5, elapsed_ms = 1 }),
    '500 rows  page 2/5  1ms'
  )
end

T['window'] = MiniTest.new_set()

T['window']['starts closed'] = function()
  eq(result.is_open(), false)
end

T['window']['opens without stealing the cursor'] = function()
  local before = vim.api.nvim_get_current_win()
  result.open()
  eq(result.is_open(), true)
  eq(vim.api.nvim_get_current_win(), before)
end

T['window']['opening twice reuses the window'] = function()
  local first = result.open()
  eq(result.open(), first)
end

T['window']['closes'] = function()
  result.open()
  result.close()
  eq(result.is_open(), false)
end

T['window']['keeps the buffer across open and close'] = function()
  local buf = result.buffer()
  result.open()
  result.close()
  eq(result.buffer(), buf)
end

T['buffer'] = MiniTest.new_set()

T['buffer']['is a scratch buffer nobody can type into'] = function()
  local buf = result.buffer()
  eq(vim.bo[buf].buftype, 'nofile')
  eq(vim.bo[buf].modifiable, false)
  eq(vim.bo[buf].swapfile, false)
end

T['buffer']['maps its keys buffer-locally, with descriptions'] = function()
  local buf = result.buffer()
  local maps = vim.api.nvim_buf_get_keymap(buf, 'n')

  local seen = {}
  for _, map in ipairs(maps) do
    seen[map.lhs] = map.desc
  end

  for _, key in ipairs({ 'L', 'H', 'q' }) do
    eq(type(seen[key]), 'string')
  end
end

T['display columns'] = MiniTest.new_set()

T['display columns']['cut a slice out of a grid line'] = function()
  --      0123456789...
  local line = ' id │ name  │ score'
  eq(result.display_slice(line, 1, 2), 'id')
  eq(result.display_slice(line, 6, 5), 'name')
  eq(result.display_slice(line, 14, 5), 'score')
end

T['display columns']['count width, not bytes'] = function()
  -- Each of these characters is two columns wide, so a byte offset would land mid-character.
  local line = ' 名前 │ 東京都'
  eq(result.display_slice(line, 1, 4), '名前')
  eq(result.display_slice(line, 8, 6), '東京都')
end

T['display columns']['turn a display column into a byte offset'] = function()
  local line = ' 名前 │ 東京都'
  eq(result.byte_at(line, 0), 0)
  eq(result.byte_at(line, 1), 1)
  -- One space plus two three-byte characters.
  eq(result.byte_at(line, 5), 7)
end

T['display columns']['stop at the end of a short line'] = function()
  eq(result.display_slice(' id', 6, 5), '')
  eq(result.byte_at(' id', 40), 3)
end

return T
