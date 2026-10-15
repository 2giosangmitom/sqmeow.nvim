--- Relation metadata or a routine's complete definition, in a read-only popup.

local M = {}

local utils = require('sqmeow.core.utils')

local popup = nil
--- The table asked for last, so an answer for an earlier one is dropped.
local wanted = nil
local shown_conn_id = nil

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

--- Display metadata rows or native source without binding executable editor keys.
local function show(payload, lines, filetype)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, type(line) == 'string' and vim.api.nvim_strwidth(line) or line:width())
  end

  M.close()
  local name = payload.name or payload.relation
  local qualified = payload.schema == '' and name or (payload.schema .. '.' .. name)
  local title = (' %s%s '):format(payload.kind and (payload.kind .. ' ') or '', qualified)
  local opened, open_err = require('sqmeow.ui.popup').open({
    title = title,
    lines = lines,
    width = math.min(math.max(width + 2, 40), math.floor(vim.o.columns * 0.9)),
    height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.8)), 1),
    filetype = filetype,
    on_close = M.close,
  })
  if not opened then
    return utils.notify(open_err or 'could not open the popup', vim.log.levels.ERROR)
  end
  popup = opened
  shown_conn_id = payload.conn_id
end

--- The lines a relation's structure reads as.
---@param payload table As `structure:done` sends it.
---@return NuiLine[]
function M.lines(payload)
  local Line = require('nui.line')
  local lines = {}
  local function section(title, rows)
    if #rows == 0 then
      return
    end
    if #lines > 0 then
      table.insert(lines, Line())
    end
    local line = Line()
    line:append(title, 'SqmeowHeader')
    table.insert(lines, line)
    vim.list_extend(lines, aligned(rows))
  end

  local rows = {}
  for _, property in ipairs(payload.properties or {}) do
    table.insert(rows, { { property[1], 'SqmeowDetailName' }, { property[2] } })
  end
  section('About', rows)

  local comments = {}
  for _, comment in ipairs(payload.comments or {}) do
    comments[comment[1]] = comment[2]
  end
  rows = {}
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
      { comments[column.name] and ('-- ' .. comments[column.name]) or '', 'Comment' },
    })
  end
  section('Columns', rows)

  rows = {}
  for _, index in ipairs(payload.indexes or {}) do
    table.insert(rows, {
      { index.name, 'SqmeowDetailName' },
      { '(' .. table.concat(index.columns, ', ') .. ')' },
      { index.primary and 'primary key' or index.unique and 'unique' or '' },
    })
  end
  section('Indexes', rows)

  rows = {}
  for _, key in ipairs(payload.foreign_keys or {}) do
    table.insert(rows, {
      { key.name ~= '' and key.name or '(unnamed)', 'SqmeowDetailName' },
      { '(' .. table.concat(key.columns, ', ') .. ')' },
      { ('→ %s (%s)'):format(key.target, table.concat(key.referenced, ', ')) },
    })
  end
  section('Foreign keys', rows)

  for _, group in ipairs({ { 'Checks', payload.checks }, { 'Triggers', payload.triggers } }) do
    rows = {}
    for _, entry in ipairs(group[2] or {}) do
      table.insert(rows, { { entry[1], 'SqmeowDetailName' }, { entry[2] } })
    end
    section(group[1], rows)
  end

  if payload.definition then
    rows = {}
    for _, text in ipairs(vim.split(payload.definition, '\n', { plain = true })) do
      table.insert(rows, { { text } })
    end
    section('Definition', rows)
  end
  return lines
end

--- Ask the engine for a table's structure, which opens when it answers.
---@param conn_id integer
---@param schema string
---@param relation string
function M.open(conn_id, schema, relation)
  wanted = { conn_id = conn_id, schema = schema, relation = relation }
  local _, err = require('sqmeow.rpc.client').request('structure', wanted)
  if err then
    wanted = nil
    utils.notify(err, vim.log.levels.ERROR)
  end
end

--- Fetch a function/procedure's signature and body for read-only inspection.
---@param conn_id integer
---@param schema string
---@param name string
---@param kind string
function M.open_routine(conn_id, schema, name, kind)
  M.close()
  require('sqmeow.rpc.events').ensure()
  local rpc = require('sqmeow.rpc.client')
  wanted = {
    conn_id = conn_id,
    schema = schema,
    name = name,
    kind = kind,
    request_id = rpc.next_request_id(),
  }
  local _, err = rpc.request('routine_source', wanted)
  if err then
    wanted = nil
    utils.notify(err, vim.log.levels.ERROR)
  end
end

--- Accept only the last routine inspection, not replies meant for an editor.
---@param payload table
function M.on_routine(payload)
  if
    not (
      wanted
      and wanted.kind
      and payload.request_id == wanted.request_id
      and payload.conn_id == wanted.conn_id
      and payload.schema == wanted.schema
      and payload.name == wanted.name
      and payload.kind == wanted.kind
    )
  then
    return
  end
  wanted = nil
  local connection = require('sqmeow.core.state').connections[payload.conn_id]
  if not connection then
    return
  end
  if payload.error then
    return utils.notify(payload.error, vim.log.levels.ERROR)
  end
  if type(payload.source) ~= 'string' or vim.trim(payload.source) == '' then
    return utils.notify('the routine has no visible source definition', vim.log.levels.ERROR)
  end
  show(
    payload,
    vim.split(payload.source, '\n', { plain = true }),
    connection.dialect == 'surrealdb' and 'surql' or 'sql'
  )
end

--- Show the structure the engine sent, if it is the one asked for last.
---@param payload table
function M.on_done(payload)
  if
    not (
      wanted
      and not wanted.kind
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

  show(payload, M.lines(payload), 'sqmeow-structure')
end

--- Discard pending inspection and visible metadata for a removed connection.
---@param conn_id integer
function M.invalidate(conn_id)
  if (wanted and wanted.conn_id == conn_id) or shown_conn_id == conn_id then
    M.close()
  end
end

--- Close the popup.
function M.close()
  -- Forgotten before unmounting, since unmounting fires the `BufLeave` that calls this again.
  local closing = popup
  popup = nil
  wanted = nil
  shown_conn_id = nil
  if closing then
    closing:unmount()
  end
end

return M
