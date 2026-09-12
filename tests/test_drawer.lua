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

--- Put the cursor on a line and make sure what is there is open.
---
--- Open-only rather than a toggle, so a case that runs after one which already expanded the same
--- node does not quietly collapse it again.
local function expand(pattern)
  local number = line_matching(pattern)
  if lines()[number]:find('^%s*v') then
    return
  end

  vim.api.nvim_win_set_cursor(drawer.open(), { number, 0 })
  drawer.actions.toggle()
end

--- Put the cursor on a line and close what is there.
local function collapse(pattern)
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
  eq(lines(), { '> s scratch  sqlite', '> + scratchpads  none saved' })
end

T['tree']['expands a connection into its schemas'] = function()
  expand('scratch')
  line_matching('main')

  eq(lines()[1], 'v s scratch  sqlite')
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
  collapse('people')
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

T['scratchpads'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local editor = require('sqmeow.ui.editor')
      vim.fn.mkdir(editor.directory(), 'p')
      vim.fn.writefile({ 'select 1' }, vim.fs.joinpath(editor.directory(), 'notes.sql'))
      drawer.render()
    end,
    post_case = function()
      vim.fn.delete(vim.fs.joinpath(require('sqmeow.ui.editor').directory(), 'notes.sql'))
      drawer.render()
    end,
  },
})

T['scratchpads']['are listed under a heading of their own'] = function()
  local heading = line_matching('scratchpads')
  eq(lines()[heading], '> + scratchpads  1')
end

T['scratchpads']['expand into the saved files'] = function()
  expand('scratchpads')
  -- The icon sits in the same column as one on a branch, so a leaf lines up with its siblings.
  eq(lines()[line_matching('notes')], '    * notes')
end

T['scratchpads']['open the file when chosen'] = function()
  expand('scratchpads')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('notes'), 0 })
  drawer.actions.toggle()

  local opened = vim.api.nvim_buf_get_name(0)
  eq(vim.fs.basename(opened), 'notes.sql')
  eq(vim.bo.filetype, 'sql')

  -- Back to the drawer, so the next case starts where this one did.
  vim.cmd.bwipeout()
  drawer.open()
end

T['scratchpads']['open somewhere other than the drawer'] = function()
  expand('scratchpads')
  local sidebar = drawer.open()
  vim.api.nvim_win_set_cursor(sidebar, { line_matching('notes'), 0 })
  vim.api.nvim_set_current_win(sidebar)

  drawer.actions.toggle()

  -- A plain `:edit` would have opened the file in the window the key was pressed in, which is the
  -- sidebar, replacing the tree with a SQL buffer.
  eq(vim.api.nvim_get_current_win() ~= sidebar, true)
  eq(vim.bo[vim.api.nvim_win_get_buf(sidebar)].filetype, 'sqmeow-drawer')
  eq(drawer.is_open(), true)

  vim.cmd.bwipeout()
  drawer.open()
end

T['scratchpads']['are renamed once a new name is given'] = function()
  local editor = require('sqmeow.ui.editor')
  local input = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    on_confirm('renamed')
  end
  MiniTest.finally(function()
    vim.ui.input = input
    vim.fn.delete(vim.fs.joinpath(editor.directory(), 'renamed.sql'))
  end)

  expand('scratchpads')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('notes'), 0 })
  drawer.actions.rename()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')), nil)
  eq(lines()[line_matching('renamed')], '    * renamed')
end

T['scratchpads']['offer the current name to edit'] = function()
  local offered = nil
  local input = vim.ui.input
  vim.ui.input = function(opts)
    offered = opts.default
  end
  MiniTest.finally(function()
    vim.ui.input = input
  end)

  expand('scratchpads')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('notes'), 0 })
  drawer.actions.rename()

  eq(offered, 'notes')
end

T['scratchpads']['are left alone when the rename is abandoned'] = function()
  local editor = require('sqmeow.ui.editor')
  local input = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    on_confirm(nil)
  end
  MiniTest.finally(function()
    vim.ui.input = input
  end)

  expand('scratchpads')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('notes'), 0 })
  drawer.actions.rename()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')) ~= nil, true)
end

T['scratchpads']['are not renamed from a row that is not one'] = function()
  local called = false
  local input = vim.ui.input
  vim.ui.input = function()
    called = true
  end
  MiniTest.finally(function()
    vim.ui.input = input
  end)

  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('scratch  sqlite'), 0 })
  drawer.actions.rename()
  eq(called, false)
end

T['scratchpads']['are deleted once the question is answered'] = function()
  local editor = require('sqmeow.ui.editor')
  local answer = 'yes'
  local select = vim.ui.select
  vim.ui.select = function(_, _, on_choice)
    on_choice(answer)
  end
  MiniTest.finally(function()
    vim.ui.select = select
  end)

  expand('scratchpads')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('notes'), 0 })
  drawer.actions.delete()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')), nil)
  eq(lines()[line_matching('scratchpads')]:find('none saved') ~= nil, true)
end

T['scratchpads']['are left alone when the question is declined'] = function()
  local editor = require('sqmeow.ui.editor')
  local select = vim.ui.select
  vim.ui.select = function(_, _, on_choice)
    on_choice('no')
  end
  MiniTest.finally(function()
    vim.ui.select = select
  end)

  expand('scratchpads')
  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('notes'), 0 })
  drawer.actions.delete()

  eq(vim.uv.fs_stat(vim.fs.joinpath(editor.directory(), 'notes.sql')) ~= nil, true)
end

T['scratchpads']['are not deleted from a row that is not one'] = function()
  local called = false
  local select = vim.ui.select
  vim.ui.select = function()
    called = true
  end
  MiniTest.finally(function()
    vim.ui.select = select
  end)

  vim.api.nvim_win_set_cursor(drawer.open(), { line_matching('scratch  sqlite'), 0 })
  drawer.actions.delete()
  eq(called, false)
end

T['scratchpads']['say so when there are none'] = function()
  vim.fn.delete(vim.fs.joinpath(require('sqmeow.ui.editor').directory(), 'notes.sql'))
  drawer.render()

  eq(lines()[line_matching('scratchpads')]:find('none saved') ~= nil, true)
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
