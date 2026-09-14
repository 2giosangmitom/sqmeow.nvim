--- Changes staged against the result on screen, and the windows that make and approve them.
---
--- Nothing is written as it is made. Cells, new rows and deletions collect here, keyed by the row's
--- index in the result, until a review shows the statements the engine planned for them and `<C-s>`
--- runs those statements together. Rows are identified by index rather than by value because the
--- engine holds the original values, keys included, and finds each row again from those.

local M = {}

local utils = require('sqmeow.utils')

--- `updates[row][column]` is the new value: a string, or `vim.NIL` for `NULL`. Zero-based indices.
local updates = {}
--- `deletes[row]` is true for a row to delete.
local deletes = {}
--- New rows, each `[column] = value`.
local inserts = {}
--- What undoes each change, most recent last.
local history = {}

--- The float being typed in, or the review, whichever is open.
local popup = nil

--- The deepest the undo history goes, past which the oldest change can no longer be undone.
local HISTORY_LIMIT = 200

local function close()
  local closing = popup
  popup = nil
  if closing then
    closing:unmount()
  end
end

local function remember(undo)
  table.insert(history, undo)
  if #history > HISTORY_LIMIT then
    table.remove(history, 1)
  end
end

local function redraw()
  require('sqmeow.ui.result').redraw()
end

--- How many changes are staged: each changed cell, deleted row and new row.
---@return integer
function M.count()
  local total = #inserts
  for _, cells in pairs(updates) do
    total = total + vim.tbl_count(cells)
  end
  return total + vim.tbl_count(deletes)
end

--- Forget every staged change.
---@return integer dropped How many there were.
function M.reset()
  local dropped = M.count()
  updates, deletes, inserts, history = {}, {}, {}, {}
  close()
  return dropped
end

--- The staged value of a cell, if it has one.
---
---@param row integer Zero-based row of the result.
---@param column integer Zero-based column.
---@return any value A string, or `vim.NIL`.
---@return boolean staged
function M.staged(row, column)
  local cells = updates[row]
  if cells and cells[column] ~= nil then
    return cells[column], true
  end
  return nil, false
end

--- Whether a row is staged for deletion.
---@param row integer
---@return boolean
function M.deleted(row)
  return deletes[row] == true
end

--- The rows staged to be added, each `[column] = value` with zero-based columns.
---@return table[]
function M.inserts()
  return inserts
end

--- Stage a new value for a cell of a row the result holds, or of a new row.
---
---@param target { row: integer|nil, insert: integer|nil } Which row: `row` in the result, or the
--- `insert`th new one.
---@param column integer Zero-based.
---@param value any A string, or `vim.NIL` for `NULL`.
function M.set(target, column, value)
  local cells
  if target.insert then
    cells = inserts[target.insert]
  else
    updates[target.row] = updates[target.row] or {}
    cells = updates[target.row]
  end
  if not cells then
    return
  end

  local previous = cells[column]
  cells[column] = value
  remember(function()
    cells[column] = previous
    if target.row and vim.tbl_isempty(cells) then
      updates[target.row] = nil
    end
  end)
  redraw()
end

--- Stage a new, empty row.
function M.add_row()
  table.insert(inserts, {})
  local added = #inserts
  remember(function()
    table.remove(inserts, added)
  end)
  redraw()
end

--- Stage rows for deletion, or take them back out when every one of them already was.
---
--- A new row is simply dropped: there is nothing in the database to delete.
---
---@param targets { row: integer|nil, insert: integer|nil }[]
function M.toggle_delete(targets)
  local rows, added = {}, {}
  for _, target in ipairs(targets) do
    if target.insert then
      table.insert(added, target.insert)
    elseif target.row then
      table.insert(rows, target.row)
    end
  end

  local keep = #rows > 0 and vim.iter(rows):all(function(row)
    return deletes[row]
  end)
  local before = {}
  for _, row in ipairs(rows) do
    before[row] = deletes[row]
    deletes[row] = (not keep) or nil
  end

  -- Highest first, so removing one does not move the next.
  table.sort(added, function(a, b)
    return a > b
  end)
  local removed = {}
  for _, index in ipairs(added) do
    table.insert(removed, { index = index, row = table.remove(inserts, index) })
  end

  remember(function()
    for row, was in pairs(before) do
      deletes[row] = was
    end
    for position = #removed, 1, -1 do
      table.insert(inserts, removed[position].index, removed[position].row)
    end
  end)
  redraw()
end

