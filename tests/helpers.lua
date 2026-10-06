-- What more than one test file needs.

local MiniTest = require('mini.test')

local M = {}

--- Put a value in a table's field and answer with what was there.
---@param target table
---@param key string
---@param value any
---@return any original
function M.swap(target, key, value)
  local original = target[key]
  target[key] = value
  return original
end

--- Replace a field for the rest of the case, and put the original back when the case ends.
---@param target table
---@param key string
---@param value any
function M.stub(target, key, value)
  local original = M.swap(target, key, value)
  MiniTest.finally(function()
    target[key] = original
  end)
end

--- Wait for something the engine or the interface does asynchronously.
---@param what string What was waited for, for the failure message.
---@param condition fun(): boolean
---@param timeout integer|nil Milliseconds. Defaults to 5000.
function M.wait_for(what, condition, timeout)
  assert(vim.wait(timeout or 5000, condition, 10), what)
end

--- Open a connection and wait for the engine to settle it.
---@param url string
---@param opts table|nil Passed to `connect`, such as `{ name = 'grid' }`.
---@param timeout integer|nil Milliseconds. Defaults to 5000.
---@return integer id
function M.connect(url, opts, timeout)
  local state = require('sqmeow.core.state')
  local id = assert(
    require('sqmeow.api.connection').connect(url, opts),
    'the engine should accept the connection'
  )
  M.wait_for('the connection should settle', function()
    local connection = state.connections[id]
    return connection == nil or connection.state ~= 'connecting'
  end, timeout)
  return id
end

--- Run SQL and wait for the engine to finish with it.
---@param sql string
---@param opts table|nil Passed to `execute`.
---@param timeout integer|nil Milliseconds. Defaults to 5000.
---@return table summary The call the engine reported.
function M.run(sql, opts, timeout)
  local state = require('sqmeow.core.state')
  -- Tests drop and delete freely, so nothing asks first.
  opts = vim.tbl_extend('keep', opts or {}, { confirmed = true })
  local call_id =
    assert(require('sqmeow.api.query').execute(sql, opts), 'the query should be accepted: ' .. sql)
  M.wait_for('the query should settle: ' .. sql, function()
    return state.call ~= nil and state.call.call_id == call_id and state.call.state ~= 'executing'
  end, timeout)
  return assert(state.call, 'the query should leave a result')
end

--- Everything the result grid buffer holds.
---@return string[]
function M.result_lines()
  return vim.api.nvim_buf_get_lines(require('sqmeow.ui.result').buffer(), 0, -1, false)
end

--- The data rows, with the header dropped.
---@return string[]
function M.result_rows()
  return vim.list_slice(M.result_lines(), 3)
end

--- Fail unless `haystack` holds `needle` as plain text.
---@param haystack string|nil
---@param needle string
function M.contains(haystack, needle)
  assert(
    type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil,
    ('expected %s to contain %s'):format(vim.inspect(haystack), vim.inspect(needle))
  )
end

--- Fail if `haystack` holds `needle` as plain text.
---@param haystack string|nil
---@param needle string
function M.absent(haystack, needle)
  assert(
    type(haystack) ~= 'string' or haystack:find(needle, 1, true) == nil,
    ('expected %s to leave out %s'):format(vim.inspect(haystack), vim.inspect(needle))
  )
end

--- A scratch buffer, gone when the case ends.
---@param lines string[]|nil What it holds.
---@return integer buf
function M.temp_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  MiniTest.finally(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
  return buf
end

--- A file holding `contents`, gone when the case ends.
---@param contents string[]
---@return string path
function M.temp_file(contents)
  local path = vim.fn.tempname()
  vim.fn.writefile(contents, path)
  MiniTest.finally(function()
    vim.fn.delete(path)
  end)
  return path
end

--- Write fixture lines, making the directory first.
---@param path string
---@param lines string[]
function M.writefile(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end

return M
