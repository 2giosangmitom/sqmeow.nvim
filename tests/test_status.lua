local eq = MiniTest.expect.equality
local status = require('sqmeow.status')
local state = require('sqmeow.state')
local config = require('sqmeow.config')

--- Pinned, so what a rendered statusline reads as does not depend on the font this suite happens
--- to run under. Both of these are ordinary configuration, which is the point.
local spinner = { '-', '\\', '|', '/' }

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state.reset()
      config.apply({ icons = { postgres = 'pg', spinner = spinner } })
    end,
    post_case = function()
      state.reset()
      config.apply({})
    end,
  },
})

local function connect()
  local id = state.next_connection_id()
  state.add_connection({
    id = id,
    name = 'app',
    url = 'postgres://localhost/app',
    dialect = 'postgres',
    state = 'connected',
  })
  return id
end

T['get'] = MiniTest.new_set()

T['get']['answers with the documented shape before anything has happened'] = function()
  eq(status.get(), {
    connection = nil,
    dialect = nil,
    state = 'idle',
    rows = nil,
    page = nil,
    pages = nil,
    elapsed_ms = nil,
    truncated = nil,
  })
end

T['get']['names the current connection'] = function()
  connect()
  local snapshot = status.get()
  eq(snapshot.connection, 'app')
  eq(snapshot.dialect, 'postgres')
  eq(snapshot.state, 'idle')
end

T['get']['follows a query through its states'] = function()
  connect()

  for _, phase in ipairs({ 'executing', 'done', 'error', 'cancelled' }) do
    state.call = { call_id = 1, conn_id = 1, state = phase }
    eq(status.get().state, phase)
  end
end

T['get']['carries the size and position of a finished result'] = function()
  connect()
  state.call = {
    call_id = 1,
    conn_id = 1,
    state = 'done',
    rows = 240,
    page = 2,
    pages = 3,
    elapsed_ms = 1500,
    truncated = true,
  }

  local snapshot = status.get()
  eq(snapshot.rows, 240)
  eq(snapshot.page, 2)
  eq(snapshot.pages, 3)
  eq(snapshot.elapsed_ms, 1500)
  eq(snapshot.truncated, true)
end

T['active'] = MiniTest.new_set()

T['active']['is false until there is a connection'] = function()
  eq(status.active(), false)
  connect()
  eq(status.active(), true)
end

T['render'] = MiniTest.new_set()

T['render']['is empty when the plugin is not being used'] = function()
  eq(status.render(), '')
end

T['render']['shows the dialect mark and the connection name'] = function()
  connect()
  eq(status.render(), 'pg app')
end

T['render']['spins while a query runs'] = function()
  connect()
  state.call = { call_id = 1, conn_id = 1, state = 'executing' }

  local rendered = status.render()
  eq(rendered:sub(1, 7), 'pg app ')
  eq(vim.tbl_contains(spinner, rendered:sub(8)), true)
end

T['render']['counts the rows once the query is done'] = function()
  connect()
  state.call = { call_id = 1, conn_id = 1, state = 'done', rows = 3, elapsed_ms = 42 }
  eq(status.render(), 'pg app 3 rows 42ms')
end

T['render']['says one row in the singular'] = function()
  connect()
  state.call = { call_id = 1, conn_id = 1, state = 'done', rows = 1 }
  eq(status.render(), 'pg app 1 row')
end

T['render']['shows the page position only when there is more than one page'] = function()
  connect()
  state.call = { call_id = 1, conn_id = 1, state = 'done', rows = 100, page = 1, pages = 1 }
  eq(status.render(), 'pg app 100 rows')

  state.call.pages = 4
  eq(status.render(), 'pg app 100 rows 1/4')
end

T['render']['marks a truncated result'] = function()
  connect()
  state.call = { call_id = 1, conn_id = 1, state = 'done', rows = 100000, truncated = true }
  eq(status.render(), 'pg app 100000 rows +')
end

T['render']['says so when a query failed'] = function()
  connect()
  state.call = { call_id = 1, conn_id = 1, state = 'error', error = 'syntax error' }
  eq(status.render(), 'pg app error')
end

T['frame'] = MiniTest.new_set()

T['frame']['advances with the clock and wraps round'] = function()
  local first = status.frame(0)
  eq(first, spinner[1])
  eq(status.frame(status.frame_ms), spinner[2])
  eq(status.frame(status.frame_ms * #spinner), first)
end

T['lualine'] = MiniTest.new_set()

T['lualine']['is a component and a condition over the same snapshot'] = function()
  local component = require('sqmeow.lualine')
  eq(type(component[1]), 'function')
  eq(component.cond(), false)

  connect()
  eq(component.cond(), true)
  eq(component[1](), 'pg app')
end

T['lualine']['is findable by name on the runtime path'] = function()
  -- The name is how a lazy.nvim spec reaches the component without calling `require` while the
  -- spec is still being read, which is before any plugin is on the runtime path.
  eq(#vim.api.nvim_get_runtime_file('lua/lualine/components/sqmeow.lua', false), 1)
end

T['lualine']['draws the same thing under its name as through the module'] = function()
  if not pcall(require, 'lualine.component') then
    MiniTest.skip('lualine is not installed')
  end

  local class = require('lualine.components.sqmeow')
  local component = class({ self = { section = 'x' } })

  eq(component.options.cond(), false)
  connect()
  eq(component.options.cond(), true)
  eq(component:update_status(), 'pg app')
end

return T
