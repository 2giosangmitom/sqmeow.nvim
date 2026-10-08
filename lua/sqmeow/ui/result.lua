--- The result grid.

local M = {}

local utils = require('sqmeow.core.utils')
local Table = require('sqmeow.ui.table')

local buf = nil
local win = nil
--- The float the grid is in, when it is not in its split.
local popup = nil
--- The sticky header float and buffer when scrolling down.
local sticky_buf = nil
local sticky_win = nil

--- The rows on screen, their offset in the view, and their result indices.
local page = { offset = 0, rows = {}, indices = {} }

--- Content widths seen on loaded pages of the current result, excluding NULL labels.
local content_widths = {}

--- How each result is shown, by call id.
local specs = {}
--- Previous free-form views awaiting asynchronous Polars validation, by call id.
local pending_views = {}
local view_summaries = {}
--- Page/cursor bookmarks awaiting local filtering after a refresh.
local resuming_views = {}

--- The call the grid was last drawn for, which tells a new result from the same one redrawn.
local drawn = nil
--- A view to put on the next result, and the call it is waiting for.
local carried, pending = nil, nil
--- Where the page and cursor were, for the next result to open at.
local resume = nil

--- How many lines the grid opens with before the first row: the column names, and the rule.
local HEADER_LINES = 2

--- Where the grid puts its highlights.
local NAMESPACE = vim.api.nvim_create_namespace('sqmeow')

--- The table grid, lazily created on the first draw.
local tbl = nil

--- Whether the last draw rendered a table grid with column headers.
local has_grid = false

--- Close and wipe the sticky header window and buffer.
local function close_sticky()
  if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
    pcall(vim.api.nvim_win_close, sticky_win, true)
  end
  sticky_win = nil
  if sticky_buf and vim.api.nvim_buf_is_valid(sticky_buf) then
    pcall(vim.api.nvim_buf_delete, sticky_buf, { force = true })
  end
  sticky_buf = nil
end

--- Update or create the sticky header float when scrolling down past the first 2 rows.
local function update_sticky()
  local config = require('sqmeow.config').get()
  if not (config.ui and config.ui.result and config.ui.result.sticky_header) then
    close_sticky()
    return
  end

  if not (has_grid and win and utils.shows(win, buf)) then
    close_sticky()
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count < 3 then
    if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
      pcall(vim.api.nvim_win_close, sticky_win, true)
      sticky_win = nil
    end
    return
  end

  local w0 = vim.api.nvim_win_call(win, function()
    return vim.fn.line('w0')
  end)

  if w0 > 2 then
    if not sticky_buf or not vim.api.nvim_buf_is_valid(sticky_buf) then
      sticky_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[sticky_buf].buftype = 'nofile'
      vim.bo[sticky_buf].bufhidden = 'hide'
      vim.bo[sticky_buf].swapfile = false
    end

    local header_lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
    if #header_lines == 2 then
      vim.bo[sticky_buf].modifiable = true
      vim.api.nvim_buf_set_lines(sticky_buf, 0, -1, false, header_lines)
      vim.bo[sticky_buf].modifiable = false

      -- Transfer extmarks / highlights from original header rows
      local hns = vim.api.nvim_create_namespace('sqmeow_sticky')
      vim.api.nvim_buf_clear_namespace(sticky_buf, hns, 0, -1)
      local marks = vim.api.nvim_buf_get_extmarks(
        buf,
        NAMESPACE,
        { 0, 0 },
        { 1, -1 },
        { details = true }
      )
      for _, m in ipairs(marks) do
        local row, col, details = m[2], m[3], m[4]
        if details and details.hl_group then
          pcall(vim.api.nvim_buf_set_extmark, sticky_buf, hns, row, col, {
            end_col = details.end_col,
            hl_group = details.hl_group,
            priority = details.priority,
          })
        end
      end

      local win_w = vim.api.nvim_win_get_width(win)
      local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)

      if not sticky_win or not vim.api.nvim_win_is_valid(sticky_win) then
        sticky_win = vim.api.nvim_open_win(sticky_buf, false, {
          relative = 'win',
          win = win,
          row = 0,
          col = 0,
          width = win_w,
          height = 2,
          focusable = false,
          style = 'minimal',
          zindex = 45,
        })
        if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
          vim.wo[sticky_win].wrap = false
          vim.wo[sticky_win].spell = false
        end
      else
        vim.api.nvim_win_set_config(sticky_win, {
          win = win,
          width = win_w,
          height = 2,
        })
      end

      -- Synchronize horizontal scrolling 1:1 with parent window
      if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
        vim.api.nvim_win_call(sticky_win, function()
          vim.fn.winrestview({ leftcol = view.leftcol, topline = 1 })
        end)
      end
    end
  else
    if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
      pcall(vim.api.nvim_win_close, sticky_win, true)
      sticky_win = nil
    end
  end
end

--- How many rows fit in one page.
---@return integer
local function page_size()
  return math.max(require('sqmeow.config').get().ui.result.page_size, 1)
end

--- A view that shows everything as the query returned it.
local function fresh()
  return {
    filters = {},
    sort = {},
    hidden = {},
    where = '',
    order_by = '',
    group_by = '',
    aggregates = '',
    having = '',
  }
end

--- How the current result is shown. `where` and `order_by` are run in its query, which `base`
--- holds as written once it has been filtered.
---@return { filters: table[], sort: table[], hidden: table<integer, boolean>, where: string, order_by: string, base: string|nil }
function M.spec()
  local call = require('sqmeow.core.state').call
  local id = call and call.call_id
  if not id then
    return fresh()
  end
  specs[id] = specs[id] or fresh()
  return specs[id]
end

--- Forget everything kept by call id, for an engine that numbers its calls from one again.
function M.forget()
  specs, drawn, carried, pending, resume = {}, nil, nil, nil, nil
  pending_views = {}
  view_summaries = {}
  has_grid = false
  close_sticky()
end

--- Round a duration for display, keeping it short without lying about the magnitude.
---@param ms integer
---@return string
function M.format_duration(ms)
  if ms < 1000 then
    return ('%dms'):format(ms)
  end
  return ('%.2fs'):format(ms / 1000)
end

--- How many pages a result has, and which one is showing.
---@param summary sqmeow.CallSummary|nil
---@return integer page
---@return integer pages
function M.pages(summary)
  local rows = summary and (summary.view_rows or summary.rows) or 0
  local size = page_size()
  local pages = math.max(math.ceil(rows / size), 1)
  return math.min(math.floor(page.offset / size) + 1, pages), pages
end

