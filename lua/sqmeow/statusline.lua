--- Statusline helpers and Lualine components.
---
--- Exposes structured state (`status()`) and ready-to-use component functions
--- (`component()` and `column()`) for `lualine.nvim`, `heirline.nvim`,
--- `mini.statusline`, or custom `'statusline'` definitions.
---
--- Example `lualine.nvim` setup with `ui = { winbar = false }`: >lua
---   require('lualine').setup({
---     sections = {
---       lualine_x = {
---         {
---           function() return require('sqmeow.statusline').column() end,
---           cond = function() return require('sqmeow.statusline').column() ~= '' end,
---         },
---       },
---       lualine_y = {
---         {
---           function() return require('sqmeow.statusline').component() end,
---           cond = function() return require('sqmeow.statusline').active() end,
---         },
---       },
---     },
---   })
--- <
---@tag sqmeow-statusline
---@toc_entry Statusline

local M = {}

local db_filetypes = {
  sql = true,
  mysql = true,
  plsql = true,
  surql = true,
  cql = true,
  redis = true,
  ['sqmeow-result'] = true,
  ['sqmeow-drawer'] = true,
}

---@param bufnr integer|nil
---@return integer
local function resolve_buf(bufnr)
  if bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return vim.api.nvim_get_current_buf()
end

