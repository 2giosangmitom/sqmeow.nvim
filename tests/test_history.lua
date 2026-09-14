local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local history = require('sqmeow.history')
local config = require('sqmeow.config')
local paths = require('sqmeow.paths')
local state = require('sqmeow.state')

-- Everything the log writes goes under here, so the suite never touches a real one.
local root = vim.fn.tempname()

--- Apply the configuration this suite runs on, under the scratch directory.
local function apply_root(extra)
  config.apply(vim.tbl_extend('force', { core = { path = root } }, extra or {}))
end

--- The log file for the configured directory.
---@return string
local function log_file()
  return paths.history()
end

--- Put something at a result path, standing in for the file the engine writes.
---@param path string
---@return string path
local function saved_file(path)
  helpers.writefile(path, { 'rows' })
  return path
end

--- A finished call, the shape the event handler passes on.
---@param overrides table|nil
---@return table
local function call(overrides)
  return vim.tbl_extend('force', {
    call_id = 1,
    conn_id = 1,
    state = 'done',
    rows = 3,
    elapsed_ms = 12,
    statement = 'select * from people',
  }, overrides or {})
end

--- What the file holds, one decoded entry per line.
---@return table[]
local function written()
  if not vim.uv.fs_stat(log_file()) then
    return {}
  end
  return vim.tbl_map(function(line)
    return vim.json.decode(line)
  end, vim.fn.readfile(log_file()))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      apply_root()
      history.clear()
    end,
    post_case = function()
      history.clear()
      state.reset()
      config.apply({})
    end,
    post_once = function()
      vim.fn.delete(root, 'rf')
    end,
  },
})