--- Describe a result for the winbar.
---@param summary sqmeow.CallSummary|nil
---@return string
---@param highlight boolean|nil Colour the icons with winbar markup, for drawing in a winbar.
function M.describe(summary, highlight)
  if not summary then
    return 'sqmeow'
  end

  if summary.state == 'executing' then
    return 'running…'
  end

  -- Which statement's result this is, when several returned rows.
  local position
  for index, entry in ipairs(summary.results or {}) do
    if entry.call_id == summary.call_id then
      position = ('result %d/%d'):format(index, #summary.results)
    end
  end
  if summary.state == 'error' then
    return (position and position .. '  ' or '') .. 'error: ' .. (summary.error or 'unknown')
  end
  if summary.state == 'cancelled' then
    return 'cancelled'
  end

  local parts = { position }
  if summary.aggregate_pending then
    table.insert(parts, 'aggregating…')
  end

  if summary.rows and summary.rows > 0 then
    table.insert(parts, ('%d row%s'):format(summary.rows, summary.rows == 1 and '' or 's'))
  elseif summary.affected then
    table.insert(
      parts,
      ('%d row%s affected'):format(summary.affected, summary.affected == 1 and '' or 's')
    )
  else
    table.insert(parts, 'no rows')
  end

  if summary.truncated then
    table.insert(parts, 'truncated')
  end
  if summary.aggregated then
    table.insert(
      parts,
      ('aggregate · read-only · %d source rows'):format(summary.source_rows or 0)
    )
  end
  if summary.view_rows then
    table.insert(parts, ('%d shown'):format(summary.view_rows))
  end

  local spec = summary.call_id and specs[summary.call_id]
  if spec then
    local function clause(label, text)
      if vim.fn.strchars(text) > 40 then
        text = vim.fn.strcharpart(text, 0, 39) .. '…'
      end
      -- A winbar reads `%` as the start of an item.
      table.insert(parts, label .. (highlight and text:gsub('%%', '%%%%') or text))
    end
    if (spec.where or '') ~= '' then
      clause('where ', spec.where)
    end
    if (spec.group_by or '') ~= '' then
      clause('group by ', spec.group_by)
    end
    if (spec.having or '') ~= '' then
      clause('having ', spec.having)
    end

    local keys = {}
    for _, key in ipairs(spec.sort) do
      local column = summary.columns and summary.columns[key.column + 1]
      table.insert(keys, (column and column.name or '?') .. (key.descending and '↓' or '↑'))
    end
    if (spec.order_by or '') ~= '' then
      clause('order by ', spec.order_by)
    elseif #keys > 0 then
      table.insert(parts, 'sorted by ' .. table.concat(keys, ', '))
    end
    local hidden = vim.tbl_count(spec.hidden)
    if hidden > 0 then
      table.insert(parts, ('%d hidden'):format(hidden))
    end
  end

  local changes = require('sqmeow.ui.edit').count()
  if summary.call_id and require('sqmeow.ui.edit').applying() == summary.call_id then
    table.insert(parts, 'applying…')
  elseif changes > 0 and summary.call_id == drawn then
    local text = ('%d change%s'):format(changes, changes == 1 and '' or 's')
    local review = require('sqmeow.keymap').lhs('result', 'review')
    if review then
      text = ('%s (%s review)'):format(text, highlight and review:gsub('%%', '%%%%') or review)
    end
    table.insert(parts, highlight and ('%%#SqmeowWinbarChanges#%s%%*'):format(text) or text)
  end

  local current, total = M.pages(summary)
  if total > 1 then
    table.insert(parts, ('page %d/%d'):format(current, total))
  end
  if summary.elapsed_ms then
    local elapsed = M.format_duration(summary.elapsed_ms)
    local icon, group = require('sqmeow.core.icons').get('elapsed')
    if icon ~= '' then
      icon = highlight and ('%%#%s#%s%%*'):format(group, icon) or icon
      elapsed = icon .. ' ' .. elapsed
    end
    table.insert(parts, elapsed)
  end
  -- A result from the log is what the query returned then, and the table may say otherwise now.
  if summary.ran_at then
    table.insert(parts, 'ran ' .. require('sqmeow.ui.log').ago(summary.ran_at))
  end

  return table.concat(parts, '  ')
end

local function scratch(name, filetype)
  return require('sqmeow.ui.buffer').scratch(name, filetype, false)
end

--- The buffer the grid is drawn into.
---@return integer
function M.buffer()
  if buf and utils.buf_valid(buf) then
    return buf
  end
  buf = scratch('sqmeow://result', 'sqmeow-result')
  require('sqmeow.keymap').apply('result', buf, M.actions)

  local group = vim.api.nvim_create_augroup('sqmeow_result_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter' }, {
    group = group,
    buffer = buf,
    callback = function()
      M.update_winbar(require('sqmeow.core.state').call)
      update_sticky()
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'VimResized' }, {
    group = group,
    callback = function()
      if win and utils.shows(win, buf) then
        update_sticky()
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      if win and (tonumber(args.match) == win or args.match == tostring(win)) then
        close_sticky()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufHidden', 'BufDelete', 'BufUnload' }, {
    group = group,
    buffer = buf,
    callback = close_sticky,
  })

  return buf
end

-- -- drawing ---------------------------------------------------------------------------------

--- What a cell reads as in the grid.
---@param value any
---@param null_text string
---@return string text
---@return boolean is_null
local function cell_text(value, null_text)
  if value == nil or value == vim.NIL then
    return null_text, true
  end
  if type(value) == 'boolean' then
    return value and 'true' or 'false', false
  end
  if type(value) == 'table' and value.sql then
    value = '= ' .. value.sql
  end
  local text = tostring(value):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return text, false
end

--- The highlight a value's kind gives its text, if any.
---@param value any
---@param is_null boolean
---@param numeric boolean|nil
---@return string|nil
local function type_group(value, is_null, numeric)
  if is_null then
    return 'SqmeowNull'
  end
  if type(value) == 'table' and value.sql then
    return 'SqmeowExpression'
  end
  if numeric then
    return 'SqmeowNumber'
  end
end

--- The characters the grid is drawn with.
local function glyphs()
  return require('sqmeow.config').get().icons.grid
end

--- What each shown column of a result is drawn as.
---@param columns table[] As the engine described them.
---@param hidden table<integer, boolean> Zero-based columns left out.
---@return table[]
local function measure(columns, hidden)
  local config = require('sqmeow.config').get()
  local icons = require('sqmeow.core.icons')

  local cap = math.max(config.ui.result.max_column_width, 1)
  local null_text = config.ui.result.null_text

  local measured = {}
  for index, column in ipairs(columns) do
    if not hidden[index - 1] then
      -- The icon says what the column holds, or which key it is.
      local icon, icon_group
      if config.ui.result.column_icons then
        local glyph, group = icons.get(column.key or column.class or 'unknown')
        if glyph ~= ' ' then
          icon, icon_group = glyph, group
        end
      end

      local name = utils.truncate(column.name, cap, glyphs().ellipsis)
      local header = vim.api.nvim_strwidth(name)
      if icon then
        -- The icon is chrome rather than content.
        header = header + vim.api.nvim_strwidth(icon) + 1
      end

      -- Measure the same text we draw, using Neovim's Unicode width rules.
      -- Keep widths from earlier pages so navigating back never shrinks columns.
      local content = content_widths[index] or 0
      for _, row in ipairs(page.rows) do
        local text, is_null = cell_text(row[index], null_text)
        if not is_null then
          content = math.max(content, vim.api.nvim_strwidth(text))
        end
      end
      content_widths[index] = content
      if column.nulls then
        content = math.max(content, vim.api.nvim_strwidth(null_text))
      end

      table.insert(measured, {
        index = index,
        name = name,
        icon = icon,
        icon_group = icon_group,
        numeric = column.numeric == true,
        width = math.max(math.min(content, cap), header),
      })
    end
  end

  return measured
