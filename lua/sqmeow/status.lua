--- What the plugin is doing, as a plain table.
---
--- Deliberately frontend-agnostic. lualine is one consumer, but heirline, mini.statusline and a
--- hand-written `'statusline'` all want the same facts in different shapes, so what lives here is
--- the facts. The lualine component is a thin wrapper, and the tests exercise this rather than
--- lualine, so the component cannot break without a test noticing.
---
---@tag sqmeow.status
---@toc_entry Statusline
---

local M = {}

---@class sqmeow.Status
---@field connection string|nil The current connection's name.
---@field dialect string|nil 'postgres', 'mysql' or 'sqlite'.
---@field state 'idle'|'executing'|'done'|'error'|'cancelled' What the last query is doing.
---@field rows integer|nil Rows in the current result.
---@field page integer|nil Which page is shown, counting from one.
---@field pages integer|nil How many pages there are.
---@field elapsed_ms integer|nil How long the last query took.
---@field truncated boolean|nil Whether the row cap was reached.

--- How long each frame of the spinner shown while a query runs is on screen.
---
--- The spinner is advanced by the clock rather than by a timer, so nothing has to be started,
--- stopped, or cleaned up: a statusline redraws often enough on its own that reading the time is
--- all it takes. Its frames are `icons.spinner` in the configuration.
M.frame_ms = 80

--- The current spinner frame.
---
---@param now integer|nil Milliseconds, for tests. Defaults to the clock.
---@return string
function M.frame(now)
  now = now or math.floor(vim.uv.now())
  local frames = require('sqmeow.icons').spinner()

  return frames[math.floor(now / M.frame_ms) % #frames + 1]
end

--- A snapshot of the session.
---
--- Always the same shape. `state` is `'idle'` rather than nil when nothing has run, so a consumer
--- can switch on it without checking for absence first.
---
---@return sqmeow.Status
function M.get()
  local state = require('sqmeow.state')
  local connection = state.current_connection()
  local call = state.call or {}

  return {
    connection = connection and connection.name or nil,
    dialect = connection and connection.dialect or nil,
    state = call.state or 'idle',
    rows = call.rows,
    page = call.page,
    pages = call.pages,
    elapsed_ms = call.elapsed_ms,
    truncated = call.truncated,
  }
end

--- Whether there is anything worth putting in a statusline.
---
--- False before the first connection, which is what keeps the component invisible for users who
--- have the plugin installed and are not using it right now.
---@return boolean
function M.active()
  return require('sqmeow.state').current_connection() ~= nil
end

--- The one-line form, for a statusline that wants a string.
---
--- Shows the connection, and then whatever the last query is doing: a spinner while it runs, the
--- row count and how long it took once it is finished, and the page position when there is more
--- than one page.
---
---@param status sqmeow.Status|nil Defaults to the current one.
---@return string
function M.render(status)
  status = status or M.get()
  if not status.connection then
    return ''
  end

  local icons = require('sqmeow.icons')
  local parts = { ('%s %s'):format(icons.dialect(status.dialect), status.connection) }

  if status.state == 'executing' then
    table.insert(parts, M.frame())
  elseif status.state == 'error' then
    table.insert(parts, 'error')
  elseif status.state == 'cancelled' then
    table.insert(parts, 'cancelled')
  elseif status.state == 'done' then
    local rows = status.rows or 0
    table.insert(parts, ('%d row%s'):format(rows, rows == 1 and '' or 's'))
    if status.truncated then
      table.insert(parts, '+')
    end
    if status.pages and status.pages > 1 then
      table.insert(parts, ('%d/%d'):format(status.page or 1, status.pages))
    end
    if status.elapsed_ms then
      table.insert(parts, require('sqmeow.ui.result').format_duration(status.elapsed_ms))
    end
  end

  return table.concat(parts, ' ')
end

return M
