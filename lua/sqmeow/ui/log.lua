--- What has been run, and how it went.
---
--- The engine still holds the rows of every result in its history, so an entry here is not just a
--- record: picking one puts it back in the result window without running anything again.

local M = {}

--- Describe one entry for a picker row.
---
---@param summary sqmeow.CallSummary
---@return string
function M.describe(summary)
  local result = require('sqmeow.ui.result')
  local state = summary.state

  local outcome
  if state == 'error' then
    outcome = 'error'
  elseif state == 'cancelled' then
    outcome = 'cancelled'
  elseif summary.rows and summary.rows > 0 then
    outcome = ('%d rows'):format(summary.rows)
  elseif summary.affected then
    outcome = ('%d affected'):format(summary.affected)
  else
    outcome = 'no rows'
  end

  local elapsed = summary.elapsed_ms and result.format_duration(summary.elapsed_ms) or ''
  local statement = (summary.statement or ''):gsub('%s+', ' '):gsub('^%s', '')

  return ('%-12s %8s  %s'):format(outcome, elapsed, statement)
end

--- The recorded queries, newest first.
---@return sqmeow.CallSummary[]
function M.entries()
  return require('sqmeow.state').calls
end

--- Choose a past query and put its result back on screen.
function M.open()
  local entries = M.entries()
  if #entries == 0 then
    vim.notify('sqmeow: nothing has been run yet')
    return
  end

  vim.ui.select(entries, {
    prompt = 'Query log',
    format_item = M.describe,
  }, function(chosen)
    if chosen then
      require('sqmeow.api').reopen(chosen.call_id)
    end
  end)
end

return M