end

--- How a result that is a query plan reads as lines, or nil for any other result.
---@param call table
---@return string[]|nil
local function plan_lines(call)
  if not (call.sql and call.sql:match('^%s*[Ee][Xx][Pp][Ll][Aa][Ii][Nn]%s')) then
    return nil
  end
  local names = table.concat(
    vim.tbl_map(function(column)
      return column.name
    end, call.columns),
    ','
  )

  local lines = {}
  if names == 'id,parent,notused,detail' then
    local depth = {}
    for _, row in ipairs(page.rows) do
      depth[row[1]] = (depth[row[2]] or -1) + 1
      table.insert(lines, ('  '):rep(depth[row[1]]) .. tostring(row[4]))
    end
    return lines
  end
  -- DuckDB puts its whole plan in the second column of one row.
  if names == 'explain_key,explain_value' then
    local row = require('sqmeow.rpc.client').request('row', { call_id = call.call_id, row = 0 })
    if row and row[2] and not row[2].is_null then
      return vim.split(row[2].value, '\n', { plain = true })
    end
  end
  if #call.columns ~= 1 then
    return nil
  end

  -- A plan in one value, such as MySQL's `FORMAT=TREE`, spans lines the grid's rows flatten.
  if call.rows == 1 then
    local row = require('sqmeow.rpc.client').request('row', { call_id = call.call_id, row = 0 })
    if row and row[1] and not row[1].is_null then
      return vim.split(row[1].value, '\n', { plain = true })
    end
  end
  for _, row in ipairs(page.rows) do
    table.insert(lines, row[1] == vim.NIL and '' or tostring(row[1]))
  end
  return lines
end

--- Draw the rows this window is showing, with the changes staged against them.
local function draw()
  local call = require('sqmeow.core.state').call
  local edit = require('sqmeow.ui.edit')
  local handle = M.buffer()

  vim.bo[handle].modifiable = true
  vim.api.nvim_buf_clear_namespace(handle, NAMESPACE, 0, -1)

  -- A failed query's error is shown here, where its rows would have been, and nowhere else.
  if call and call.state == 'error' then
    has_grid = false
    local lines = vim.split(call.error or 'the query failed', '\n')
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, lines)
    for row, text in ipairs(lines) do
      vim.api.nvim_buf_set_extmark(handle, NAMESPACE, row - 1, 0, {
        end_col = #text,
        hl_group = 'SqmeowError',
      })
    end
    vim.bo[handle].modifiable = false
    return
  end

  if not (call and call.columns and #call.columns > 0) then
    has_grid = false
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, {})
    vim.bo[handle].modifiable = false
    return
  end

  local plan = plan_lines(call)
  if plan then
    has_grid = false
    vim.api.nvim_buf_set_lines(handle, 0, -1, false, plan)
    vim.bo[handle].modifiable = false
    return
  end

  local measured = measure(call.columns, M.spec().hidden)
  local null_text = require('sqmeow.config').get().ui.result.null_text
  -- Read-only columns are dimmed only where others can be edited.
  local editable = vim.iter(call.columns):any(function(column)
    return column.editable
  end)

  local marks = require('sqmeow.config').get().icons.edit
  --- A configured marker, or a blank one when it would not fit the grid's one-column gutter.
  local function marker(name)
    local text = marks[name] or ''
    return vim.api.nvim_strwidth(text) == 1 and text or ' '
  end

  --- The marker and line highlight of a row with staged changes.
  ---@param row sqmeow.Table.Row
  ---@return sqmeow.Table.RowMark|nil
  local function row_mark(row)
    if row.index > #page.rows then
      return { mark = marker('added'), mark_hl = 'SqmeowSignAdded', line_hl = 'SqmeowInserted' }
    end
    local absolute = page.indices[row.index]
    if not absolute then
      return nil
    end
    if edit.deleted(absolute) then
      return {
        mark = marker('deleted'),
        mark_hl = 'SqmeowSignDeleted',
        line_hl = 'SqmeowDeleted',
      }
    end
    if edit.changed(absolute) then
      return {
        mark = marker('changed'),
        mark_hl = 'SqmeowSignChanged',
        line_hl = 'SqmeowChangedRow',
      }
    end
  end

  --- Build column definitions for the table module.
  ---@return table[]
  local function build_columns()
    local columns = {}
    for _, column in ipairs(measured) do
      -- The header includes the type/key icon when configured.
      local header_content = {}
      if column.icon then
        table.insert(header_content, { column.icon, column.icon_group })
        table.insert(header_content, { ' ' })
      end
      local described = call.columns[column.index]
      table.insert(header_content, {
        column.name,
        (editable and not (described and described.editable)) and 'SqmeowReadOnly'
          or 'SqmeowHeader',
      })

      -- Each column index is captured by the closures below.
      local col_index = column.index
      table.insert(columns, {
        id = tostring(col_index),
        header = header_content,
        width = column.width,
        align = column.numeric and 'right' or 'left',
        accessor_fn = function(row)
          return row[col_index]
        end,
        --- The cell callback resolves the edit state: deleted rows, staged changes,
        --- inserted rows, nulls, and the type highlight.
        cell = function(info)
          local row_pos = info.row.index
          local raw = info.row.original

          if row_pos <= #page.rows then
            local absolute = page.indices[row_pos]
            local value = raw[col_index]
            local staged = false
            if absolute then
              local changed, has = edit.staged(absolute, col_index - 1)
              if has then
                value, staged = changed, true
              end
            end

            local text, is_null = cell_text(value, null_text)
            if absolute ~= nil and edit.deleted(absolute) then
              return { text, 'SqmeowDeletedText' }
            end
            -- A marked row's line highlight shows through plain text.
            local plain = absolute ~= nil and edit.changed(absolute) and nil or 'SqmeowText'
            return {
              text,
              type_group(value, is_null, column.numeric) or plain,
              fill = staged and 'SqmeowChanged' or nil,
            }
          else
            -- Staged inserts sit below the page rows.
            local insert_pos = row_pos - #page.rows
            local values = edit.inserts()[insert_pos]
            local value = values and values[col_index - 1] or nil
            if value == nil then
              return ''
            end
            local text, is_null = cell_text(value, null_text)
            return { text, type_group(value, is_null, column.numeric) }
          end
        end,
      })
    end
    return columns
  end

  --- Assemble the data the table module draws: page rows followed by inserts.
  ---@return table[]
  local function build_data()
    local data = {}
    for i, row in ipairs(page.rows) do
      data[i] = row
    end
    for _, values in ipairs(edit.inserts()) do
      table.insert(data, values)
    end
    return data
  end

  -- The table instance is created once and reconfigured per draw.
  if tbl and tbl.bufnr ~= handle then
    tbl:set_buffer(handle)
  end
  if not tbl then
    tbl = Table.new({
      bufnr = handle,
      ns_id = NAMESPACE,
      columns = build_columns(),
      data = build_data(),
      trim = true,
      row_mark = row_mark,
    })
  else
    tbl.trim = true
    tbl.row_mark = row_mark
    tbl:set_columns(build_columns())
    tbl:set_data(build_data())
  end

  tbl:render()
  has_grid = true
  vim.bo[handle].modifiable = false