T['records a finished call'] = function()
  history.append(call())

  local entries = history.entries()
  eq(#entries, 1)
  eq(entries[1].statement, 'select * from people')
  eq(entries[1].rows, 3)
  eq(entries[1].elapsed_ms, 12)
  eq(entries[1].state, 'done')
end

T['names the connection the call ran on'] = function()
  state.connections[1] = {
    id = 1,
    name = 'production',
    url = 'sqlite::memory:',
    state = 'connected',
    dialect = 'postgres',
  }
  history.append(call())

  eq(history.entries()[1].connection, 'production')
  eq(history.entries()[1].dialect, 'postgres')
end

T['keeps a failure as readily as a success'] = function()
  history.append(call({ state = 'error', rows = nil, error = 'no such table: people' }))
  eq(history.entries()[1].state, 'error')
  eq(history.entries()[1].error, 'no such table: people')
end

T['leaves out a call the user did not submit'] = function()
  history.append(call({ history = false }))
  eq(history.entries(), {})
end

T['ignores a call with nothing to remember'] = function()
  history.append(call({ statement = '   ' }))

  local nothing = call()
  nothing.statement = nil
  history.append(nothing)

  eq(history.entries(), {})
end

T['on disk'] = MiniTest.new_set()

T['on disk']['writes a line per call'] = function()
  history.append(call({ call_id = 1, statement = 'select 1' }))
  history.append(call({ call_id = 2, statement = 'select 2' }))

  local lines = written()
  eq(#lines, 2)
  eq(lines[1].statement, 'select 1')
  eq(lines[2].statement, 'select 2')
end

T['on disk']['reads back what an earlier session left'] = function()
  helpers.writefile(log_file(), {
    vim.json.encode({ at = 1, session = 'earlier', call_id = 7, statement = 'select 7' }),
  })

  local entries = history.entries()
  eq(#entries, 1)
  eq(entries[1].statement, 'select 7')
end

T['on disk']['skips a line that does not decode'] = function()
  helpers.writefile(log_file(), {
    'this is not json',
    vim.json.encode({ at = 1, statement = 'select 1' }),
  })

  eq(#history.entries(), 1)
end

T['on disk']['notices the file changing underneath it'] = function()
  history.append(call({ statement = 'select 1' }))
  eq(#history.entries(), 1)

  -- Another editor, appending to the same log.
  local file = assert(io.open(log_file(), 'a'))
  file:write(vim.json.encode({ at = 2, statement = 'select 2' }), '\n')
  file:close()

  eq(#history.entries(), 2)
end

T['on disk']['keeps nothing when persistence is off'] = function()
  apply_root({ query = { persist_history = false } })

  history.append(call())
  eq(written(), {})
  -- Still listed, because the log within a session is the same list.
  eq(#history.entries(), 1)
end

T['on disk']['drops the oldest once the file is twice the limit'] = function()
  apply_root({ query = { history_limit = 3 } })

  for index = 1, 7 do
    history.append(call({ call_id = index, statement = ('select %d'):format(index) }))
  end

  local lines = written()
  eq(#lines, 3)
  eq(lines[1].statement, 'select 5')
  eq(lines[3].statement, 'select 7')
end

T['listing'] = MiniTest.new_set()

T['listing']['puts the newest first'] = function()
  history.append(call({ statement = 'select 1' }))
  history.append(call({ statement = 'select 2' }))

  eq(history.entries()[1].statement, 'select 2')
end

T['listing']['keeps every run of the same statement'] = function()
  for index = 1, 3 do
    history.append(call({ call_id = index, statement = 'select * from people' }))
  end

  -- Each run can have answered differently, so each one is there to go back to.
  local entries = history.entries()
  eq(#entries, 3)
  eq(entries[1].call_id, 3)
  eq(entries[3].call_id, 1)
end

T['listing']['tells apart the same statement on two connections'] = function()
  state.connections[1] = { id = 1, name = 'dev', url = 'sqlite::memory:', state = 'connected' }
  state.connections[2] =
    { id = 2, name = 'production', url = 'sqlite::memory:', state = 'connected' }
  history.append(call({ conn_id = 1 }))
  history.append(call({ conn_id = 2 }))

  eq(#history.entries(), 2)
end

T['listing']['narrows to one connection'] = function()
  state.connections[1] = { id = 1, name = 'dev', url = 'sqlite::memory:', state = 'connected' }
  state.connections[2] =
    { id = 2, name = 'production', url = 'sqlite::memory:', state = 'connected' }
  history.append(call({ conn_id = 1, statement = 'select 1' }))
  history.append(call({ conn_id = 2, statement = 'select 2' }))

  local entries = history.entries({ connection = 'dev' })
  eq(#entries, 1)
  eq(entries[1].statement, 'select 1')
end

T['listing']['stops at the limit'] = function()
  for index = 1, 5 do
    history.append(call({ call_id = index, statement = ('select %d'):format(index) }))
  end

  eq(#history.entries({ limit = 2 }), 2)
end

T['reopening'] = MiniTest.new_set()

T['reopening']['offers a result the engine still holds'] = function()
  state.record_call({ call_id = 4, state = 'done', rows = 1 })
  history.append(call({ call_id = 4 }))

  eq(history.reopenable(history.entries()[1]), true)
end

T['reopening']['refuses a call from a previous session'] = function()
  state.record_call({ call_id = 4, state = 'done', rows = 1 })
  history.append(call({ call_id = 4 }))

  local entry = vim.deepcopy(history.entries()[1])
  entry.session = 'earlier'
  eq(history.reopenable(entry), false)
end

T['reopening']['refuses a call the engine has evicted'] = function()
  history.append(call({ call_id = 99 }))
  eq(history.reopenable(history.entries()[1]), false)
end

T['clearing'] = function()
  history.append(call())
  history.clear()

  eq(history.entries(), {})
  eq(vim.uv.fs_stat(log_file()), nil)
end

T['results'] = MiniTest.new_set()

T['results']['are named inside the directory the log keeps them in'] = function()
  local first, second = history.result_path(), history.result_path()
  eq(first ~= second, true)
  eq(vim.startswith(first, paths.results() .. '/'), true)
end

T['results']['are pointed at only by a run that returned columns'] = function()
  local kept = history.result_path()
  history.append(call({ call_id = 1, archive = kept, columns = { { name = 'n' } } }))
  history.append(call({ call_id = 2, archive = history.result_path(), columns = {}, affected = 3 }))
  history.append(call({ call_id = 3, state = 'error', archive = history.result_path() }))

  local entries = history.entries()
  eq(entries[3].result, kept)
  eq(entries[2].result, nil)
  eq(entries[1].result, nil)
end

T['results']['count as saved only while the file is there'] = function()
  local path = history.result_path()
  history.append(call({ archive = path, columns = { { name = 'n' } } }))
  eq(history.saved(history.entries()[1]), false)

  saved_file(path)
  eq(history.saved(history.entries()[1]), true)
end

T['results']['go when the entry pointing at them is trimmed'] = function()
  apply_root({ query = { history_limit = 1 } })

  local saved = {}
  for index = 1, 3 do
    saved[index] = saved_file(history.result_path())
    history.append(call({ call_id = index, archive = saved[index], columns = { { name = 'n' } } }))
  end

  eq(vim.uv.fs_stat(saved[1]), nil)
  eq(vim.uv.fs_stat(saved[2]), nil)
  eq(vim.uv.fs_stat(saved[3]) ~= nil, true)
end

T['results']['are never deleted from outside their own directory'] = function()
  apply_root({ query = { history_limit = 1 } })

  local outside = helpers.temp_file({ 'keep me' })

  -- A log line edited by hand to name some other file.
  helpers.writefile(log_file(), {
    vim.json.encode({ at = 1, statement = 'select 0', result = outside }),
  })
  for index = 1, 2 do
    history.append(call({ call_id = index, statement = ('select %d'):format(index) }))
  end

  eq(#written(), 1)
  eq(vim.uv.fs_stat(outside) ~= nil, true)
  eq(history.saved({ result = outside }), false)
end

T['results']['go with the log when it is cleared'] = function()
  local path = saved_file(history.result_path())
  history.append(call({ archive = path, columns = { { name = 'n' } } }))
  history.clear()

  eq(vim.uv.fs_stat(paths.results()), nil)
end

T['ago'] = MiniTest.new_set()

T['ago']['says how long ago in words'] = function()
  local log = require('sqmeow.ui.log')
  local now = os.time()

  eq(log.ago(now), 'just now')
  eq(log.ago(now - 120), '2m ago')
  eq(log.ago(now - 7200), '2h ago')
  eq(log.ago(now - 172800), '2d ago')
  eq(log.ago(nil), '')
end

return T
