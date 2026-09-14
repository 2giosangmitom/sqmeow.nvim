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
---@param opts table|nil Passed to `api.connect`, such as `{ name = 'grid' }`.
---@param timeout integer|nil Milliseconds. Defaults to 5000.
---@return integer id
function M.connect(url, opts, timeout)
  local api = require('sqmeow.api')
  local state = require('sqmeow.state')
  local id = assert(api.connect(url, opts), 'the engine should accept the connection')
  M.wait_for('the connection should settle', function()
    local connection = state.connections[id]
    return connection == nil or connection.state ~= 'connecting'
  end, timeout)
  return id
end

--- Run SQL and wait for the engine to finish with it.
---@param sql string
---@param opts table|nil Passed to `api.execute`.
---@param timeout integer|nil Milliseconds. Defaults to 5000.
---@return table summary The call the engine reported.
function M.run(sql, opts, timeout)
  local api = require('sqmeow.api')
  local state = require('sqmeow.state')
  local call_id = assert(api.execute(sql, opts), 'the query should be accepted: ' .. sql)
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

--- The column names and the rule under them.
---@return string[]
function M.result_header()
  return vim.list_slice(M.result_lines(), 1, 2)
end

--- The data rows, with the header dropped.
---@return string[]
function M.result_rows()
  return vim.list_slice(M.result_lines(), 3)
end

--- The drawer's lines, as they are drawn now.
---@return string[]
function M.drawer_lines()
  return vim.api.nvim_buf_get_lines(require('sqmeow.ui.drawer').buffer(), 0, -1, false)
end

--- Wait until the drawer draws a line matching `pattern`, then answer with the first one's number.
---@param pattern string A Lua pattern.
---@param timeout integer|nil Milliseconds. Defaults to 5000.
---@return integer number
function M.drawer_line(pattern, timeout)
  local found
  vim.wait(timeout or 5000, function()
    for number, line in ipairs(M.drawer_lines()) do
      if line:find(pattern) then
        found = number
        return true
      end
    end
    return false
  end, 20)
  return assert(
    found,
    ('no line matching %q; drawer holds:\n%s'):format(pattern, table.concat(M.drawer_lines(), '\n'))
  )
end

--- Every extmark on one line of a buffer, as `{ group, from, to }` in column order.
---@param buf integer
---@param namespace string The namespace's name, such as `'sqmeow.drawer'`.
---@param number integer The line, counted from one.
---@return { group: string, from: integer, to: integer }[]
function M.marks_on(buf, namespace, number)
  local found = vim.api.nvim_buf_get_extmarks(
    buf,
    vim.api.nvim_create_namespace(namespace),
    { number - 1, 0 },
    { number - 1, -1 },
    { details = true }
  )

  local spans = vim.tbl_map(function(mark)
    return { group = mark[4].hl_group, from = mark[3], to = mark[4].end_col }
  end, found)
  table.sort(spans, function(left, right)
    return left.from < right.from
  end)
  return spans
end

--- Plain characters for what a column holds.
---@return table<string, string>
function M.ascii_icons()
  return {
    text = 't',
    number = 'n',
    boolean = 'b',
    temporal = 'd',
    json = 'j',
    uuid = 'u',
    binary = 'y',
    unknown = '?',
    primary_key = 'K',
    foreign_key = 'k',
  }
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

--- Close whatever floats are open.
function M.close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= '' then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- The first window holding a buffer `predicate` accepts, or nil.
---@param predicate fun(win: integer, buf: integer): boolean
---@return integer|nil
function M.find_win(predicate)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if predicate(win, buf) then
      return win
    end
  end
  return nil
end

--- Buffer-local normal-mode maps, keyed by what they are pressed as.
---@param buf integer
---@return table<string, string|nil>
function M.buf_maps(buf)
  local seen = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    seen[map.lhs] = map.desc
  end
  return seen
end

return M