---@param buf integer
---@return 'result'|'drawer'|'preview'|'alter'|'routine'|'query'|nil
local function detect_role(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ft = vim.bo[buf].filetype
  local name = vim.api.nvim_buf_get_name(buf)
  if ft == 'sqmeow-result' or name:find('sqmeow://result', 1, true) then
    return 'result'
  end
  if ft == 'sqmeow-drawer' or name:find('sqmeow://drawer', 1, true) then
    return 'drawer'
  end
  if name:match('%[Preview: ') then
    return 'preview'
  end
  if name:match('%[Alter: ') then
    return 'alter'
  end
  if name:match('%[Routine: ') then
    return 'routine'
  end
  if
    db_filetypes[ft]
    or vim.b[buf].sqmeow_editor
    or vim.b[buf].sqmeow_connection
    or name:find('sqmeow://', 1, true)
  then
    return 'query'
  end
  return nil
end

---@param spec table|nil
---@param call table|nil
---@return boolean
local function is_filtered(spec, call)
  if call and call.aggregated then
    return true
  end
  if not spec then
    return false
  end
  return (spec.where or '') ~= ''
    or (spec.order_by or '') ~= ''
    or (spec.group_by or '') ~= ''
    or (spec.aggregates or '') ~= ''
    or (spec.having or '') ~= ''
    or (spec.filters and #spec.filters > 0)
    or (spec.sort and #spec.sort > 0)
    or (spec.hidden and not vim.tbl_isempty(spec.hidden))
    or false
end

--- Whether `bufnr` (default current buffer) is a database editor, preview, drawer, or result buffer.
---@param bufnr integer|nil Buffer handle; defaults to the current buffer.
---@return boolean
function M.active(bufnr)
  return detect_role(resolve_buf(bufnr)) ~= nil
end

--- Structured statusline state for `bufnr`, or nil outside database buffers.
---@param bufnr integer|nil Buffer handle; defaults to the current buffer.
---@return table|nil status
function M.status(bufnr)
  local buf = resolve_buf(bufnr)
  local role = detect_role(buf)
  if not role then
    return nil
  end

  local state = require('sqmeow.core.state')
  local result = require('sqmeow.ui.result')
  local edit = require('sqmeow.ui.edit')
  local call = state.call

  local conn = nil
  if role == 'result' and call then
    if call.conn_id and state.connections[call.conn_id] then
      conn = state.connections[call.conn_id]
    elseif call.connection and call.connection ~= '' then
      conn = state.connection_by_name(call.connection)
        or { name = call.connection, dialect = call.dialect }
    end
  end
  if not conn then
    conn = require('sqmeow.api.connection').target(buf)
  end
  if not conn and vim.b[buf].sqmeow_connection then
    local pinned = vim.b[buf].sqmeow_connection
    conn = state.connection_by_name(pinned) or { name = pinned }
  end
  if not conn then
    conn = state.current_connection()
  end

  local info = {
    connection = conn and conn.name or nil,
    dialect = conn and conn.dialect or nil,
    database = conn and (conn.current_database or conn.database) or nil,
    read_only = (conn and conn.read_only == true) or false,
    role = role,
    staged_changes = edit.count(),
    filtered = false,
  }

  if role == 'result' then
    info.column = result.current_column(call)
  end

  if call then
    local call_conn = call.conn_id and state.connections[call.conn_id]
    local call_name = (call_conn and call_conn.name) or call.connection
    local matches_conn = role == 'result'
      or not info.connection
      or not call_name
      or call_name == info.connection

    if matches_conn then
      info.state = call.state
      info.rows = call.rows
      info.view_rows = call.view_rows
      info.affected = call.affected
      info.truncated = call.truncated == true
      info.elapsed_ms = call.elapsed_ms
      if call.elapsed_ms ~= nil then
        info.elapsed = result.format_duration(call.elapsed_ms)
      end
      if call.columns and #call.columns > 0 then
        local page, total = result.pages(call)
        info.page = page
        info.total_pages = total
      end
      info.filtered = is_filtered(result.spec(), call)
    end
  end

  return info
end

--- Formatted active column and SQL type when focused in the result grid, or `''`.
---@return string
function M.column()
  local buf = vim.api.nvim_get_current_buf()
  if detect_role(buf) ~= 'result' then
    return ''
  end
  local col = require('sqmeow.ui.result').current_column()
  if not (col and col.name and col.name ~= '') then
    return ''
  end
  local icon = require('sqmeow.core.icons').get('column')
  local prefix = (icon and icon ~= '') and (icon .. ' ') or '󰠵 '
  if col.type_name and col.type_name ~= '' then
    return ('%s%s (%s)'):format(prefix, col.name, col.type_name:lower())
  end
  return prefix .. col.name
end

--- Formatted connection and query telemetry string for statuslines, or `''`.
---@param bufnr integer|nil Buffer handle; defaults to the current buffer.
---@return string
function M.component(bufnr)
  local info = M.status(bufnr)
  if not info then
    return ''
  end

  local icon = require('sqmeow.core.icons').get('connection')
  local prefix = (icon and icon ~= '') and (icon .. ' ') or '󰆼 '
  local base = info.connection or (info.role == 'query' and 'sql' or info.role)
  local display = prefix .. base
  if info.read_only then
    display = display .. ' 󰌾'
  end

  if info.state == 'executing' then
    return display .. ' ·  running…'
  end
  if info.state == 'error' then
    return display .. ' ·  error'
  end
  if info.state == 'cancelled' then
    return display .. ' · cancelled'
  end
  if info.state ~= 'done' then
    if info.staged_changes > 0 then
      return display .. ' · ●'
    end
    return display
  end

  local parts = {}
  local plus = info.truncated and '+' or ''
  if info.view_rows ~= nil then
    table.insert(parts, ('%d/%d%s rows'):format(info.view_rows, info.rows or 0, plus))
  elseif info.rows ~= nil and (info.rows > 0 or info.total_pages ~= nil) then
    local plural = (info.rows == 1 and not info.truncated) and '' or 's'
    table.insert(parts, ('%d%s row%s'):format(info.rows, plus, plural))
  elseif info.affected ~= nil then
    table.insert(parts, ('%d affected'):format(info.affected))
  else
    table.insert(parts, '0 rows')
  end

  if info.elapsed then
    table.insert(parts, info.elapsed)
  end
  if info.total_pages and info.total_pages > 1 then
    table.insert(parts, ('p%d/%d'):format(info.page or 1, info.total_pages))
  end
  if info.filtered then
    table.insert(parts, '󰈲')
  end
  if info.staged_changes > 0 then
    table.insert(parts, '●')
  end

  if #parts > 0 then
    return display .. ' · ' .. table.concat(parts, ' · ')
  end
  return display
end

return M
