local eq = MiniTest.expect.equality
local keymap = require('sqmeow.keymap')
local help = require('sqmeow.ui.help')
local config = require('sqmeow.config')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.apply({})
    end,
  },
})

local function find(surface, action)
  for _, entry in ipairs(keymap.resolve(surface)) do
    if entry.action == action then
      return entry
    end
  end
  return nil
end

T['defaults'] = MiniTest.new_set()

T['defaults']['carry a description on every mapping'] = function()
  for surface in pairs(keymap.defaults) do
    for _, entry in ipairs(keymap.resolve(surface)) do
      eq(type(entry.desc), 'string')
      eq(entry.desc ~= '', true)
    end
  end
end

T['defaults']['give one action several keys where it helps'] = function()
  eq(find('drawer', 'toggle').lhs, { '<CR>', 'o' })
end

T['defaults']['use the same key for the same thing on every surface'] = function()
  for surface in pairs(keymap.defaults) do
    eq(find(surface, 'close').lhs, { 'q' })
    eq(find(surface, 'help').lhs, { '?' })
  end
end

T['overrides'] = MiniTest.new_set()

T['overrides']['change one action without restating the rest'] = function()
  config.apply({ keymaps = { result = { next_page = '<C-n>' } } })

  eq(find('result', 'next_page').lhs, { '<C-n>' })
  eq(find('result', 'prev_page').lhs, { 'H' })
end

T['overrides']['accept several keys'] = function()
  config.apply({ keymaps = { result = { next_page = { 'L', '<Right>' } } } })
  eq(find('result', 'next_page').lhs, { 'L', '<Right>' })
end

T['overrides']['drop a mapping when set to false'] = function()
  config.apply({ keymaps = { drawer = { toggle = false } } })
  eq(find('drawer', 'toggle').lhs, {})
end

T['problems'] = MiniTest.new_set()

T['problems']['are none by default'] = function()
  eq(keymap.problems(), {})
end

T['problems']['name an action that does not exist'] = function()
  config.apply({ keymaps = { drawer = { togle = 'x' } } })

  local problems = keymap.problems()
  eq(#problems, 1)
  eq(problems[1]:find('togle', 1, true) ~= nil, true)
end

T['problems']['name a surface that does not exist'] = function()
  config.apply({ keymaps = { sidebar = { toggle = 'x' } } })

  local problems = keymap.problems()
  eq(#problems, 1)
  eq(problems[1]:find('sidebar', 1, true) ~= nil, true)
end

T['applying'] = MiniTest.new_set()

T['applying']['binds only inside the buffer it was given'] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local before = #vim.api.nvim_get_keymap('n')

  keymap.apply('result', buf, { next_page = function() end })

  eq(#vim.api.nvim_get_keymap('n'), before)
  eq(#vim.api.nvim_buf_get_keymap(buf, 'n'), 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['applying']['skips an action the surface has not implemented'] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  keymap.apply('result', buf, {})

  eq(#vim.api.nvim_buf_get_keymap(buf, 'n'), 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['applying']['puts a description on what it binds'] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  keymap.apply('result', buf, { close = function() end })

  local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
  eq(maps[1].lhs, 'q')
  eq(maps[1].desc:find('sqmeow', 1, true), 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['plug'] = MiniTest.new_set()

T['plug']['is defined and bound to no ordinary key'] = function()
  require('sqmeow.keymap').register_plug()

  local global = vim.api.nvim_get_keymap('n')
  local plugs = vim.tbl_filter(function(map)
    return map.lhs:find('<Plug>', 1, true) == 1 and map.lhs:find('sqmeow', 1, true)
  end, global)
  eq(#plugs > 0, true)

  -- Nothing outside a plugin window is taken. Every global mapping is a <Plug> one.
  local taken = vim.tbl_filter(function(map)
    return map.desc
      and map.desc:find('sqmeow', 1, true) == 1
      and map.lhs:find('<Plug>', 1, true) ~= 1
  end, global)
  eq(taken, {})
end

T['cheatsheet'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      help.close()
    end,
  },
})

T['cheatsheet']['lists a line per mapping'] = function()
  local lines = help.lines('drawer')
  eq(#lines, #keymap.defaults.drawer)
  eq(lines[1]:find('<CR>, o', 1, true) ~= nil, true)
end

T['cheatsheet']['omits an action the user disabled'] = function()
  config.apply({ keymaps = { drawer = { toggle = false } } })
  eq(#help.lines('drawer'), #keymap.defaults.drawer - 1)
end

T['cheatsheet']['shows an override rather than the default'] = function()
  config.apply({ keymaps = { result = { next_page = '<C-n>' } } })

  local text = table.concat(help.lines('result'), '\n')
  eq(text:find('<C-n>', 1, true) ~= nil, true)
end

return T