--- Undo the most recent change.
---@return boolean undone
function M.undo()
  local undo = table.remove(history)
  if not undo then
    return false
  end
  undo()
  redraw()
  return true
end

--- The staged changes, shaped the way the engine's `plan` reads them.
---@return table
function M.changes()
  local function cells(values)
    local list = {}
    for column, value in pairs(values) do
      -- A `NULL` is sent as no value at all, which the engine reads as `NULL`.
      table.insert(list, { column = column, value = value ~= vim.NIL and value or nil })
    end
    table.sort(list, function(a, b)
      return a.column < b.column
    end)
    return list
  end

  local planned = { updates = {}, deletes = {}, inserts = {} }
  for row, values in pairs(updates) do
    table.insert(planned.updates, { row = row, cells = cells(values) })
  end
  table.sort(planned.updates, function(a, b)
    return a.row < b.row
  end)
  for row in pairs(deletes) do
    table.insert(planned.deletes, row)
  end
  table.sort(planned.deletes)
  for _, values in ipairs(inserts) do
    table.insert(planned.inserts, cells(values))
  end
  return planned
end

-- -- windows ---------------------------------------------------------------------------------

--- What a cell holds now: its staged value, or what the result holds for it.
---
---@param call table
---@param target { row: integer|nil, insert: integer|nil }
---@param column integer
---@return string|nil text Nil for `NULL`.
local function current_text(call, target, column)
  local value, staged
  if target.insert then
    value = (inserts[target.insert] or {})[column]
    staged = value ~= nil
  else
    value, staged = M.staged(target.row, column)
  end
  if staged then
    return value ~= vim.NIL and value or nil
  end
  if target.insert then
    return ''
  end

  -- The full value, line breaks and all, rather than the flattened one the grid holds.
  local row = require('sqmeow.rpc').request('row', { call_id = call.call_id, row = target.row })
  local cell = row and row[column + 1]
  if not cell or cell.is_null then
    return nil
  end
  return cell.value
end

--- How big the cell editor has to be to show every line whole: as wide as the longest line, up to
--- most of the editor, and as tall as the rows those lines take once wrapped at that width, up to
--- half of it.
---
---@param lines string[]
---@return { width: integer, height: integer }
local function editor_size(lines)
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line) + 2)
  end
  width = math.min(width, math.max(math.floor(vim.o.columns * 0.8), 1))

  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(math.ceil(vim.api.nvim_strwidth(line) / width), 1)
  end
  return {
    width = width,
    height = math.min(math.max(rows, 1), math.max(math.floor(vim.o.lines * 0.5), 1)),
  }
end

