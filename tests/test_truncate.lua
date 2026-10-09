local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local utils = require('sqmeow.core.utils')
local T = MiniTest.new_set()

-- The pre-optimization algorithm is the compatibility oracle, including its
-- per-character treatment of combining accents and zero-width characters.
local function original(text, limit, marker)
  if vim.api.nvim_strwidth(text) <= limit then
    return text
  end
  if limit <= 0 then
    return ''
  end
  if vim.api.nvim_strwidth(marker) > limit then
    marker = ''
  end
  local budget = limit - vim.api.nvim_strwidth(marker)
  local out, at = {}, 0
  for char in utils.characters(text) do
    local step = vim.api.nvim_strwidth(char)
    if at + step > budget then
      break
    end
    at = at + step
    table.insert(out, char)
  end
  return table.concat(out) .. marker
end

T['truncate preserves ASCII Unicode controls and marker behavior'] = function()
  local previous = vim.o.ambiwidth
  MiniTest.finally(function()
    vim.o.ambiwidth = previous
  end)
  for _, ambiwidth in ipairs({ 'single', 'double' }) do
    vim.o.ambiwidth = ambiwidth
    for _, text in ipairs({
      '',
      ('plain text \\"'):rep(20),
      ('中🙂é'):rep(20),
      ('é\226\128\141·'):rep(20),
      'a\n\r\tb\0c',
      string.char(127) .. 'control',
    }) do
      for _, marker in ipairs({ '', '…', '...', '中🙂' }) do
        for limit = -1, 40 do
          eq(utils.truncate(text, limit, marker), original(text, limit, marker))
        end
      end
    end
  end
end

T['fixed and automatic table columns keep their display widths'] = function()
  local Table = require('sqmeow.ui.table')
  local buffer = vim.api.nvim_create_buf(false, true)
  MiniTest.finally(function()
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
  local text = ('中🙂é'):rep(20)
  for _, width in ipairs({ 4, 200 }) do
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {})
    local grid = Table.new({
      bufnr = buffer,
      ns_id = vim.api.nvim_create_namespace('sqmeow-truncate-test'),
      columns = { { id = 'x', header = 'x', width = width, accessor_key = 'x' } },
      data = { { x = text } },
      trim = true,
    })
    grid:render()
    local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    local expected = utils.truncate(text, width, require('sqmeow.config').get().icons.grid.ellipsis)
    eq(lines[#lines]:find(expected, 1, true) ~= nil, true)
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {})
  local grid = Table.new({
    bufnr = buffer,
    ns_id = vim.api.nvim_create_namespace('sqmeow-truncate-test'),
    columns = { { id = 'x', header = 'x', accessor_key = 'x' } },
    data = { { x = text } },
    trim = true,
  })
  grid:render()
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  eq(lines[#lines]:find(text, 1, true) ~= nil, true)
end

return T
