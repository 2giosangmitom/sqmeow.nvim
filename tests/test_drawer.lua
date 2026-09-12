-- The schema drawer, against a real SQLite database, through the real engine.

local eq = MiniTest.expect.equality
local api = require('sqmeow.api')
local rpc = require('sqmeow.rpc')
local state = require('sqmeow.state')
local drawer = require('sqmeow.ui.drawer')

local TIMEOUT = 5000

local function lines()
  return vim.api.nvim_buf_get_lines(drawer.buffer(), 0, -1, false)
end

--- Wait until a line matching `pattern` is drawn, then answer with its number.
local function line_matching(pattern)
  local found
  local arrived = vim.wait(TIMEOUT, function()
    for number, line in ipairs(lines()) do
      if line:find(pattern) then
        found = number
        return true
      end
    end
    return false
  end, 20)

  assert(
    arrived,
    ('no line matching %q; drawer holds:\n%s'):format(pattern, table.concat(lines(), '\n'))
  )
  return found
end

--- Put the cursor on a line and expand what is there.
local function expand(pattern)
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching(pattern), 0 })
  drawer.actions.toggle()
end

local function run(sql)
  local call_id = assert(api.execute(sql))
  assert(
    vim.wait(TIMEOUT, function()
      return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
    end, 10),
    'the query should settle: ' .. sql
  )
  return state.call
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      -- Pinned, so the tree looks the same whether or not an icon plugin is installed.
      require('sqmeow').setup({ integrations = { icons = 'ascii' } })

      local id = assert(api.connect('sqlite::memory:', { name = 'scratch' }))
      assert(vim.wait(TIMEOUT, function()
        return state.connections[id] ~= nil and state.connections[id].state == 'connected'
      end, 10))

      run('create table people (id integer primary key, name text not null, score real)')
      run('create view adults as select * from people')
      api.open_drawer()
    end,
    post_once = function()
      drawer.close()
      api.close()
      rpc.stop()
      state.reset()
      drawer.reset()
    end,
  },
})

T['tree'] = MiniTest.new_set()

T['tree']['starts with connections collapsed'] = function()
  eq(lines(), { '> # scratch  sqlite' })
end

T['tree']['expands a connection into its schemas'] = function()
  expand('scratch')
  line_matching('main')

  eq(lines()[1], 'v # scratch  sqlite')
  eq(lines()[2], '  > @ main')
end

T['tree']['expands a schema into its tables and views'] = function()
  expand('main')
  line_matching('adults')

  local text = table.concat(lines(), '\n')
  eq(text:find('people%s+table') ~= nil, true)
  eq(text:find('adults%s+view') ~= nil, true)
end

T['tree']['expands a relation into its columns'] = function()
  expand('people')
  line_matching('score')

  local text = table.concat(lines(), '\n')
  eq(text:find('id%s+INTEGER%s+primary key') ~= nil, true)
  eq(text:find('name%s+TEXT%s+not null') ~= nil, true)
  eq(text:find('score%s+REAL') ~= nil, true)
end

T['tree']['collapses again'] = function()
  local before = #lines()
  expand('people')
  eq(#lines() < before, true)
  eq(drawer.is_expanded(state.current, { 'main', 'people' }), false)
end

T['actions'] = MiniTest.new_set()

T['actions']['yank a qualified name'] = function()
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('people'), 0 })
  drawer.actions.yank_name()
  eq(vim.fn.getreg('"'), '"main"."people"')
end

T['actions']['yank a select for a relation'] = function()
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('people'), 0 })
  drawer.actions.yank_select()
  eq(vim.fn.getreg('"'), 'select * from "main"."people" limit 100')
end

T['actions']['do nothing on a node that is not a relation'] = function()
  vim.fn.setreg('"', 'untouched')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('scratch'), 0 })
  drawer.actions.yank_select()
  eq(vim.fn.getreg('"'), 'untouched')
end

T['actions']['preview a relation into the result window'] = function()
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('people'), 0 })
  drawer.actions.preview()

  assert(vim.wait(TIMEOUT, function()
    return state.call ~= nil and state.call.state == 'done'
  end, 10))

  -- ASCII rules, because this file asked for the ASCII icon set and that setting reaches the
  -- grid the engine draws as well as the markers the drawer draws.
  local grid = vim.api.nvim_buf_get_lines(require('sqmeow.ui.result').buffer(), 0, -1, false)
  eq(grid[1], ' id | name | score')
end

T['window'] = MiniTest.new_set()

T['window']['is open, and its buffer cannot be typed into'] = function()
  eq(drawer.is_open(), true)
  eq(vim.bo[drawer.buffer()].modifiable, false)
  eq(vim.bo[drawer.buffer()].buftype, 'nofile')
end

T['window']['maps its keys buffer-locally with descriptions'] = function()
  local maps = vim.api.nvim_buf_get_keymap(drawer.buffer(), 'n')
  local seen = {}
  for _, map in ipairs(maps) do
    seen[map.lhs] = map.desc
  end

  for _, key in ipairs({ '<CR>', 'o', 'r', 'y', 's', '?', 'q' }) do
    eq(type(seen[key]), 'string')
  end
end

return T