--- Open a float to change one cell.
---
--- An ordinary buffer, so every motion works and a value with line breaks keeps them. It opens in
--- insert mode after the value, since changing it is what it was opened for. `<C-s>` in either
--- mode, or `<CR>` in normal mode, stages what the buffer holds; `q` leaves it as it was.
---
---@param target { row: integer|nil, insert: integer|nil, column: integer, name: string }
function M.edit_cell(target)
  local call = require('sqmeow.state').call
  local described = call and call.columns and call.columns[target.column + 1]
  if not (described and described.editable) then
    return utils.notify(('`%s` cannot be edited'):format(target.name), vim.log.levels.WARN)
  end

  local nui, err = utils.nui({ 'popup' }, 'the cell editor')
  if not nui then
    return utils.notify(err, vim.log.levels.ERROR)
  end

  local text = current_text(call, target, target.column)
  local lines = vim.split(text or '', '\n', { plain = true })

  close()
  popup = nui.Popup({
    enter = true,
    focusable = true,
    relative = 'cursor',
    position = { row = 1, col = 0 },
    size = editor_size(lines),
    zindex = 60,
    border = {
      style = require('sqmeow.config').border(),
      text = {
        top = (' %s%s '):format(target.name, text == nil and ' (NULL)' or ''),
        bottom = ' <C-s> save   <Esc> then q cancel ',
        bottom_align = 'center',
      },
    },
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'wipe',
      swapfile = false,
      filetype = described.class == 'json' and 'json' or '',
    },
    win_options = { wrap = true, number = false, relativenumber = false },
  })
  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(popup.winid, { #lines, #lines[#lines] })
  vim.cmd.startinsert({ bang = true })

  local bufnr = popup.bufnr
  local function save()
    local value = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    vim.cmd.stopinsert()
    close()
    M.set(target, target.column, value)
  end

  popup:map('n', '<CR>', save, { nowait = true })
  -- One mode per call: nui passes the mode straight to `nvim_buf_set_keymap`, which takes one.
  popup:map('n', '<C-s>', save, { nowait = true })
  popup:map('i', '<C-s>', save, { nowait = true })
  popup:map('n', 'q', close, { nowait = true })
  popup:map('n', '<Esc>', close, { nowait = true })
  popup:on('BufLeave', close, { once = true })

  -- Grown and shrunk with what is typed, so a line break or a long line never hides the rest of
  -- the value behind the one line the window started with. Size alone, so it stays where it is.
  local editor = popup
  popup:on({ 'TextChanged', 'TextChangedI' }, function()
    if popup ~= editor or not vim.api.nvim_win_is_valid(editor.winid) then
      return
    end
    local size = editor_size(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    editor:update_layout({ size = size })
    -- A window that was too short scrolled to follow the cursor, and one that now fits it all
    -- should show it from the top.
    vim.api.nvim_win_call(editor.winid, function()
      if vim.fn.line('$') <= size.height then
        vim.fn.winrestview({ topline = 1 })
      end
    end)
  end)
end

--- The filetype planned statements are shown with.
local function filetype(call)
  local connection = require('sqmeow.state').connections[call.conn_id]
  local dialect = connection and connection.dialect
  if dialect == 'mongodb' then
    return 'json'
  end
  return dialect ~= 'redis' and 'sql' or ''
end

--- Ask the engine to run approved statements.
---
---@param conn_id integer
---@param statements string[]
function M.apply(conn_id, statements)
  local _, err =
    require('sqmeow.rpc').request('apply', { conn_id = conn_id, statements = statements })
  if err then
    utils.notify(err, vim.log.levels.ERROR)
  end
end

--- What happened to applied statements. On success the staged changes are gone from the database
--- side too, so they are dropped here and the result's query runs again to show what is there now.
--- On failure they stay, to be fixed and tried again.
---
---@param payload { conn_id: integer, statements: integer, error: string|nil }
function M.on_applied(payload)
  if payload.error then
    return utils.notify('nothing was applied: ' .. payload.error, vim.log.levels.ERROR)
  end

  M.reset()
  utils.notify(
    ('applied %d statement%s'):format(payload.statements, payload.statements == 1 and '' or 's')
  )

  local call = require('sqmeow.state').call
  if call and call.conn_id == payload.conn_id and call.sql then
    require('sqmeow.ui.result').carry_view()
    require('sqmeow.api').execute(call.sql, { conn_id = call.conn_id, history = false })
  end
end

--- Show the statements the staged changes plan into, and apply them on `<C-s>`.
---
--- The review is the only way to apply: what runs is exactly what is on screen.
function M.review()
  local call = require('sqmeow.state').call
  if M.count() == 0 then
    return utils.notify('there are no changes to review')
  end
  if not (call and call.call_id) then
    return
  end

  local statements, err =
    require('sqmeow.rpc').request('plan', { call_id = call.call_id, changes = M.changes() })
  if not statements then
    return utils.notify(err or 'the changes could not be planned', vim.log.levels.ERROR)
  end

  local nui, nui_err = utils.nui({ 'popup' }, 'the review')
  if not nui then
    return utils.notify(nui_err, vim.log.levels.ERROR)
  end

  local lines = {}
  for _, statement in ipairs(statements) do
    vim.list_extend(lines, vim.split(statement .. (filetype(call) == 'sql' and ';' or ''), '\n'))
  end

  close()
  popup = nui.Popup({
    enter = true,
    focusable = true,
    relative = 'editor',
    position = '50%',
    size = {
      width = math.floor(vim.o.columns * 0.7),
      height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.6)), 1),
    },
    zindex = 60,
    border = {
      style = require('sqmeow.config').border(),
      text = {
        top = (' Review %d change%s '):format(M.count(), M.count() == 1 and '' or 's'),
        top_align = 'center',
        bottom = ' <C-s> apply   q back ',
        bottom_align = 'center',
      },
    },
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'wipe',
      swapfile = false,
      filetype = filetype(call),
    },
    win_options = { wrap = false, number = false, relativenumber = false },
  })
  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.bo[popup.bufnr].modifiable = false

  popup:map('n', '<C-s>', function()
    close()
    M.apply(call.conn_id, statements)
  end, { nowait = true })
  popup:map('n', 'q', close, { nowait = true })
  popup:map('n', '<Esc>', close, { nowait = true })
  popup:on('BufLeave', close, { once = true })
end

return M
