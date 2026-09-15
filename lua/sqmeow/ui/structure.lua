--- A table's columns and indexes, in a popup.

local M = {}

local utils = require('sqmeow.utils')

local popup = nil
--- The table asked for last, so an answer for an earlier one is dropped.
local wanted = nil

--- Lay rows out in aligned columns, each cell its text and highlight group.
---@param rows table[][]
---@return NuiLine[]
local function aligned(rows)
  local Line = require('nui.line')
  local widths = {}
  for _, row in ipairs(rows) do
    for index, cell in ipairs(row) do
      widths[index] = math.max(widths[index] or 0, vim.api.nvim_strwidth(cell[1]))
    end
  end

  return vim.tbl_map(function(row)
    -- Empty cells at the end would only leave trailing spaces.
    while #row > 0 and row[#row][1] == '' do
      table.remove(row)
    end
    local line = Line()
    line:append('  ')
    for index, cell in ipairs(row) do
      line:append(cell[1], cell[2])
      if index < #row then
        line:append((' '):rep(widths[index] - vim.api.nvim_strwidth(cell[1]) + 2))
      end
    end
    return line
  end, rows)
end

--- The lines a table's structure reads as.
---@param payload table As `structure:done` sends it.
---@return NuiLine[]
function M.lines(payload)
  local Line = require('nui.line')
  local lines = {}
  local function heading(text)
    local line = Line()
    line:append(text, 'SqmeowHeader')
    table.insert(lines, line)
  end

  heading('Columns')
  local rows = {}
  for _, column in ipairs(payload.columns or {}) do
    local notes = {}
    if column.primary_key then
      table.insert(notes, 'primary key')
    end
    if column.references then
      table.insert(notes, '→ ' .. column.references)
    end
    table.insert(rows, {
      { column.name, 'SqmeowDetailName' },
      { column.type_name or '', 'SqmeowDetailType' },
      { column.nullable and 'null' or 'not null' },
      { column.default and ('default ' .. column.default) or '' },
      { table.concat(notes, ', ') },
    })
  end
  vim.list_extend(lines, aligned(rows))

  if #(payload.indexes or {}) > 0 then
    table.insert(lines, Line())
    heading('Indexes')
    rows = {}
    for _, index in ipairs(payload.indexes) do
      table.insert(rows, {
        { index.name, 'SqmeowDetailName' },
        { '(' .. table.concat(index.columns, ', ') .. ')' },
        { index.primary and 'primary key' or index.unique and 'unique' or '' },
      })
    end
    vim.list_extend(lines, aligned(rows))
  end
  return lines
end

--- Ask the engine for a table's structure, which opens when it answers.
---@param conn_id integer
---@param schema string
---@param relation string
function M.open(conn_id, schema, relation)
  wanted = { conn_id = conn_id, schema = schema, relation = relation }
  local _, err = require('sqmeow.rpc').request('structure', wanted)
  if err then
    wanted = nil
    utils.notify(err, vim.log.levels.ERROR)
  end
end

--- Show the structure the engine sent, if it is the one asked for last.
---@param payload table
function M.on_done(payload)
  if
    not (
      wanted
      and payload.conn_id == wanted.conn_id
      and payload.schema == wanted.schema
      and payload.relation == wanted.relation
    )
  then
    return
  end
  wanted = nil
  if payload.error then
    return utils.notify(payload.error, vim.log.levels.ERROR)
  end

  local nui, err = utils.nui({ 'popup' }, 'the structure view')
  if not nui then
    return utils.notify(err, vim.log.levels.ERROR)
  end

  local lines = M.lines(payload)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, line:width())
  end

  M.close()
  popup = nui.Popup({
    enter = true,
    focusable = true,
    relative = 'editor',
    position = '50%',
    size = {
      width = math.min(math.max(width + 2, 40), math.floor(vim.o.columns * 0.9)),
      height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.8)), 1),
    },
    zindex = 50,
    border = {
      style = require('sqmeow.config').border(),
      text = {
        top = (' %s '):format(
          payload.schema == '' and payload.relation or (payload.schema .. '.' .. payload.relation)
        ),
        top_align = 'center',
      },
    },
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'wipe',
      swapfile = false,
      filetype = 'sqmeow-structure',
    },
    win_options = { cursorline = true, wrap = false, number = false, relativenumber = false },
  })
  popup:mount()
  popup:map('n', 'q', M.close, { nowait = true })
  popup:map('n', '<Esc>', M.close, { nowait = true })
  popup:on('BufLeave', M.close, { once = true })

  local namespace = vim.api.nvim_create_namespace('sqmeow.structure')
  vim.api.nvim_buf_set_lines(
    popup.bufnr,
    0,
    -1,
    false,
    vim.tbl_map(function(line)
      return line:content()
    end, lines)
  )
  for index, line in ipairs(lines) do
    line:highlight(popup.bufnr, namespace, index)
  end
  vim.bo[popup.bufnr].modifiable = false
end

--- Close the popup.
function M.close()
  -- Forgotten before unmounting, since unmounting fires the `BufLeave` that calls this again.
  local closing = popup
  popup = nil
  if closing then
    closing:unmount()
  end
end

return M
