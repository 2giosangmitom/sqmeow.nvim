local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local connection = require('sqmeow.ui.connection')
local config = require('sqmeow.config')
local file = require('sqmeow.sources.file')

local scratch = vim.fs.joinpath(vim.fn.tempname(), 'connections.json')

--- The dialog's lines, without the padding that lines the values up.
---@return string[]
local function rows()
  local win = helpers.find_win(function(_, buf)
    return vim.bo[buf].filetype == 'sqmeow-form'
  end)
  if not win then
    return {}
  end
  return vim.tbl_map(function(line)
    return (vim.trim(line):gsub('%s%s+', ' '))
  end, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
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
      helpers.close_floats()
      config.apply({})
      pcall(vim.fn.delete, scratch)
    end,
  },
})

T['create'] = MiniTest.new_set()

T['create']['asks which database first'] = function()
  connection.create()

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(#lines, 10)
  helpers.contains(lines[1], 'PostgreSQL')
  helpers.contains(lines[2], 'MySQL')
  helpers.contains(lines[3], 'Redis')
  helpers.contains(lines[4], 'MongoDB')
  helpers.contains(lines[5], 'ScyllaDB')
  helpers.contains(lines[6], 'SurrealDB')
  helpers.contains(lines[7], 'ClickHouse')
  helpers.contains(lines[8], 'SQLite')
  helpers.contains(lines[9], 'DuckDB')
  helpers.contains(lines[10], 'Connection string')
end

T['create']['asks for a name and offers none'] = function()
  -- The name is what everything else will call this database.
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
  local connected
  helpers.stub(require('sqmeow.api'), 'connect', function(url, opts)
    connected = { url = url, name = opts.name }
  end)

  -- A template for the password is kept whole, which the form of separate fields cannot do.
  local url = 'postgres://app:{{ env "PGPASSWORD" }}@db.internal/shop'
  connection.from_url({ name = 'shop', url = url })
  eq(rows(), { 'Name shop', 'URL ' .. url, 'SSH user@bastion', 'Read only [ ]' })
  press('<C-s>')
  vim.wait(50)

  local saved = file.load({ path = scratch })
  eq(#saved, 1)
  eq({ saved[1].name, saved[1].url }, { 'shop', url })
  eq(connected, { url = url, name = 'shop' })
end

T['from a url']['saves the SSH host a connection goes through'] = function()
  local connected
  helpers.stub(require('sqmeow.api'), 'connect', function(_, opts)
    connected = opts.ssh
  end)

  connection.from_url({ name = 'far', url = 'postgres://app@db.internal/shop', ssh = 'me@bastion' })
  eq(rows()[3], 'SSH me@bastion')
  press('<C-s>')
  vim.wait(50)

  eq(file.load({ path = scratch })[1].ssh, 'me@bastion')
  eq(connected, 'me@bastion')
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
    'SSH user@bastion',
    'Read only [ ]',
  })
end

T['edit']['asks a SQLite connection for a file and nothing else'] = function()
  connection.edit({ name = 'local', url = 'sqlite:app.db', read_only = true })
  eq(rows(), { 'Name local', 'File app.db', 'Read only [x]' })
end

T['edit']['keeps a template whole through the form'] = function()
  local url = 'postgres://{{ env "PGUSER" }}:{{ exec "pass show db" }}@db.internal/shop'
  file.add({ name = 'prod', url = url }, { path = scratch })

  eq(connection.edit({ name = 'prod', url = url }), true)
  eq(rows()[5], 'User {{ env "PGUSER" }}')
  press('<C-s>')
  vim.wait(50)

  eq(file.load({ path = scratch })[1].url, url)
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
  eq(saved[1].read_only, nil)
end

T['edit']['saves the connection as read-only once its box is ticked'] = function()
  file.add({ name = 'shop', url = 'postgres://app@db.internal/orders' }, { path = scratch })

  connection.edit({ name = 'shop', url = 'postgres://app@db.internal/orders' })
  local last = #rows()
  vim.api.nvim_win_set_cursor(0, { last, 0 })
  press('<CR>')
  eq(rows()[last], 'Read only [x]')
  press('<C-s>')
  vim.wait(50)

  eq(file.load({ path = scratch })[1].read_only, true)
end

return T