end

--- Draw the page on screen again, after something about how it is shown changed.
function M.redraw()
  draw()
  M.update_winbar(require('sqmeow.core.state').call)
  update_sticky()
end

--- Ask the engine for a slice of the current result and draw it.
---@param offset integer Where in the view the page should start.
---@return boolean drawn
function M.show_page(offset)
  local state = require('sqmeow.core.state')
  local call = state.call
  if not (call and call.call_id) then
    return false
  end

  local size = page_size()
  local total = call.view_rows or call.rows or 0
  -- Past either end settles on the last or first page rather than emptying the view.
  local last = math.max(math.ceil(total / size) - 1, 0) * size
  offset = math.max(math.min(offset, last), 0)

  local reply, err = require('sqmeow.rpc.client').request('rows', {
    call_id = call.call_id,
    offset = offset,
    limit = size,
  })
  if err or type(reply) ~= 'table' then
    -- A result the engine evicted is read back from where it was saved.
    if
      err
      and err:find('no longer held', 1, true)
      and call.archive
      and vim.uv.fs_stat(call.archive)
    then
      local connection = state.connections[call.conn_id]
      require('sqmeow.api.view').restore({
        result = call.archive,
        statement = call.statement,
        connection = connection and connection.name or call.connection,
        dialect = connection and connection.dialect or call.dialect,
        at = call.ran_at,
      })
      return false
    end
    utils.notify(err or 'the engine sent no rows', vim.log.levels.WARN)
    return false
  end

  -- Show the engine's view count only when it differs from the retained row count.
  call.view_rows = reply.total ~= call.rows and reply.total or nil
  page = { offset = offset, rows = reply.rows or {}, indices = reply.indices or {} }
  draw()
  M.update_winbar(call)
  update_sticky()
  return true
end

--- Apply the current result's filter and sort specification in the engine.
---@return boolean sent
function M.send_view(opts)
  opts = opts or {}
  local call = require('sqmeow.core.state').call
  if not (call and call.call_id) then
    return false
  end

  local spec = M.spec()
  local rpc = require('sqmeow.rpc.client')
  if (spec.aggregates or '') ~= '' and require('sqmeow.ui.edit').count() > 0 then
    utils.notify(
      'discard or apply staged edits before aggregating the snapshot',
      vim.log.levels.WARN
    )
    return false
  end
  local source_id = call.call_id
  -- Only a new query replaces the result and drops staged changes. Ask the same Rust
  -- router before prompting; the actual request rechecks if the connection changed.
  if opts.refresh and require('sqmeow.ui.edit').count() > 0 then
    local requested = vim.deepcopy(spec)
    local route, route_err =
      rpc.request('result_view_route', { call_id = source_id, refresh = true })
    if not route then
      utils.notify(route_err or 'the result cannot be refreshed', vim.log.levels.WARN)
      return false
    end
    if
      route == 'query'
      and require('sqmeow.ui.edit').settle(function()
        specs[call.call_id] = requested
        M.send_view(opts)
      end)
    then
      return false
    end
  end
  local base = spec.base or call.sql
  local reply, err = rpc.request('result_view', {
    call_id = source_id,
    refresh = opts.refresh,
    conn_id = call.conn_id,
    sql = base,
    inserted = opts.keep,
    filters = spec.filters,
    sort = spec.sort,
    where = spec.where,
    order_by = spec.order_by,
    group_by = spec.group_by,
    aggregates = spec.aggregates,
    having = spec.having,
  })
  if err then
    utils.notify(err, vim.log.levels.WARN)
    return false
  end
  call.aggregate_pending = (spec.aggregates or '') ~= ''
  if reply.route == 'query' then
    spec.base = base
    carried = vim.deepcopy(spec)
    resume = opts.keep
        and { offset = page.offset, cursor = M.window() and vim.api.nvim_win_get_cursor(win) }
      or nil
    local state = require('sqmeow.core.state')
    state.call = {
      call_id = reply.call_id,
      conn_id = call.conn_id,
      state = 'executing',
      statement = base,
      history = false,
    }
    M.update_winbar(state.call)
  else
    M.update_winbar(call)
  end
  return true
end

--- The engine finished building a view.
---@param payload { call_id: integer, rows: integer|nil, error: string|nil }
local function apply_view_summary(call, payload)
  if not payload.summary then
    return
  end
  local schema_changed = not vim.deep_equal(call.columns, payload.summary.columns)
  call.original_columns = payload.aggregated and payload.original_columns or nil
  call.columns = payload.summary.columns
  call.source = payload.summary.source
  call.rows = payload.summary.rows
  call.truncated = payload.summary.truncated
  call.capabilities = payload.summary.capabilities
  call.aggregated = payload.aggregated
  call.source_rows = payload.source_rows
  call.view_rows = payload.rows ~= call.rows and payload.rows or nil
  content_widths = {}
  if schema_changed then
    M.spec().hidden = {}
  end
end

function M.on_view(payload)
  local active = require('sqmeow.core.state').call
  if active and active.call_id == payload.call_id then
    active.aggregate_pending = nil
  end
  local at = resuming_views[payload.call_id]
  resuming_views[payload.call_id] = nil
  if payload.error then
    if pending_views[payload.call_id] then
      specs[payload.call_id] = pending_views[payload.call_id]
      M.update_winbar(require('sqmeow.core.state').call)
    end
    pending_views[payload.call_id] = nil
    if at then
      -- A refreshed schema can invalidate the old filter. Show the new original rows instead.
      local spec = specs[payload.call_id]
      spec.where, spec.order_by, spec.filters, spec.sort = '', '', {}, {}
      spec.group_by, spec.aggregates, spec.having = '', '', ''
      local call = require('sqmeow.core.state').call
      if call and call.call_id == payload.call_id then
        M.show_page(at.offset)
      end
    end
    return utils.notify(payload.error, vim.log.levels.WARN)
  end
  pending_views[payload.call_id] = nil
  local state = require('sqmeow.core.state')
  local call = state.call
  if payload.summary then
    local source = call and call.call_id == payload.call_id and call or nil
    if not source then
      for _, summary in ipairs(state.calls) do
        if summary.call_id == payload.call_id then
          source = summary
          break
        end
      end
    end
    local previous = view_summaries[payload.call_id]
    payload.original_columns = (previous and previous.original_columns)
      or (source and (source.original_columns or source.columns))
    view_summaries[payload.call_id] = payload
  end
  if call and call.call_id == payload.call_id then
    apply_view_summary(call, payload)
    call.view_rows = payload.rows ~= call.rows and payload.rows or nil
    M.show_page(at and at.offset or 0)
    if at and at.cursor and M.window() then
      pcall(vim.api.nvim_win_set_cursor, win, at.cursor)
    end
  end
