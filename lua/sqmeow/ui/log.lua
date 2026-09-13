--- What has been run, and what came back.
---
--- The log outlives the session. Every query the user submits is written to |sqmeow.history| with
--- the rows it returned, so choosing one shows its result again, from last week as readily as from
--- a minute ago, without running anything.

local M = {}

--- How long ago something ran, in words.
---
--- Rounded hard, because the point is to tell this morning's query from last month's, not to time
--- anything.
---
---@param at integer|nil Seconds since the epoch.
---@return string
function M.ago(at)
  if type(at) ~= 'number' then
    return ''
  end

  local seconds = math.max(0, os.time() - at)
  if seconds < 60 then
    return 'just now'
  end
  if seconds < 3600 then
    return ('%dm ago'):format(math.floor(seconds / 60))
  end
  if seconds < 86400 then
    return ('%dh ago'):format(math.floor(seconds / 3600))
  end
  return ('%dd ago'):format(math.floor(seconds / 86400))
end

--- What one entry says, without its statement.
---
---@param entry table
---@return string
local function outcome(entry)
  if entry.state == 'error' then
    return 'error'
  end
  if entry.state == 'cancelled' then
    return 'cancelled'
  end
  if entry.rows and entry.rows > 0 then
    return ('%d rows'):format(entry.rows)
  end
  if entry.affected then
    return ('%d affected'):format(entry.affected)
  end
  return 'no rows'
end

--- Describe one entry as a single line.
---
---@param entry table
---@return string
function M.describe(entry)
  local elapsed = entry.elapsed_ms and require('sqmeow.ui.result').format_duration(entry.elapsed_ms)
  local statement = (entry.statement or ''):gsub('%s+', ' '):gsub('^%s', '')

  return ('%-9s %-12s %8s  %s'):format(M.ago(entry.at), outcome(entry), elapsed or '', statement)
end

--- The recorded queries, newest first, one row per statement.
---
---@param opts table|nil `connection` narrows to one name, `limit` caps the list.
---@return table[]
function M.entries(opts)
  return require('sqmeow.history').entries(opts)
end

--- Show what one entry returned.
---
--- From the engine's memory when it still holds the result, and from the copy saved with the log
--- otherwise. Nothing is run either way: a log holds deletes as readily as selects, and picking a
--- line out of a list is not the same as asking for it to happen again.
---
---@param entry table
function M.reopen(entry)
  local history = require('sqmeow.history')
  local api = require('sqmeow.api')

  if history.reopenable(entry) then
    return api.reopen(entry.call_id)
  end
  if history.saved(entry) then
    return api.restore(entry)
  end

  if entry.state == 'done' and (entry.rows or 0) > 0 then
    return vim.notify('sqmeow: the rows this query returned were not kept', vim.log.levels.WARN)
  end

  -- A failure, a cancellation, or a statement that changed rows rather than returning any: what
  -- the log recorded is the whole of what there is to show.
  local state = require('sqmeow.state')
  local result = require('sqmeow.ui.result')
  local connection = entry.connection and state.connection_by_name(entry.connection)

  result.open()
  state.call = {
    conn_id = connection and connection.id or nil,
    state = entry.state,
    error = entry.error,
    rows = entry.rows,
    affected = entry.affected,
    elapsed_ms = entry.elapsed_ms,
    statement = entry.statement,
    history = false,
    connection = entry.connection,
    dialect = entry.dialect,
    ran_at = entry.at,
  }
  result.render(state.call)
end

--- Show the log in the drawer.
---
--- The drawer is the one place the plugin lists things, so `:Sqmeow log` opens it there rather
--- than in a window of its own: one tree holding connections, scratchpads and what has been run.
function M.open()
  local drawer = require('sqmeow.ui.drawer')
  drawer.open()
  drawer.reveal_history()
end

return M
