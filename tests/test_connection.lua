local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local connection = require('sqmeow.ui.connection')
local config = require('sqmeow.config')
local file = require('sqmeow.sources.file')

local scratch = vim.fs.joinpath(vim.fn.tempname(), 'connections.json')

local function close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    -- Closing a dialog takes its border window with it, so a handle from this list may already be
    -- gone by the time the loop reaches it.
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= '' then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- The dialog's lines, without the padding that lines the values up.
---@return string[]
local function rows()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == 'sqmeow-form' then
      return vim.tbl_map(function(line)
        return (vim.trim(line):gsub('%s%s+', ' '))
      end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end
  end
  return {}
end

--- Press a key that the dialog bound, the way a user would.
---@param key string
local function press(key)
  vim.api.nvim_feedkeys(vim.keycode(key), 'x', false)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not require('sqmeow.ui.form').available() then
        MiniTest.skip('nui.nvim is not installed')
      end
      config.apply({ sources = { { type = 'file', path = scratch } } })
    end,
    post_case = function()
      close_floats()
      config.apply({})
      pcall(vim.fn.delete, scratch)
    end,
  },
})

T['create'] = MiniTest.new_set()

T['create']['asks which database first'] = function()
  connection.create()

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(#lines, 6)
  MiniTest.expect.no_equality(lines[1]:find('PostgreSQL'), nil)
  MiniTest.expect.no_equality(lines[2]:find('MySQL'), nil)
  MiniTest.expect.no_equality(lines[3]:find('Redis'), nil)
  MiniTest.expect.no_equality(lines[4]:find('MongoDB'), nil)
  MiniTest.expect.no_equality(lines[5]:find('SQLite'), nil)
  MiniTest.expect.no_equality(lines[6]:find('Connection string'), nil)
end

T['create']['asks for a name and offers none'] = function()
  -- The name is what everything else will call this database, so it is the user's to choose. A
  -- default assembled out of the host and the database would also be a piece of the URL the form
  -- exists to keep off the screen.
  require('sqmeow.ui.form').open({
    title = 'New PostgreSQL connection',
    fields = require('sqmeow.dialects').fields('postgres'),
    on_submit = function() end,
  })

  eq(rows()[1], 'Name')
end

T['create']['refuses to save without a name'] = function()
  connection.edit({ name = '', url = 'sqlite:app.db' })
  press('<C-s>')
  vim.wait(50)

  -- Still open, because there is nothing to call the connection yet.
  MiniTest.expect.no_equality(#rows(), 0)
  eq(file.load({ path = scratch }), {})
end

T['from a url'] = MiniTest.new_set()

T['from a url']['saves the url as typed and connects'] = function()
  local api = require('sqmeow.api')
  local connect = api.connect
  local connected
  api.connect = function(url, opts)
    connected = { url = url, name = opts.name }
  end
  MiniTest.finally(function()
    api.connect = connect
  end)

  -- A template for the password is kept whole, which the form of separate fields cannot do.
  local url = 'postgres://app:{{ env "PGPASSWORD" }}@db.internal/shop'
  connection.from_url({ name = 'shop', url = url })
  eq(rows(), { 'Name shop', 'URL ' .. url })
  press('<C-s>')
  vim.wait(50)

  local saved = file.load({ path = scratch })
  eq(#saved, 1)
  eq({ saved[1].name, saved[1].url }, { 'shop', url })
  eq(connected, { url = url, name = 'shop' })
end

T['from a url']['refuses a url for a database the plugin does not speak'] = function()
  connection.from_url({ name = 'warehouse', url = 'oracle://host/db' })
  press('<C-s>')
  vim.wait(50)

  MiniTest.expect.no_equality(#rows(), 0)
  eq(file.load({ path = scratch }), {})
end

T['edit'] = MiniTest.new_set()

T['edit']['fills the form in from the saved url'] = function()
  local opened = connection.edit({
    name = 'shop',
    url = 'postgres://app:hunter2@db.internal:5432/orders?sslmode=require',
  })

  eq(opened, true)
  eq(rows(), {
    'Name shop',
    'Host db.internal',
    'Port 5432',
    'Database orders',
    'User app',
    'Password *******',
    'Options sslmode=require',
  })
end

T['edit']['asks a SQLite connection for a file and nothing else'] = function()
  connection.edit({ name = 'local', url = 'sqlite:app.db' })
  eq(rows(), { 'Name local', 'File app.db' })
end

T['edit']['refuses a url holding a template'] = function()
  -- Taking one apart and writing it back would percent encode the braces, so the caller is told
  -- to ask the older way instead.
  eq(connection.edit({ name = 'prod', url = 'postgres://app:{{ env "PGPASS" }}@host/db' }), false)
  eq(rows(), {})
end

T['edit']['refuses a url for a database the plugin does not have'] = function()
  eq(connection.edit({ name = 'warehouse', url = 'oracle://host/db' }), false)
end

T['edit']['writes the connection back when the form is saved'] = function()
  file.add({ name = 'shop', url = 'postgres://app@db.internal/orders' }, { path = scratch })

  connection.edit({ name = 'shop', url = 'postgres://app@db.internal/orders' })
  press('<C-s>')
  vim.wait(50)

  local saved = file.load({ path = scratch })
  eq(#saved, 1)
  eq(saved[1].name, 'shop')
  eq(saved[1].url, 'postgres://app@db.internal/orders')
end

return T
