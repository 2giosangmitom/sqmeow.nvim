--- Queries that outlive the session.
---
--- Every finished call is written to a file of JSON lines, so the log is still there tomorrow. It
--- holds what was run and how it went, not the rows: a cached grid goes stale the moment the table
--- changes, and re-running a statement you can see is both cheaper and honest.
---
--- The file is appended to, one line per call, which is why it is JSON lines rather than a JSON
--- array: appending needs no read of what is already there and no rewrite, so two editors writing
--- at once cannot lose each other's work.

local M = {}

--- Tells calls this Neovim made apart from ones read back from disk.
---
--- A call id means something only to the engine that issued it, so an id from a previous session
--- cannot be handed back to the engine running now.
M.session = ('%d.%d'):format(vim.uv.os_getpid(), vim.uv.hrtime())

-- Entries in the order they were run, with the path and the state of the file they were read
-- from. Both are checked before the list is served, so changing the configured path, or another
-- editor appending to the same file, is noticed rather than served stale.
local cache = { path = nil, entries = {}, stamp = nil }

--- Where the history is kept.
---
--- Under `stdpath('state')` rather than `stdpath('data')`: it is a record of what happened here,
--- not something the user would carry to another machine.
---
---@return string
function M.path()
  local configured = require('sqmeow.config').get().query.history_file
  if configured ~= '' then
    return vim.fs.normalize(configured)
  end
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'sqmeow', 'history.jsonl')
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
      local decoded, entry = pcall(vim.json.decode, line)
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

--- Rewrite the file with the newest entries only.
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

  cache.entries = vim.list_slice(cache.entries, #cache.entries - limit + 1, #cache.entries)

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

--- Record a finished call.
---
--- Called for everything that stops running, including a failure and a cancellation, because what
--- went wrong is as much worth finding again as what worked.
---
---@param summary sqmeow.CallSummary
function M.append(summary)
  local statement = summary.statement
  if type(statement) ~= 'string' or vim.trim(statement) == '' then
    return
  end

  local query = require('sqmeow.config').get().query
  local connection = require('sqmeow.state').connections[summary.conn_id]

  local entry = {
    at = os.time(),
    session = M.session,
    call_id = summary.call_id,
    connection = connection and connection.name or nil,
    dialect = connection and connection.dialect or nil,
    statement = statement,
    state = summary.state,
    rows = summary.rows,
    affected = summary.affected,
    elapsed_ms = summary.elapsed_ms,
  }

  table.insert(loaded(), entry)

  if query.persist_history then
    write(entry)
    trim(query.history_limit)
  else
    -- Nothing is written, so nothing trims the file. The list still has to stop growing.
    while #cache.entries > query.history_limit do
      table.remove(cache.entries, 1)
    end
  end
end

--- The queries to show, newest first.
---
--- One row per statement: running the same select twenty times while working something out should
--- leave one line to come back to, not twenty.
---
---@param opts table|nil `connection` narrows to one name, `limit` caps the list.
---@return table[]
function M.entries(opts)
  opts = opts or {}

  local all = loaded()
  local seen = {}
  local newest = {}

  for index = #all, 1, -1 do
    local entry = all[index]
    if not opts.connection or entry.connection == opts.connection then
      local key = ('%s\0%s'):format(entry.connection or '', entry.statement)
      if not seen[key] then
        seen[key] = true
        table.insert(newest, entry)
        if opts.limit and #newest >= opts.limit then
          break
        end
      end
    end
  end

  return newest
end

--- Whether the engine can still put this call's rows back on screen.
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

--- Forget everything, on disk and in memory.
---@return boolean cleared
function M.clear()
  local path = M.path()
  local cleared = pcall(vim.fn.delete, path)
  cache = { path = path, entries = {}, stamp = stamp(path) }
  return cleared
end

return M
