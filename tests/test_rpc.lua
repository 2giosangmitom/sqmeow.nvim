local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local rpc = require('sqmeow.rpc.client')

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      rpc.stop()
    end,
  },
})

T['engine'] = MiniTest.new_set()

T['engine']['starts and answers a handshake'] = function()
  local channel, err = rpc.start()
  eq(err, nil)
  eq(type(channel), 'number')

  local info = assert(rpc.info())
  eq(type(info.core_version), 'string')
  eq(type(info.pid), 'number')
end

T['engine']['starts lazily, once'] = function()
  eq(rpc.is_running(), false)
  local first = rpc.start()
  local second = rpc.start()
  eq(first, second)
  eq(rpc.is_running(), true)
end

T['engine']['answers a request'] = function()
  eq(rpc.request('ping'), 'pong')
end

T['engine']['reports an unknown method without dying'] = function()
  local result, err = rpc.request('no_such_method')
  eq(result, nil)
  eq(err ~= nil, true)
  helpers.contains(assert(err, 'there should be an error'), 'no_such_method')
  -- The channel survives a rejected call.
  eq(rpc.request('ping'), 'pong')
end

T['engine']['stops cleanly'] = function()
  rpc.start()
  rpc.stop()
  eq(rpc.is_running(), false)
  eq(rpc.info(), nil)
end

T['engine']['restarts'] = function()
  local first = rpc.start()
  local pid = rpc.info().pid
  local second = rpc.restart()
  eq(second ~= first, true)
  eq(rpc.info().pid ~= pid, true)
end

-- Subscriptions outlive a case.
local unsubscribes = {}

local function subscribe(event, callback)
  table.insert(unsubscribes, rpc.on(event, callback))
end

T['events'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      for _, unsubscribe in ipairs(unsubscribes) do
        unsubscribe()
      end
      unsubscribes = {}
    end,
  },
})

T['events']['reach a subscriber'] = function()
  local seen = {}
  subscribe('call:state', function(payload)
    table.insert(seen, payload)
  end)

  rpc.dispatch('call:state', { state = 'done' })
  eq(#seen, 1)
  eq(seen[1].state, 'done')
end

T['events']['defer RPC callbacks and preserve event order across handler requests'] = function()
  rpc.start()
  local seen, waiting, returned = {}, false, false
  helpers.stub(vim, 'rpcrequest', function(_, method)
    waiting = true
    if method == 'outer' then
      rpc.dispatch('ordered', 1)
      rpc.dispatch('ordered', 2)
    elseif method == 'inner' then
      rpc.dispatch('ordered', 3)
    end
    waiting = false
    return true
  end)
  subscribe('ordered', function(value)
    eq(waiting, false)
    eq(returned, true)
    table.insert(seen, value)
    if value == 1 then
      rpc.request('inner')
    end
  end)
  rpc.request('outer')
  returned = true
  rpc.dispatch('ordered', 4)
  helpers.wait_for('all deferred events arrive', function()
    return #seen == 4
  end)
  eq(seen, { 1, 2, 4, 3 })
end

T['events']['stop reaching an unsubscribed handler'] = function()
  local count = 0
  local unsubscribe = rpc.on('log', function()
    count = count + 1
  end)
  table.insert(unsubscribes, unsubscribe)

  rpc.dispatch('log', {})
  unsubscribe()
  rpc.dispatch('log', {})
  eq(count, 1)
end

T['events']['stop'] = MiniTest.new_set({ parametrize = { { false }, { true } } })

T['events']['stop']['discards events before a scheduled drain'] = function(exited)
  local on_exit
  helpers.stub(require('sqmeow.install'), 'resolve', function()
    return '/fake/engine', 'development'
  end)
  helpers.stub(vim.fn, 'jobstart', function(_, opts)
    on_exit = opts.on_exit
    return 123
  end)
  helpers.stub(vim.fn, 'jobstop', function(job)
    on_exit(job, 0)
  end)
  helpers.stub(vim, 'rpcrequest', function(_, method)
    if method == 'queue' or method == 'shutdown' then
      rpc.dispatch('stopped', method)
    end
    return {}
  end)

  local seen = {}
  subscribe('stopped', function(payload)
    table.insert(seen, payload)
  end)

  rpc.request('queue')
  eq(seen, {})
  if exited then
    on_exit(123, 0)
  end
  eq(rpc.is_running(), not exited)
  rpc.stop()
  eq(rpc.is_running(), false)

  local drained = false
  vim.schedule(function()
    drained = true
  end)
  helpers.wait_for('the scheduled drain runs after stop', function()
    return drained
  end)
  eq(seen, {})

  -- Stopping keeps subscriptions usable for subsequent events.
  rpc.dispatch('stopped', 'fresh')
  eq(seen, { 'fresh' })
end

T['events']['survive a failing subscriber'] = function()
  local reached = false
  subscribe('log', function()
    error('boom')
  end)
  subscribe('log', function()
    reached = true
  end)

  rpc.dispatch('log', {})
  eq(reached, true)
end

T['events']['are ignored when nobody is listening'] = function()
  rpc.dispatch('nobody:cares', {})
end

return T
