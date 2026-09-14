local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local result = require('sqmeow.ui.result')
local icons = require('sqmeow.icons')
local sqmeow = require('sqmeow')

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

T['describe'] = MiniTest.new_set({
  hooks = {
    -- `describe` reads the page size out of the configuration, so a case that changed it must not
    -- leave that behind for the next one.
    post_case = function()
      sqmeow.setup({})
    end,
  },
})

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

--- How long a query took, as `describe` writes it: behind the configured icon.
local function took(ms)
  return icons.get('elapsed') .. ' ' .. ms
end

T['describe']['counts rows, singular and plural'] = function()
  eq(result.describe({ state = 'done', rows = 1, elapsed_ms = 4 }), '1 row  ' .. took('4ms'))
  eq(result.describe({ state = 'done', rows = 2, elapsed_ms = 4 }), '2 rows  ' .. took('4ms'))
end

T['describe']['reports affected rows when a statement returned none'] = function()
  eq(
    result.describe({ state = 'done', rows = 0, affected = 3, elapsed_ms = 1 }),
    '3 rows affected  ' .. took('1ms')
  )
end

T['describe']['says so when nothing came back at all'] = function()
  eq(result.describe({ state = 'done', rows = 0, elapsed_ms = 1 }), 'no rows  ' .. took('1ms'))
end

T['describe']['colours the time icon only for a winbar'] = function()
  local summary = { state = 'done', rows = 1, elapsed_ms = 4 }
  local icon = icons.get('elapsed')
  eq(result.describe(summary, true), ('1 row  %%#SqmeowIconElapsed#%s%%* 4ms'):format(icon))

  -- Without a glyph, the time stands alone.
  sqmeow.setup({ icons = { elapsed = '' } })
  eq(result.describe(summary, true), '1 row  4ms')
end

T['describe']['flags a truncated result'] = function()
  local text = result.describe({ state = 'done', rows = 100, truncated = true, elapsed_ms = 2 })
  helpers.contains(text, 'truncated')
end

T['describe']['shows the page only when there is more than one'] = function()
  -- Which page is showing is no longer something the summary carries: the engine does not know how
  -- tall this window is, so the count is worked out here from the row total and the page size.
  -- That a *particular* page is named is covered end to end in `test_query.lua`, where paging is
  -- real; here only the page size decides whether there is more than one page at all.
  sqmeow.setup({ ui = { result = { page_size = 100 } } })

  eq(result.describe({ state = 'done', rows = 5, elapsed_ms = 1 }), '5 rows  ' .. took('1ms'))
  eq(
    result.describe({ state = 'done', rows = 500, elapsed_ms = 1 }),
    '500 rows  page 1/5  ' .. took('1ms')
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
  local seen = helpers.buf_maps(result.buffer())

  for _, key in ipairs({ 'L', 'H', 'q' }) do
    eq(type(seen[key]), 'string')
  end
end

-- The display-column arithmetic these tests used to cover is gone: nui records where it put every
-- cell, so `current_cell` asks it rather than measuring the line under the cursor. What is left to
-- test here is the paging arithmetic, which is this side's own.

T['pages'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      sqmeow.setup({})
    end,
  },
})

T['pages']['is one page when a result fits'] = function()
  sqmeow.setup({ ui = { result = { page_size = 100 } } })
  local current, total = result.pages({ state = 'done', rows = 9 })
  eq(current, 1)
  eq(total, 1)
end

T['pages']['counts a partial last page'] = function()
  sqmeow.setup({ ui = { result = { page_size = 4 } } })
  local _, total = result.pages({ state = 'done', rows = 9 })
  eq(total, 3)
end

T['pages']['says one page for a result with no rows'] = function()
  sqmeow.setup({ ui = { result = { page_size = 4 } } })
  local current, total = result.pages({ state = 'done', rows = 0 })
  eq(current, 1)
  eq(total, 1)
end

T['pages']['says one page when nothing has run'] = function()
  local current, total = result.pages(nil)
  eq(current, 1)
  eq(total, 1)
end

T['layout'] = MiniTest.new_set()

T['layout']['closing does not squeeze the editor when a float came and went'] = function()
  local height = vim.api.nvim_win_get_height(0)
  -- Another plugin's notification, open while the result opens and gone before it closes.
  local note = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = 'editor',
    row = 0,
    col = 0,
    width = 20,
    height = 1,
  })
  result.open()
  vim.api.nvim_win_close(note, true)
  result.close()

  eq(vim.api.nvim_win_get_height(0), height)
end

return T
