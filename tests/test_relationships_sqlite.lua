local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local browser = require('sqmeow.ui.relationships')
local rpc = require('sqmeow.rpc.client')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require('sqmeow').setup({ query = { persist_history = false } })
    end,
    post_case = function()
      browser.close()
      require('sqmeow.ui.result').close()
      require('sqmeow.ui.drawer').close()
      rpc.stop()
      require('sqmeow.core.state').reset()
    end,
  },
})

local function settled_lines()
  helpers.wait_for('relationship popup should finish loading', function()
    return vim.bo.filetype == 'sqmeow-relationships'
      and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] ~= 'Loading relationships…'
  end)
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

T['unqualified SQLite table shows both directions and follows the resolved endpoint'] = function()
  local conn_id = helpers.connect('sqlite::memory:', { name = 'relationships' })
  eq(
    helpers.run('CREATE TABLE teams (tenant_id INTEGER, id INTEGER, PRIMARY KEY (tenant_id, id))').state,
    'done'
  )
  eq(
    helpers.run([[
    CREATE TABLE users (
      id INTEGER PRIMARY KEY, tenant INTEGER, team INTEGER, manager INTEGER,
      FOREIGN KEY (tenant, team) REFERENCES teams (tenant_id, id),
      FOREIGN KEY (manager) REFERENCES users (id)
    )
  ]]).state,
    'done'
  )
  eq(
    helpers.run(
      'CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users (id))'
    ).state,
    'done'
  )

  -- Echoed schema remains empty, but SQLite metadata has canonical schema `main`.
  browser.open(conn_id, '', 'users')
  local lines = settled_lines()
  local text = table.concat(lines, '\n')
  helpers.contains(text, 'Belongs to')
  helpers.contains(text, 'Referenced by')
  helpers.contains(text, 'main.users.tenant → main.teams.tenant_id')
  helpers.contains(text, 'main.users.team → main.teams.id')
  helpers.contains(text, 'main.posts.user_id → main.users.id')
  helpers.contains(text, 'main.users (self)')
  local mapping = assert(text:find('main.users.tenant', 1, true), 'tenant mapping should be shown')
  eq(mapping < assert(text:find('main.users.team', 1, true), 'team mapping should be shown'), true)

  local endpoint
  for index, line in ipairs(lines) do
    if line:find(': main.teams', 1, true) then
      endpoint = index
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { assert(endpoint, 'teams endpoint should be selectable'), 0 })
  browser.actions.browse()
  local followed = table.concat(settled_lines(), '\n')
  helpers.contains(followed, 'Belongs to\n  None')
  helpers.contains(followed, ': main.users')
  helpers.contains(followed, 'main.users.tenant → main.teams.tenant_id')
end

T['case-insensitive SQLite lookup displays the catalog spelling'] = function()
  local conn_id = helpers.connect('sqlite::memory:', { name = 'mixed-case relationships' })
  eq(helpers.run('CREATE TABLE Parent (id INTEGER PRIMARY KEY)').state, 'done')
  eq(helpers.run('CREATE TABLE Child (parent_id INTEGER REFERENCES Parent (id))').state, 'done')
  browser.open(conn_id, '', 'parent')
  local text = table.concat(settled_lines(), '\n')
  helpers.contains(text, 'Referenced by')
  helpers.contains(text, 'main.Child.parent_id → main.Parent.id')
end

return T