end

--- Whether a retained result can be filtered locally, preserving capability/RPC errors.
---@param call sqmeow.CallSummary|nil
---@return boolean
---@return string|nil error
function M.filterable(call)
  if not (call and call.call_id) then
    return false, 'there is no result to filter'
  end
  local flags, err = require('sqmeow.rpc.client').request('result_capabilities', {
    call_id = call.call_id,
  })
  if not flags then
    return false, err or 'the result capabilities could not be read'
  end
  return flags.filter == true, flags.filter ~= true and 'this result cannot be filtered' or nil
end

--- Polars column names, with numeric suffixes for duplicates.
---@param call sqmeow.CallSummary
---@return string[]
function M.filter_names(call)
  local taken, names = {}, {}
  for index, column in ipairs(call.columns or {}) do
    local candidate, count = column.name, 1
    while taken[candidate:lower()] do
      count = count + 1
      candidate = ('%s_%d'):format(column.name, count)
    end
    taken[candidate:lower()] = true
    names[index] = candidate
  end
  return names
end

--- The result's source dialect, retained after disconnecting.
---@param call sqmeow.CallSummary|nil
---@return string|nil
function M.dialect(call)
  local connection = call
    and call.conn_id
    and require('sqmeow.core.state').connections[call.conn_id]
  return connection and connection.dialect or (call and call.dialect)
end

--- An identifier quoted for Polars SQL, independently of the original database.
---@param name string
---@return string
function M.quote(name)
  return '"' .. (name:gsub('"', '""')) .. '"'
end

--- Run the current result's query again, changing the parts of its view `view` names.
---@param view table|nil Fields of the view to replace, such as `where` and `order_by`.
---@param keep boolean|nil Open the new result at the same page and cursor, with the rows inserts returned.
---@return boolean started
function M.rerun(view, keep)
  local call = require('sqmeow.core.state').call
  if not (call and call.call_id) then
    return false
  end
  local spec = M.spec()
  local before = vim.deepcopy(spec)
  specs[call.call_id] = vim.tbl_extend('force', vim.deepcopy(spec), view or {})
  if M.send_view({ keep = keep, refresh = true }) then
    return true
  end
  specs[call.call_id] = before
  return false
end

--- Narrow held rows with Polars SQL, restoring the previous view if validation fails.
---@return boolean sent
local function narrow(where, order_by, sort, grouping)
  local call = require('sqmeow.core.state').call
  local id = call and call.call_id
  if not id then
    return false
  end
  local spec = M.spec()
  local before = vim.deepcopy(spec)
  spec.where, spec.order_by, spec.sort = where, order_by, sort
  if grouping then
    spec.group_by, spec.aggregates, spec.having =
      grouping.group_by or '', grouping.aggregates or '', grouping.having or ''
  end
  if M.send_view() then
    local shown = require('sqmeow.core.state').call
    if shown and shown.call_id == id then
      pending_views[id] = before
    end
    return true
  end
  specs[id] = before
  return false
end

--- Group/aggregate retained snapshots with Polars; never execute database SQL.
--- Empty grouping fields restore an ordinary filtered view.
function M.aggregate(view)
  local call = require('sqmeow.core.state').call
  local allowed, err = M.filterable(call)
  if not allowed then
    utils.notify(err or 'there is no retained result to aggregate', vim.log.levels.WARN)
    return false
  end
  local requested = vim.deepcopy(view)
  if (requested.aggregates or '') ~= '' and require('sqmeow.ui.edit').count() > 0 then
    require('sqmeow.ui.edit').settle(function()
      if require('sqmeow.core.state').call == call then
        M.aggregate(requested)
      end
    end)
    return false
  end
  local spec = M.spec()
  return narrow(requested.where or spec.where, requested.order_by or '', {}, requested)
end

--- Filter and order retained rows with Polars SQL, never rerunning the database query.
---@param where string A WHERE condition, or empty for none.
---@param order_by string An ORDER BY list, or empty for none.
---@return boolean started
function M.filter(where, order_by)
  local call = require('sqmeow.core.state').call
  local allowed, err = M.filterable(call)
  if not allowed then
    utils.notify(err or 'this result cannot be filtered', vim.log.levels.WARN)
    return false
  end
  return narrow(where, order_by, {})
end

--- Draw a result from its beginning.
---@param summary sqmeow.CallSummary|nil
function M.render(summary)
  page = { offset = 0, rows = {}, indices = {} }

  local id = summary and summary.call_id
  if id and view_summaries[id] then
    apply_view_summary(summary, view_summaries[id])
  end
  if id ~= drawn then
    drawn = id
    content_widths = {}
    -- Staged changes name rows of the result they were made on, which is no longer on screen.
    local dropped = require('sqmeow.ui.edit').reset()
    if dropped > 0 then
      utils.notify(
        ('%d unapplied change%s dropped: another result replaced the one they were made on'):format(
          dropped,
          dropped == 1 and ' was' or 's were'
        ),
        vim.log.levels.WARN
      )
    end
    if carried and id then
      specs[id], pending = carried, id
    end
    carried = nil
  end

  if not (summary and id and summary.state == 'done') then
    draw()
    M.update_winbar(summary)
    update_sticky()
    return
  end

  local at
  if pending == id then
    pending, at, resume = nil, resume, nil
    local spec = M.spec()
    if
      spec.where ~= ''
      or spec.order_by ~= ''
      or #spec.filters > 0
      or #spec.sort > 0
      or (spec.aggregates or '') ~= ''
    then
      resuming_views[id] = at or { offset = 0 }
      if M.send_view() then
        draw()
        M.update_winbar(summary)
        return
      end
      resuming_views[id] = nil
    end
  end
  M.show_page(at and at.offset or 0)
  if at and at.cursor and M.window() then
    pcall(vim.api.nvim_win_set_cursor, win, at.cursor)
  end
end

--- The row the page on screen starts at, counted in the view.
---@return integer
function M.offset()
  return page.offset
end

--- The columns the grid shows, zero-based and in order, or nil when none is hidden.
---@return integer[]|nil
function M.visible_columns()
  local call = require('sqmeow.core.state').call
  local spec = M.spec()
  if not (call and call.columns) or vim.tbl_isempty(spec.hidden) then
    return nil
  end

  local shown = {}
  for index = 0, #call.columns - 1 do
    if not spec.hidden[index] then
      table.insert(shown, index)
    end
  end
  return shown
