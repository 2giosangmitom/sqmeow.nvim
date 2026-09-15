--- Persists the query log and archived results on disk.
---
--- The log lives at `history/log.jsonl` (newline-delimited JSON) and results
--- under `history/results/`. Entries are filtered to valid objects with a
--- `statement` field; corrupted lines are skipped.

local M = {}

--- Identifies calls made by this Neovim instance.
M.session = ('%d.%d'):format(vim.uv.os_getpid(), vim.uv.hrtime())

-- Entries in the order they were run, with the path and the state of the file they were read from.
local cache = { path = '', entries = {}, stamp = nil }

-- Counts the result files this Neovim has named, so two queries in the same second get two.
local named = 0

--- Returns the path to the log file.
---@return string
function M.path()
  return require('sqmeow.paths').history()
end

--- Returns a new unique path for the engine to save one result in.
---@return string
function M.result_path()
  named = named + 1
  return vim.fs.joinpath(
    require('sqmeow.paths').results(),
    ('%d-%d-%d.msgpack'):format(os.time(), vim.uv.os_getpid(), named)
  )
end

--- Whether a path is one of the saved results.
---@param path any
---@return boolean
local function owned(path)
  if type(path) ~= 'string' then
    return false
  end
  local directory = require('sqmeow.paths').results() .. '/'
  return vim.fs.normalize(path):sub(1, #directory) == directory
end

--- Where the run's earlier statements' results were saved, or nil when none was.
---@param summary table
---@return string[]|nil
local function archives(summary)
  local paths = {}
  for _, entry in ipairs(summary.results or {}) do
    if entry.archive and entry.call_id ~= summary.call_id then
      table.insert(paths, entry.archive)
    end
  end
  return #paths > 0 and paths or nil
end

--- Delete the results an entry kept, if it kept any.
---@param entry table
local function forget(entry)
  for _, path in ipairs(vim.list_extend({ entry.result }, entry.results or {})) do
    if owned(path) then
      pcall(vim.fn.delete, path)
    end
  end
end

--- Read the file, skipping anything in it that is not an entry.
---@param path string
---@return table[]
local function read(path)
  if not vim.uv.fs_stat(path) then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return {}
  end

  local entries = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      local decoded, entry =
        pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if decoded and type(entry) == 'table' and type(entry.statement) == 'string' then
        table.insert(entries, entry)
      end
    end
  end
  return entries
end

--- What the file looked like when it was last read.
---@param path string
---@return string|nil
local function stamp(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  return ('%d.%d.%d'):format(stat.size, stat.mtime.sec, stat.mtime.nsec)
end

--- Everything recorded, oldest first, re-reading the file whenever it has changed.
---@return table[]
local function loaded()
  local path = M.path()
  local current = stamp(path)

  if cache.path ~= path or cache.stamp ~= current then
    cache = { path = path, entries = read(path), stamp = current }
  end
  return cache.entries
end

--- Rewrite the file with the newest entries only, and delete the results of the rest.
---@param limit integer
local function trim(limit)
  -- Trimming on every call would rewrite the file constantly.
  if #cache.entries <= limit * 2 then
    return
  end

  local dropped = #cache.entries - limit
  for index = 1, dropped do
    forget(cache.entries[index])
  end
  cache.entries = vim.list_slice(cache.entries, dropped + 1, #cache.entries)

  local temp = cache.path .. '.tmp'
  local lines = vim.tbl_map(function(entry)
    return vim.json.encode(entry)
  end, cache.entries)

  if pcall(vim.fn.writefile, lines, temp) then
    pcall(vim.uv.fs_rename, temp, cache.path)
    cache.stamp = stamp(cache.path)
  end
end

--- Append one line to the file.
---@param entry table
local function write(entry)
  vim.fn.mkdir(vim.fs.dirname(cache.path), 'p')

  -- Owner only. The log holds statements, and a statement can hold anything the person writing it
  -- put there.
  local file = io.open(cache.path, 'a')
  if not file then
    return
  end

  file:write(vim.json.encode(entry), '\n')
  file:close()
  pcall(vim.uv.fs_chmod, cache.path, 384)

  -- The file just changed, and it changed to exactly what is held here.
  cache.stamp = stamp(cache.path)
end

--- Records a finished query in the log.
---@param summary sqmeow.CallSummary
function M.append(summary)
  if summary.history == false then
    return
  end

  local statement = summary.statement
  if type(statement) ~= 'string' or vim.trim(statement) == '' then
    return
  end

  local query = require('sqmeow.config').get().query
  local connection = require('sqmeow.state').connections[summary.conn_id]

  -- The engine saves a result only once it has finished with columns to save.
  local kept = summary.state == 'done'
    and summary.archive
    and summary.columns
    and #summary.columns > 0

  local entry = {
    at = os.time(),
    session = M.session,
    call_id = summary.call_id,
    connection = connection and connection.name or nil,
    dialect = connection and connection.dialect or nil,
    statement = statement,
    state = summary.state,
    error = summary.error,
    rows = summary.rows,
    affected = summary.affected,
    elapsed_ms = summary.elapsed_ms,
    result = kept and summary.archive or nil,
    -- The saved results of the run's earlier statements.
    results = kept and archives(summary) or nil,
  }

  table.insert(loaded(), entry)

  if query.persist_history then
    write(entry)
    trim(query.history_limit)
  else
    -- Nothing is written, so nothing trims the file. The list still has to stop growing.
    while #cache.entries > query.history_limit do
      forget(table.remove(cache.entries, 1))
    end
  end
end

--- Returns log entries newest-first, one per run.
---@param opts table|nil Optional `connection` to filter by name and `limit` to cap length.
---@return table[]
function M.entries(opts)
  opts = opts or {}

  local all = loaded()
  local newest = {}

  for index = #all, 1, -1 do
    local entry = all[index]
    if not opts.connection or entry.connection == opts.connection then
      table.insert(newest, entry)
      if opts.limit and #newest >= opts.limit then
        break
      end
    end
  end

  return newest
end

--- Returns whether the current engine still holds this call's rows.
---@param entry table
---@return boolean
function M.reopenable(entry)
  if entry.session ~= M.session then
    return false
  end

  for _, call in ipairs(require('sqmeow.state').calls) do
    if call.call_id == entry.call_id then
      return true
    end
  end
  return false
end

--- Returns whether this entry's result file still exists on disk.
---@param entry table
---@return boolean
function M.saved(entry)
  return owned(entry.result) and vim.uv.fs_stat(entry.result) ~= nil
end

--- Clears the log and all archived results from disk and memory.
---@return boolean cleared
function M.clear()
  local path = M.path()
  local cleared = pcall(vim.fn.delete, path)
  pcall(vim.fn.delete, require('sqmeow.paths').results(), 'rf')
  cache = { path = path, entries = {}, stamp = stamp(path) }
  return cleared
end

return M
