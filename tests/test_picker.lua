local eq = MiniTest.expect.equality
local picker = require('sqmeow.integrations.picker')
local config = require('sqmeow.config')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.apply({})
    end,
    post_case = function()
      config.apply({})
    end,
  },
})

--- Replace a backend for the length of one case.
local function fake(name, available, run)
  local original = picker.backends[name]
  picker.backends[name] = { available = available, run = run or function() end }
  MiniTest.finally(function()
    picker.backends[name] = original
  end)
end

local function absent()
  return false
end

local function present()
  return true
end

T['resolve'] = MiniTest.new_set()

T['resolve']['falls back to the built-in prompt when nothing is installed'] = function()
  fake('telescope', absent)
  fake('fzf-lua', absent)
  fake('snacks', absent)
  eq(picker.resolve(), 'builtin')
end

T['resolve']['prefers telescope when several are installed'] = function()
  fake('telescope', present)
  fake('fzf-lua', present)
  fake('snacks', present)
  eq(picker.resolve(), 'telescope')
end

T['resolve']['takes the next one along when the first is missing'] = function()
  fake('telescope', absent)
  fake('fzf-lua', present)
  fake('snacks', present)
  eq(picker.resolve(), 'fzf-lua')
end

T['resolve']['honours an explicit choice'] = function()
  fake('telescope', present)
  fake('snacks', present)
  config.apply({ integrations = { picker = 'snacks' } })
  eq(picker.resolve(), 'snacks')
end

T['resolve']['falls back when the chosen picker is not installed'] = function()
  fake('fzf-lua', absent)
  config.apply({ integrations = { picker = 'fzf-lua' } })
  eq(picker.resolve(), 'builtin')
end

T['pick'] = MiniTest.new_set()

T['pick']['sends the chosen item to the caller'] = function()
  local chosen = nil
  fake('telescope', present, function(items, opts)
    opts.on_choice(items[2])
  end)

  picker.pick({ 'one', 'two' }, {
    prompt = 'Pick',
    format = function(item)
      return item
    end,
    on_choice = function(item)
      chosen = item
    end,
  })

  eq(chosen, 'two')
end

T['pick']['shows nothing and says so when the list is empty'] = function()
  local shown = false
  fake('telescope', present, function()
    shown = true
  end)

  eq(
    picker.pick({}, {
      prompt = 'Pick',
      format = tostring,
      on_choice = function() end,
    }),
    nil
  )
  eq(shown, false)
end

T['pick']['falls back to the built-in prompt when a backend raises'] = function()
  local chosen = nil
  fake('telescope', present, function()
    error('telescope changed its API again')
  end)

  local select = vim.ui.select
  vim.ui.select = function(items, _, on_choice)
    on_choice(items[1])
  end
  MiniTest.finally(function()
    vim.ui.select = select
  end)

  local used = picker.pick({ 'one' }, {
    prompt = 'Pick',
    format = tostring,
    on_choice = function(item)
      chosen = item
    end,
  })

  eq(used, 'builtin')
  eq(chosen, 'one')
end

T['builtin'] = MiniTest.new_set()

T['builtin']["formats each row through the caller's function"] = function()
  local labels = nil
  local select = vim.ui.select
  vim.ui.select = function(items, opts)
    labels = vim.tbl_map(opts.format_item, items)
  end
  MiniTest.finally(function()
    vim.ui.select = select
  end)

  config.apply({ integrations = { picker = 'builtin' } })
  picker.pick({ { name = 'db' }, { name = 'other' } }, {
    prompt = 'Pick',
    format = function(item)
      return item.name:upper()
    end,
    on_choice = function() end,
  })

  eq(labels, { 'DB', 'OTHER' })
end

T['builtin']['does not call back when the user cancels'] = function()
  local called = false
  local select = vim.ui.select
  vim.ui.select = function(_, _, on_choice)
    on_choice(nil)
  end
  MiniTest.finally(function()
    vim.ui.select = select
  end)

  config.apply({ integrations = { picker = 'builtin' } })
  picker.pick({ 'one' }, {
    prompt = 'Pick',
    format = tostring,
    on_choice = function()
      called = true
    end,
  })

  eq(called, false)
end

return T