end

-- -- where the cursor is ---------------------------------------------------------------------

--- Which result column the cursor is in, wherever it is in the grid, header included.
---@param call? table Summary or state call.
---@return { column: integer, name: string, line: integer }|nil # `column` zero-based.
local function cursor_column(call)
  call = call or require('sqmeow.core.state').call
  if not (win and utils.shows(win, buf) and call and call.columns and tbl) then
    return nil
  end

  local cell = tbl:get_cell(nil, win)
  if not cell then
    return nil
  end

  -- The column id is the 1-based engine index stored as a string.
  local col_index = tonumber(cell.column.id) or 1
  return {
    column = col_index - 1,
    name = call.columns[col_index] and call.columns[col_index].name or '',
    line = vim.api.nvim_win_get_cursor(win)[1],
  }
end

--- Where the cursor is in the result, as a row and a column of the data.
---@return { row: integer|nil, insert: integer|nil, column: integer, name: string, value: any }|nil # Nil when the cursor is on the header rather than on a row.
function M.current_cell()
  local found = cursor_column()
  if not found then
    return nil
  end

  local position = found.line - HEADER_LINES
  if position < 1 then
    return nil
  end
  if position <= #page.rows then
    return {
      row = page.indices[position] or (page.offset + position - 1),
      column = found.column,
      name = found.name,
      value = page.rows[position][found.column + 1],
    }
  end

  local insert = position - #page.rows
  if require('sqmeow.ui.edit').inserts()[insert] then
    return { insert = insert, column = found.column, name = found.name }
  end
  return nil
end

--- Put the cursor on a column, keeping the row it is already on.
---@param index integer One-based column.
---@return boolean moved
function M.goto_column(index)
  if not (win and utils.shows(win, buf) and tbl) then
    return false
  end

  local cell = tbl:goto_column(index, win)
  if cell then
    vim.api.nvim_set_current_win(win)
    return true
  end
  return false
end

