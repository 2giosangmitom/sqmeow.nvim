--- What has been run, and how it went.
---
--- The log outlives the session. Every finished call is written to |sqmeow.history|, so a query
--- from last week is still here, and one from this session can be put back on screen without
--- running anything again.

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

--- Describe one entry for a picker row.
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

--- Act on one entry.
---
--- Its rows if the engine still has them, and the statement itself otherwise. Nothing is run: a
--- log holds deletes as readily as selects, and picking a line out of a list is not the same as
--- asking for it to happen again.
---
---@param entry table
function M.reopen(entry)
  if require('sqmeow.history').reopenable(entry) then
    return require('sqmeow.api').reopen(entry.call_id)
  end

  require('sqmeow.ui.editor').open_statement(entry.statement)
  vim.notify('sqmeow: the rows are long gone, so here is the query')
end

--- Choose a past query and put its result back on screen.
---
--- The list itself is |sqmeow.pickers|`.history`, so it is shown with whichever fuzzy picker the
--- user has. What lives here is what an entry says, which is the part the picker does not know.
function M.open()
  require('sqmeow.pickers').history()
end

return M
