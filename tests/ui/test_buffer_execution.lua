local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/ui/helpers.lua')
local state = require('sqmeow.core.state')
local rpc = require('sqmeow.rpc.client')

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require('sqmeow').setup({ query = { persist_history = false } })
    end,
    post_case = function()
      -- Deleting the query buffer can focus the locked result grid.
      require('sqmeow.ui.result').close()
    end,
    post_once = function()
      rpc.stop()
      state.reset()
    end,
  },
})

local adapters = {
  -- Selection and unsaved-buffer handling are shared Lua logic. The Node integration suite
  -- (tests/integration) covers dialect boundaries and each server through RPC.
  sqlite = { url = 'sqlite::memory:' },
  duckdb = { url = 'duckdb::memory:' },
}

local function wait(id)
  helpers.wait_for('buffer execution settles', function()
    return state.call ~= nil and state.call.call_id == id and state.call.state ~= 'executing'
  end, 15000)
  eq(state.call.state, 'done')
  eq(state.call.rows > 0, true)
end

for name, spec in pairs(adapters) do
  local query = "SELECT 'a;b' AS note;"
  local id, buf, path
  local group = MiniTest.new_set({
    hooks = {
      pre_case = function()
        id = helpers.connect(spec.url, { name = name }, 15000)
        eq(state.connections[id].state, 'connected')
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(
          buf,
          0,
          -1,
          false,
          { 'unselected invalid query', query, 'unselected invalid query' }
        )
        vim.api.nvim_set_current_buf(buf)
        path = vim.fn.tempname()
        vim.fn.writefile({ 'stale invalid query on disk' }, path)
        vim.api.nvim_buf_set_name(buf, path)
        vim.bo[buf].modified = true
        vim.b[buf].sqmeow_connection = name
      end,
      post_case = function()
        if id then
          require('sqmeow.api.connection').disconnect(id)
        end
        if buf then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        if path then
          vim.fn.delete(path)
        end
        id, buf, path = nil, nil, nil
      end,
    },
  })
  T[name] = group

  group['visual key executes only unsaved selection'] = function()
    local execute, accepted = require('sqmeow.api.query').execute, nil
    helpers.stub(require('sqmeow.api.query'), 'execute', function(sql, opts)
      accepted = execute(sql, opts)
      return accepted
    end)
    require('sqmeow.ui.editor').attach(0, name)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.keycode('V<CR>'), 'mx', false)
    wait(assert(accepted, 'selection was accepted'))
    eq(state.call.statement, query)
  end

  group['explicit range executes unsaved requested lines'] = function()
    local execute, accepted = require('sqmeow.api.query').execute, nil
    helpers.stub(require('sqmeow.api.query'), 'execute', function(sql, opts)
      accepted = execute(sql, opts)
      return accepted
    end)
    vim.cmd('2Sqmeow execute')
    wait(assert(accepted, 'range was accepted'))
    eq(state.call.statement, query)
  end

  group['whole buffer uses unsaved content'] = function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })
    wait(assert(require('sqmeow.api.query').execute_buffer()))
    eq(state.call.statement, query)
  end
end

return T