--- The rows a visual selection covers, leaving visual mode.
---@return { row: integer|nil, insert: integer|nil }[]
local function selected()
  local first, last = vim.fn.line('v'), vim.fn.line('.')
  if first > last then
    first, last = last, first
  end
  vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })

  local inserts = require('sqmeow.ui.edit').inserts()
  local targets = {}
  for position = math.max(first - HEADER_LINES, 1), last - HEADER_LINES do
    if position <= #page.rows then
      table.insert(targets, { row = page.indices[position] or (page.offset + position - 1) })
    elseif inserts[position - #page.rows] then
      table.insert(targets, { insert = position - #page.rows })
    end
  end
  return targets
end

-- -- the float --------------------------------------------------------------------------------

--- Whether the grid is showing in its float.
---@return boolean
function M.is_float()
  return popup ~= nil and utils.shows(win, buf)
end

--- Show the grid in a float, moving it out of its split.
---@return integer|nil win
function M.open_float()
  if win and M.is_float() then
    vim.api.nvim_set_current_win(win)
    return win
  end

  local parts, err = utils.nui({ 'popup' }, 'the result float')
  if not parts then
    utils.notify(err, vim.log.levels.ERROR)
    return nil
  end

  local layout = require('sqmeow.ui.layout')
  layout.remember()
  local cursor
  if win and utils.shows(win, buf) then
    cursor = vim.api.nvim_win_get_cursor(win)
    layout.close_window(win)
  end
  if popup then
    popup:unmount()
  end

  popup = parts.Popup({
    enter = true,
    focusable = true,
    relative = 'editor',
    position = '50%',
    size = { width = '90%', height = '80%' },
    zindex = 40,
    bufnr = M.buffer(),
    border = {
      style = require('sqmeow.config').border(),
      -- A title, as every dialog has.
      text = { top = ' Result ', top_align = 'center' },
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = 'no',
      wrap = false,
      cursorline = true,
    },
  })
  popup:mount()
  win = popup.winid
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  M.update_winbar(require('sqmeow.core.state').call)
  update_sticky()
  return win
end

--- Move the grid between its split and its float.
function M.toggle_float()
  -- The bar is docked to the window the grid is leaving.
  require('sqmeow.ui.filter').close()
  if not M.is_float() then
    return M.open_float()
  end
  if not (popup and win) then
    popup, win = nil, nil
    return M.open()
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local closing = popup
  popup, win = nil, nil
  closing:unmount()

  win = M.open()
  vim.api.nvim_set_current_win(win)
  pcall(vim.api.nvim_win_set_cursor, win, cursor)
end

--- Check whether the result can be edited and report the reason if it cannot.
---@return boolean
local function editing()
  local state = require('sqmeow.core.state')
  local call = state.call
  if call and (call.aggregated or call.aggregate_pending) then
    utils.notify(
      'aggregate results are read-only; reset the view to edit original rows',
      vim.log.levels.WARN
    )
    return false
  end
  local connection = call and call.conn_id and state.connections[call.conn_id]
  if connection and connection.read_only then
    utils.notify(
      ('`%s` is read-only, so its results cannot be edited'):format(connection.name),
      vim.log.levels.WARN
    )
    return false
  end
  if not (call and call.source) then
    utils.notify(
      'this result cannot be edited: its rows cannot be traced back to where they are stored',
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

--- Order retained rows by a column, always using Polars SQL.
local function sort_by(column, add)
  local spec = M.spec()
  local sort = vim.deepcopy(spec.sort)
  local at
  for index, key in ipairs(sort) do
    if key.column == column then
      at = index
    end
  end
  local key = at and sort[at]

  if add then
    if not key then
      table.insert(sort, { column = column, descending = false })
    elseif not key.descending then
      key.descending = true
    else
      table.remove(sort, at)
    end
  elseif not key then
    sort = { { column = column, descending = false } }
  elseif not key.descending then
    sort = { { column = column, descending = true } }
  else
    sort = {}
  end

  local call = require('sqmeow.core.state').call
  if not (call and call.call_id) then
    return
  end
  local names = M.filter_names(call)
  local keys = {}
  for _, entry in ipairs(sort) do
    local name = M.quote(names[entry.column + 1] or '')
    table.insert(keys, name .. (entry.descending and ' DESC' or ' ASC') .. ' NULLS LAST')
  end
  local order_by = table.concat(keys, ', ')
  narrow(spec.where, order_by, sort)
end

-- -- actions --------------------------------------------------------------------------------

--- Actions the result window's keys are bound to.
M.actions = {}

function M.actions.next_page()
  require('sqmeow.api.query').next_page()
end

function M.actions.prev_page()
  require('sqmeow.api.query').prev_page()
end

function M.actions.first_page()
  require('sqmeow.api.query').first_page()
end

function M.actions.last_page()
  require('sqmeow.api.query').last_page()
end

function M.actions.next_column()
  if tbl and win and utils.shows(win, buf) then
    tbl:next_column(win)
  end
end

function M.actions.prev_column()
  if tbl and win and utils.shows(win, buf) then
    tbl:prev_column(win)
  end
end

--- Write the whole result to a file.
function M.actions.export()
  require('sqmeow.api.export').export()
end

--- Write the rows the visual selection covers to a file.
function M.actions.export_selection()
  local first, last = vim.fn.line('v'), vim.fn.line('.')
  if first > last then
    first, last = last, first
  end
  vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })

  -- Buffer lines to rows of this page: the column names and the rule above them are not rows.
  first = math.max(first - HEADER_LINES, 1)
  last = math.min(last - HEADER_LINES, #page.rows)
  if last < first then
    return
  end
  require('sqmeow.api.export').export({ offset = page.offset + first - 1, limit = last - first + 1 })
end

--- Show the row under the cursor as a list of columns and values.
function M.actions.detail()
  local cell = M.current_cell()
  if not (cell and cell.row) then
    return
  end
  require('sqmeow.ui.detail').open(cell.row)
end

function M.actions.toggle_float()
  M.toggle_float()
end

--- The relation a query reads from, as written: `FROM` for SQL, the collection of a MongoDB
--- command, the key of a Redis one.
---@param call sqmeow.CallSummary
---@return string|nil schema
---@return string|nil relation
function M.read_from(call)
  local sql = call.sql or call.statement or ''
  local dialect = M.dialect(call)
  if dialect == 'mongodb' then
    return '', sql:match('"find"%s*:%s*"([^"]+)"') or sql:match('"aggregate"%s*:%s*"([^"]+)"')
  end
  if dialect == 'redis' then
    return '', sql:match('^%s*%S+%s+"([^"]+)"') or sql:match('^%s*%S+%s+(%S+)')
  end
  local name = sql:match('[Ff][Rr][Oo][Mm]%s+([%w_%.`"%[%]]+)')
  if not name then
    return nil, nil
  end
  local parts = vim.split((name:gsub('[`"%[%]]', '')), '.', { plain = true })
  return #parts > 1 and parts[#parts - 1] or '', parts[#parts]
end

--- Show the structure of the table the column under the cursor comes from.
local function show_table(surface)
  local call = require('sqmeow.core.state').call
  if not call then
    return
  end
  local tables = call.source and call.source.tables
  -- A result that cannot be traced back to a table shows the one its query reads from.
  if not (tables and #tables > 0) then
    local schema, relation = M.read_from(call)
    if not (relation and call.conn_id) then
      return utils.notify('this result names no table to show', vim.log.levels.WARN)
    end
    return require('sqmeow.ui.' .. surface).open(call.conn_id, schema or '', relation)
  end
  local here = cursor_column()
  local chosen = tables[1]
  for _, candidate in ipairs(tables) do
    if here and vim.tbl_contains(candidate.columns, here.column) then
      chosen = candidate
      break
    end
  end
  require('sqmeow.ui.' .. surface).open(call.conn_id, chosen.schema or '', chosen.name)
end

function M.actions.structure()
  show_table('structure')
end

--- Use the same column provenance and query fallback as the structure action.
function M.actions.relationships()
  show_table('relationships')
end

--- Show another statement's result from the same run.
---@param step integer
local function switch(step)
  local state = require('sqmeow.core.state')
  local call = state.call
  local results = call and call.results
  if not (call and results and #results > 1) then
    return utils.notify('this query returned one result')
  end
  if require('sqmeow.ui.edit').settle(function()
    switch(step)
  end) then
    return
  end
  local at = 1
  for index, entry in ipairs(results) do
    if entry.call_id == call.call_id then
      at = index
    end
  end
  local shown = vim.tbl_extend(
    'force',
    { conn_id = call.conn_id, statement = call.statement, history = false },
    results[(at - 1 + step) % #results + 1],
    { results = results }
  )
  state.call = shown
  M.render(shown)
end

function M.actions.next_result()
  switch(1)
end

function M.actions.prev_result()
  switch(-1)
end

--- Show only the rows holding the value under the cursor in its column.
function M.actions.filter_cell()
  local cell = M.current_cell()
  if not (cell and cell.row) then
    return
  end

  local call = require('sqmeow.core.state').call
  if call and call.call_id then
    local condition, err = require('sqmeow.rpc.client').request('condition', {
      call_id = call.call_id,
      row = cell.row,
      column = cell.column,
    })
    if not condition then
      return utils.notify(err or 'the value could not be matched', vim.log.levels.WARN)
    end
    local spec = M.spec()
    if call.aggregated then
      local having = (spec.having or '') == '' and condition
        or ('(%s) AND %s'):format(spec.having, condition)
      narrow(
        spec.where,
        spec.order_by,
        spec.sort,
        { group_by = spec.group_by, aggregates = spec.aggregates, having = having }
      )
      return
    end
    local where = spec.where == '' and condition or ('(%s) AND %s'):format(spec.where, condition)
    narrow(where, spec.order_by, spec.sort)
    return
  end
end

function M.actions.filter()
  require('sqmeow.ui.filter').open(1)
end

function M.actions.order()
  require('sqmeow.ui.filter').open(2)
end

function M.actions.group()
  require('sqmeow.ui.filter').open(3)
end

function M.actions.sort()
  local here = cursor_column()
  if here then
    sort_by(here.column, false)
  end
end

function M.actions.sort_add()
  local here = cursor_column()
  if here then
    sort_by(here.column, true)
  end
end

function M.actions.hide_column()
  local call = require('sqmeow.core.state').call
  local here = cursor_column()
  if not (call and here) then
    return
  end
  local spec = M.spec()
  if #call.columns - vim.tbl_count(spec.hidden) <= 1 then
    return utils.notify('the last column cannot be hidden', vim.log.levels.WARN)
  end
  spec.hidden[here.column] = true
  M.redraw()
end

function M.actions.show_columns()
  M.spec().hidden = {}
  M.redraw()
end

--- Clear the filters, sort and hidden columns, and show every row again.
function M.actions.reset_view()
  local call = require('sqmeow.core.state').call
  if not (call and call.call_id) then
    return
  end
  local spec = M.spec()
  local before = spec
  specs[call.call_id] = fresh()
  specs[call.call_id].base = before.base
  pending_views[call.call_id] = vim.deepcopy(before)
  if not M.send_view() then
    specs[call.call_id] = before
    pending_views[call.call_id] = nil
  end
end

function M.actions.edit_cell()
  local cell = editing() and M.current_cell()
  if cell then
    require('sqmeow.ui.edit').edit_cell(cell)
  end
end

function M.actions.set_expression()
  local cell = editing() and M.current_cell()
  if not cell then
    return
  end
  local state = require('sqmeow.core.state')
  local dialect = (state.call and state.connections[state.call.conn_id] or {}).dialect
  if dialect == 'redis' or dialect == 'mongodb' then
    return utils.notify(('%s takes no SQL expression'):format(dialect), vim.log.levels.WARN)
  end
  require('sqmeow.ui.edit').edit_cell(cell, true)
end

function M.actions.set_null()
  local cell = editing() and M.current_cell()
  if not cell then
    return
  end
  local column = require('sqmeow.core.state').call.columns[cell.column + 1]
  if not (column and column.editable) then
    return utils.notify(('`%s` cannot be edited'):format(cell.name), vim.log.levels.WARN)
  end
  require('sqmeow.ui.edit').set(cell, cell.column, vim.NIL)
end

--- Stage a copy of the row under the cursor as a new row, leaving out its primary key.
function M.actions.duplicate_row()
  local cell = editing() and M.current_cell()
  if not (cell and cell.row) then
    return
  end
  local call = require('sqmeow.core.state').call
  if not (call and call.source and call.columns) then
    return
  end
  if not call.source.insertable then
    return utils.notify(
      'a row cannot be added to a result that shows more than one table',
      vim.log.levels.WARN
    )
  end
  local row, err =
    require('sqmeow.rpc.client').request('row', { call_id = call.call_id, row = cell.row })
  if not row then
    return utils.notify(err or 'that row is not there', vim.log.levels.WARN)
  end

  local edit = require('sqmeow.ui.edit')
  local values = {}
  for index, column in ipairs(call.columns) do
    if column.editable and column.key ~= 'primary_key' then
      local staged, has = edit.staged(cell.row, index - 1)
      if has then
        values[index - 1] = staged
      elseif row[index] then
        values[index - 1] = row[index].is_null and vim.NIL or row[index].value
      end
    end
  end
  edit.add_row(values)
  if win then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(M.buffer()), 0 })
  end
end

function M.actions.add_row()
  if not editing() then
    return
  end
  if not require('sqmeow.core.state').call.source.insertable then
    return utils.notify(
      'a row cannot be added to a result that shows more than one table',
      vim.log.levels.WARN
    )
  end
  require('sqmeow.ui.edit').add_row()
  if win then
    local last = vim.api.nvim_buf_line_count(M.buffer())
    vim.api.nvim_win_set_cursor(win, { last, 0 })
  end
end

function M.actions.delete_row()
  local cell = editing() and M.current_cell()
  if cell then
    require('sqmeow.ui.edit').toggle_delete({ cell })
  end
end

function M.actions.delete_selection()
  local targets = selected()
  if editing() and #targets > 0 then
    require('sqmeow.ui.edit').toggle_delete(targets)
  end
end

function M.actions.cancel()
  if not require('sqmeow.api.query').cancel() then
    utils.notify('there is nothing running to stop')
  end
end

function M.actions.undo()
  if editing() and not require('sqmeow.ui.edit').undo() then
    utils.notify('there is nothing to undo')
  end
end

function M.actions.discard()
  if not editing() then
    return
  end
  local dropped = require('sqmeow.ui.edit').reset()
  M.redraw()
  utils.notify(('discarded %d change%s'):format(dropped, dropped == 1 and '' or 's'))
end

function M.actions.review()
  if editing() then
    require('sqmeow.ui.edit').review()
  end
end

function M.actions.help()
  require('sqmeow.ui.help').open('result')
end

function M.actions.close()
  M.close()
end

-- -- the window -----------------------------------------------------------------------------

--- Show the result window, creating it if needed.
---@return integer win
function M.open()
  if win and utils.shows(win, buf) then
    return win
  end
  if popup then
    -- Closed some other way than through here, such as `:close`, which leaves nui a mount to undo.
    popup:unmount()
    popup = nil
  end

  local config = require('sqmeow.config').get()
  require('sqmeow.ui.layout').remember()
  local previous = vim.api.nvim_get_current_win()

  vim.cmd(('botright %dsplit'):format(config.ui.result.height))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M.buffer())

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  -- Other splits must not squash the grid, which would silently hide columns.
  vim.wo[win].winfixheight = true

  -- Opening a result should not steal the cursor from the query being written.
  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  M.update_winbar(require('sqmeow.core.state').call)
  update_sticky()
  return win
end

--- The window showing the grid, or nil.
---@return integer|nil
function M.window()
  return utils.shows(win, buf) and win or nil
end

--- The sticky header window when pinned, or nil.
---@return integer|nil
function M.sticky_window()
  return (sticky_win and vim.api.nvim_win_is_valid(sticky_win)) and sticky_win or nil
end

--- Hide the result window, keeping what it holds.
function M.close()
  close_sticky()
  require('sqmeow.ui.filter').close()
  if popup then
    local closing = popup
    popup = nil
    closing:unmount()
  elseif win and utils.shows(win, buf) then
    require('sqmeow.ui.layout').close_window(win)
  end
  win = nil

  require('sqmeow.ui.detail').close()
  require('sqmeow.ui.layout').restore()
end

--- Whether the result window is showing, in its split or its float.
---@return boolean
function M.is_open()
  return utils.shows(win, buf)
end

--- Update the line above the grid.
---@param summary sqmeow.CallSummary|nil
function M.update_winbar(summary)
  if not utils.shows(win, buf) or not require('sqmeow.config').get().ui.winbar then
    return
  end

  -- The connection the result came from, not the active one.
  local state = require('sqmeow.core.state')
  ---@type { name: string, dialect: string|nil }|nil
  local connection = summary and summary.conn_id and state.connections[summary.conn_id]
  if not connection and summary and summary.connection then
    -- A result shown from the log names the database it came from, whether or not that is open.
    connection = { name = summary.connection, dialect = summary.dialect }
  end
  connection = connection or state.current_connection()
  local label = connection and state.label(connection) or 'not connected'

  -- Dynamic active column information
  local col_info = ''
  local config = require('sqmeow.config').get()
  if config.ui.result.winbar_column_info then
    local cell = cursor_column(summary)
    if cell and cell.name and cell.name ~= '' then
      local call = summary or state.call
      local total = call and call.columns and #call.columns or 0
      local col_type = call
          and call.columns
          and call.columns[cell.column + 1]
          and call.columns[cell.column + 1].type_name
        or ''
      local icon = require('sqmeow.core.icons').get('column')
      local icon_str = (icon and icon ~= '') and (icon .. ' ') or '󰠵 '
      local name_escaped = cell.name:gsub('%%', '%%%%')
      col_info = ('  %%#SqmeowSignAdded#%s%s%%*'):format(icon_str, name_escaped)
      if col_type ~= '' then
        local type_escaped = col_type:gsub('%%', '%%%%')
        col_info = col_info .. (' %%#SqmeowNull#(%s)%%*'):format(type_escaped)
      end
      if total > 0 then
        col_info = col_info .. (' %%#SqmeowNull#[%d/%d]%%*'):format(cell.column + 1, total)
      end
    end
  end

  vim.wo[win].winbar = ('%%#SqmeowWinbar# %s  %%*%s%s'):format(
    label,
    M.describe(summary, true),
    col_info
  )
end

return M
