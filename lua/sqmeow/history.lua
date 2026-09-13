--- The queries the user ran, and what they returned.
---
--- Only what the user submits is recorded: a statement run from a buffer, a selection, or the
--- command line. What the plugin asks on its own behalf is not, whether that is the engine reading
--- a schema for the drawer or a preview of a table, because nobody ran it, and a log full of it
--- buries what somebody did.
---
--- Every run is an entry of its own. A run that returned rows keeps them in a file beside the log,
--- written by the engine, so choosing an entry shows the result the query had then rather than
--- handing back the statement to run again. The same select run twice is two entries, because the
--- two runs can have answered differently and each answer is worth finding again.
---
--- The log itself is appended to, one line per call, which is why it is JSON lines rather than a
--- JSON array: appending needs no read of what is already there and no rewrite, so two editors
--- writing at once cannot lose each other's work.

local M = {}

--- Tells calls this Neovim made apart from ones read back from disk.
---
--- A call id means something only to the engine that issued it, so an id from a previous session
--- cannot be handed back to the engine running now.
M.session = ('%d.%d'):format(vim.uv.os_getpid(), vim.uv.hrtime())

-- Entries in the order they were run, with the path and the state of the file they were read
-- from. Both are checked before the list is served, so changing `core.path`, or another editor
-- appending to the same file, is noticed rather than served stale.
local cache = { path = '', entries = {}, stamp = nil }

-- Counts the result files this Neovim has named, so two queries in the same second get two.
local named = 0

--- Where the log is kept.
---@return string
function M.path()
  return require('sqmeow.paths').history()
end

--- A new file for the engine to save one result in.
---
--- Named by time, process and a counter, so neither two queries in one second nor two editors
--- sharing the directory can be handed the same name.
---
---@return string
function M.result_path()
  named = named + 1
  return vim.fs.joinpath(
    require('sqmeow.paths').results(),
    ('%d-%d-%d.msgpack'):format(os.time(), vim.uv.os_getpid(), named)
  )
end

--- Whether a path is one of the saved results.
---
--- Checked before a file is read back or deleted on the log's say-so, because the log is a text
--- file anyone can edit, and a line naming some other file is not a reason to delete that file.
---
---@param path any
---@return boolean
local function owned(path)
  if type(path) ~= 'string' then
    return false
  end
  local directory = require('sqmeow.paths').results() .. '/'
  return vim.fs.normalize(path):sub(1, #directory) == directory
end

--- Delete the result an entry kept, if it kept one.
---@param entry table
local function forget(entry)
  if owned(entry.result) then
    pcall(vim.fn.delete, entry.result)
  end
end

--- Read the file, skipping anything in it that is not an entry.
---
--- A line that does not decode is dropped rather than raising: a half-written line from a crash
--- should cost the user that one query, not the whole log.
---
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
---
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
---
--- Through a temporary file and a rename, so an editor reading the log while it is being trimmed
--- sees either the old file or the new one and never half of either.
---
---@param limit integer
local function trim(limit)
  -- Trimming on every call would rewrite the file constantly, so it happens once the file has
  -- grown to twice what is kept.
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
---
--- Written where it happens rather than scheduled: it is one short line once per query, and doing
--- it in order is what keeps the file and what is held in memory saying the same thing.
---
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

--- Record a query the user ran, once it has stopped running.
---
--- Called for everything that stops, including a failure and a cancellation, because what went
--- wrong is as much worth finding again as what worked. A call marked `history = false` is left
--- out: that is SQL the plugin wrote, or a logged result being shown again.
---
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

  -- The engine saves a result only once it has finished with columns to save, so that is when
  -- the entry points at one. A statement that changed rows without returning any has nothing to
  -- show beyond what the entry says.
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

--- The queries to show, newest first, one per run.
---
---@param opts table|nil `connection` narrows to one name, `limit` caps the list.
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

--- Whether the engine running now still holds this call's rows in memory.
---
--- True only for a call this Neovim made: after a restart the engine has a new set of ids, and the
--- results the old ones named are gone with it.
---
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

--- Whether this entry's result was saved and is still there to read.
---
---@param entry table
---@return boolean
function M.saved(entry)
  return owned(entry.result) and vim.uv.fs_stat(entry.result) ~= nil
end

--- Forget everything, on disk and in memory, results included.
---@return boolean cleared
function M.clear()
  local path = M.path()
  local cleared = pcall(vim.fn.delete, path)
  pcall(vim.fn.delete, require('sqmeow.paths').results(), 'rf')
  cache = { path = path, entries = {}, stamp = stamp(path) }
  return cleared
end

return M
