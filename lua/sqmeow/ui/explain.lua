--- Visual query execution plan viewer (`:Sqmeow explain`).
---
--- Executes dialect-specific `EXPLAIN` queries silently over RPC (without
--- opening the result grid, clobbering `state.call`, or polluting query
--- history) and renders an interactive operator tree with cost/time bars,
--- buffer statistics, sequential-scan and row-estimate mismatch warnings,
--- subtree folding, and an operator detail popup.

local M = {}

local notify = require('sqmeow.core.utils').notify

local ns = vim.api.nvim_create_namespace('sqmeow.explain')

---@class sqmeow.ExplainStats
---@field seq_scans integer
---@field mismatches integer
---@field shared_hit integer
---@field shared_read integer

---@class sqmeow.ExplainMeta
---@field total_time number
---@field excl_time number
---@field excl_cost number
---@field pct number
---@field flags string[]
---@field is_seq_scan boolean
---@field has_mismatch boolean
---@field collapsed boolean

---@class sqmeow.ExplainView
---@field buf integer
---@field win integer
---@field entry table
---@field root table
---@field raw_json string
---@field sql string
---@field is_analyze boolean
---@field connection string
---@field stats sqmeow.ExplainStats
---@field line_to_node table<integer, table>

---@class sqmeow.ExplainPending
---@field sql string
---@field is_analyze boolean
---@field connection string

---@type sqmeow.ExplainView|nil
local view = nil

---@type any|nil
local detail_popup = nil

--- In-flight silent EXPLAIN calls keyed by `call_id`.
---@type table<integer, sqmeow.ExplainPending>
local silent_calls = {}

--- Most recent active EXPLAIN call id, for cancellation via `api.query.cancel()`.
---@type integer|nil
local active_call_id = nil

--- Monotonic counter bumped on engine restart/stop to drop queued `done` callbacks.
local generation = 0

--- True while `rpc.request('execute', ...)` for an EXPLAIN call is waiting for its `call_id`.
local in_flight = false

--- Events received while `in_flight` is true, replayed once `call_id` is known.
---@type table[]
local buffered_events = {}

--- Split `sql` into statements while respecting quotes, dollar-quotes, and comments.
--- Each entry records `{ text, start_line, end_line }` with 1-based line numbers.
---@param sql string
---@return { text: string, start_line: integer, end_line: integer }[]
local function split_statements(sql)
  local stmts = {}
  local len = #sql
  local i = 1
  local line = 1
  local stmt_start = 1
  local stmt_start_line = 1

  local function flush(end_pos, end_line)
    local raw = sql:sub(stmt_start, end_pos)
    local trimmed = vim.trim(raw)
    if trimmed ~= '' then
      table.insert(stmts, {
        text = trimmed,
        start_line = stmt_start_line,
        end_line = end_line,
      })
    end
  end

  while i <= len do
    local ch = sql:sub(i, i)
    local two = sql:sub(i, i + 1)

    if ch == '\n' then
      line = line + 1
      i = i + 1
    elseif two == '--' then
      local nl = sql:find('\n', i + 2, true)
      if nl then
        line = line + 1
        i = nl + 1
      else
        i = len + 1
      end
    elseif two == '/*' then
      local close = sql:find('*/', i + 2, true)
      if close then
        for _ in sql:sub(i + 2, close + 1):gmatch('\n') do
          line = line + 1
        end
        i = close + 2
      else
        i = len + 1
      end
    elseif ch == "'" or ch == '"' then
      local quote = ch
      i = i + 1
      while i <= len do
        local c = sql:sub(i, i)
        if c == '\n' then
          line = line + 1
          i = i + 1
        elseif c == quote then
          if sql:sub(i + 1, i + 1) == quote then
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          i = i + 1
        end
      end
    elseif ch == '$' then
      local tag = sql:match('^%$[%w_]*%$', i)
      if tag then
        local close = sql:find(tag, i + #tag, true)
        if close then
          for _ in sql:sub(i + #tag, close - 1):gmatch('\n') do
            line = line + 1
          end
          i = close + #tag
        else
          i = len + 1
        end
      else
        i = i + 1
      end
    elseif ch == ';' then
      flush(i, line)
      i = i + 1
      stmt_start = i
      stmt_start_line = line
      -- Advance start line past trailing newlines/whitespace before the next statement
      while stmt_start <= len do
        local ws = sql:sub(stmt_start, stmt_start)
        if ws == '\n' then
          line = line + 1
          stmt_start = stmt_start + 1
          stmt_start_line = line
        elseif ws == ' ' or ws == '\t' or ws == '\r' then
          stmt_start = stmt_start + 1
        else
          break
        end
      end
      i = stmt_start
    else
      i = i + 1
    end
  end

  if stmt_start <= len then
    flush(len, line)
  end
  return stmts
end

--- Strip comments and quoted literals so keyword checks ignore string/comment contents.
---@param sql string
---@return string
local function strip_comments_and_literals(sql)
  local out = {}
  local len = #sql
  local i = 1
  while i <= len do
    local ch = sql:sub(i, i)
    local two = sql:sub(i, i + 1)
    if two == '--' then
      local nl = sql:find('\n', i + 2, true)
      table.insert(out, ' ')
      i = nl and (nl + 1) or (len + 1)
    elseif two == '/*' then
      local close = sql:find('*/', i + 2, true)
      table.insert(out, ' ')
      i = close and (close + 2) or (len + 1)
    elseif ch == "'" or ch == '"' then
      local quote = ch
      table.insert(out, ' ')
      i = i + 1
      while i <= len do
        local c = sql:sub(i, i)
        if c == quote then
          if sql:sub(i + 1, i + 1) == quote then
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          i = i + 1
        end
      end
    elseif ch == '$' then
      local tag = sql:match('^%$[%w_]*%$', i)
      if tag then
        local close = sql:find(tag, i + #tag, true)
        table.insert(out, ' ')
        i = close and (close + #tag) or (len + 1)
      else
        table.insert(out, ch)
        i = i + 1
      end
    else
      table.insert(out, ch)
      i = i + 1
    end
  end
  return vim.trim(table.concat(out))
end

--- Strip trailing semicolons and any leading `EXPLAIN (...)` prefix.
---@param sql string
---@return string
function M.strip_explain(sql)
  local cleaned = vim.trim(sql or '')
  cleaned = cleaned:gsub(';%s*$', '')
  cleaned = cleaned:gsub('^[Ee][Xx][Pp][Ll][Aa][Ii][Nn]%s*%b()%s*', '')
  cleaned = cleaned:gsub('^[Ee][Xx][Pp][Ll][Aa][Ii][Nn]%s+', '')
  return vim.trim(cleaned)
end

local MUTATING_KEYWORDS = {
  INSERT = true,
  UPDATE = true,
  DELETE = true,
  MERGE = true,
  CREATE = true,
  ALTER = true,
  DROP = true,
  TRUNCATE = true,
  COPY = true,
  GRANT = true,
  REVOKE = true,
}

--- Whether a SQL statement is read-only and safe to execute with `EXPLAIN ANALYZE`.
--- Rejects data-modifying CTEs (e.g. `WITH d AS (DELETE ...) SELECT * FROM d`).
---@param sql string
---@return boolean
function M.is_read_only(sql)
  local clean = strip_comments_and_literals(sql):upper()
  local is_read_head = clean:match('^SELECT%f[%W]') ~= nil
    or clean:match('^WITH%f[%W]') ~= nil
    or clean:match('^TABLE%f[%W]') ~= nil
    or clean:match('^VALUES%f[%W]') ~= nil
  if not is_read_head then
    return false
  end
  if clean:match('^WITH%f[%W]') ~= nil then
    for word in clean:gmatch('%a+') do
      if MUTATING_KEYWORDS[word] then
        return false
      end
    end
  end
  return true
end

--- Build the dialect-specific EXPLAIN statement for a single query.
---@param dialect string
---@param sql string
---@param opts? { analyze?: boolean }
---@return string|nil explain_sql
---@return boolean is_analyze
---@return string|nil err
function M.build_query(dialect, sql, opts)
  opts = opts or {}
  local stmts = split_statements(sql or '')
  if #stmts == 0 then
    return nil, false, 'there is nothing to explain'
  end
  if #stmts > 1 then
    return nil, false, 'explain supports one statement at a time'
  end

  local cleaned = M.strip_explain(stmts[1].text)
  if cleaned == '' then
    return nil, false, 'there is nothing to explain'
  end

  if dialect == 'postgres' or dialect == 'postgresql' then
    local analyze = opts.analyze
    if analyze == nil then
      analyze = M.is_read_only(cleaned)
    end
    local prefix = analyze and 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
      or 'EXPLAIN (FORMAT JSON) '
    return prefix .. cleaned, analyze, nil
  end

  return nil, false, ('visual explain plan is not supported for dialect `%s` yet'):format(dialect)
end

--- Extract the SQL statement containing `cursor_line` (1-based) from `lines`.
---@param lines string[]
---@param cursor_line integer
---@return string|nil
function M.statement_at_line(lines, cursor_line)
  if #lines == 0 then
    return nil
  end
  local stmts = split_statements(table.concat(lines, '\n'))
  if #stmts == 0 then
    return nil
  end
  for _, stmt in ipairs(stmts) do
    if cursor_line >= stmt.start_line and cursor_line <= stmt.end_line then
      return stmt.text
    end
  end
  return stmts[#stmts].text
end

---@param n number|nil
---@return string
local function format_num(n)
  if type(n) ~= 'number' then
    return '-'
  end
  if n >= 1000000 then
    return string.format('%.1fM', n / 1000000)
  elseif n >= 1000 then
    return string.format('%.1fk', n / 1000)
  end
  return tostring(math.floor(n + 0.5))
end

---@param ms number|nil
---@return string
local function format_ms(ms)
  if type(ms) ~= 'number' then
    return '-'
  end
  if ms >= 1000 then
    return string.format('%.2fs', ms / 1000)
  elseif ms >= 10 then
    return string.format('%.1fms', ms)
  end
  return string.format('%.2fms', ms)
end

---@param pct number|nil
---@param width? integer
---@return string
local function cost_bar(pct, width)
  width = width or 10
  local clamped = math.max(0, math.min(100, pct or 0))
  local filled = math.floor((clamped / 100) * width + 0.5)
  return ('█'):rep(filled) .. ('░'):rep(width - filled)
end

--- Recursively enrich a PostgreSQL plan tree with exclusive time/cost, share %, and hotspot flags.
---@param node table
---@param root_time number
---@param root_cost number
---@param is_analyze boolean
---@param stats? sqmeow.ExplainStats
---@return sqmeow.ExplainStats
function M.enrich(node, root_time, root_cost, is_analyze, stats)
  local is_root = stats == nil
  stats = stats or { seq_scans = 0, mismatches = 0, shared_hit = 0, shared_read = 0 }
  local children = node.Plans or {}
  local child_time_sum = 0
  local child_cost_sum = 0

  for _, child in ipairs(children) do
    M.enrich(child, root_time, root_cost, is_analyze, stats)
    local loops = child['Actual Loops'] or 1
    child_time_sum = child_time_sum + ((child['Actual Total Time'] or 0) * loops)
    child_cost_sum = child_cost_sum + (child['Total Cost'] or 0)
  end

  local loops = node['Actual Loops'] or 1
  local total_time = (node['Actual Total Time'] or 0) * loops
  local excl_time = math.max(0, total_time - child_time_sum)
  local total_cost = node['Total Cost'] or 0
  local excl_cost = math.max(0, total_cost - child_cost_sum)

  local pct = 0
  if is_analyze and root_time > 0 then
    pct = (excl_time / root_time) * 100
  elseif root_cost > 0 then
    pct = (excl_cost / root_cost) * 100
  end

  local flags = {}
  local ntype = node['Node Type'] or 'Unknown'
  local is_seq_scan = ntype == 'Seq Scan'
  if is_seq_scan then
    stats.seq_scans = stats.seq_scans + 1
    table.insert(flags, 'FULL SCAN')
  end

  local plan_rows = node['Plan Rows'] or 0
  local actual_rows = node['Actual Rows']
  local has_mismatch = false
  if is_analyze and actual_rows ~= nil then
    local ratio = math.max((actual_rows + 1) / (plan_rows + 1), (plan_rows + 1) / (actual_rows + 1))
    if ratio >= 10 and math.abs(actual_rows - plan_rows) >= 50 then
      has_mismatch = true
      stats.mismatches = stats.mismatches + 1
      table.insert(flags, 'EST MISMATCH')
    end
  end

  -- PostgreSQL reports buffer counters inclusively on parent nodes; read from the root
  -- to avoid double-counting child buffers.
  if is_root then
    stats.shared_hit = node['Shared Hit Blocks'] or 0
    stats.shared_read = node['Shared Read Blocks'] or 0
  end

  node._meta = {
    total_time = total_time,
    excl_time = excl_time,
    excl_cost = excl_cost,
    pct = pct,
    flags = flags,
    is_seq_scan = is_seq_scan,
    has_mismatch = has_mismatch,
    collapsed = false,
  }
  return stats
end

---@param meta sqmeow.ExplainMeta
---@param node_type string|nil
---@return string
local function node_severity_hl(meta, node_type)
  if meta.pct >= 50 or (meta.is_seq_scan and (meta.pct >= 20 or (meta.total_time or 0) >= 5)) then
    return 'SqmeowExplainHot'
  elseif meta.pct >= 20 or meta.has_mismatch or meta.is_seq_scan then
    return 'SqmeowExplainWarn'
  elseif (node_type or ''):find('Index', 1, true) then
    return 'SqmeowExplainOk'
  end
  return 'SqmeowExplainInfo'
end

local function close_detail()
  if detail_popup then
    local p = detail_popup
    detail_popup = nil
    pcall(function()
      p:unmount()
    end)
  end
end

---@param node table
local function show_node_details(node)
  close_detail()
  local meta = node._meta or {}
  local title = ' '
    .. (node['Node Type'] or 'Operator')
    .. (node['Relation Name'] and (' on ' .. node['Relation Name']) or '')
    .. ' '

  local lines = {}
  local function add(label, val)
    if val ~= nil and val ~= '' and val ~= vim.NIL then
      table.insert(lines, string.format('  %-22s %s', label .. ':', tostring(val)))
    end
  end

  add('Index Name', node['Index Name'])
  add('Alias', node['Alias'])
  add('Join Type', node['Join Type'])
  add('Exclusive Share', string.format('%.1f%%', meta.pct or 0))
  add('Exclusive Time', format_ms(meta.excl_time))
  add('Total Time', format_ms(meta.total_time))
  add(
    'Actual Rows',
    node['Actual Rows']
        and (format_num(node['Actual Rows']) .. ' (loops: ' .. tostring(node['Actual Loops'] or 1) .. ')')
      or nil
  )
  add('Estimated Rows', format_num(node['Plan Rows']))
  add(
    'Startup / Total Cost',
    string.format('%.2f .. %.2f', node['Startup Cost'] or 0, node['Total Cost'] or 0)
  )
  add('Filter', node['Filter'])
  add('Index Cond', node['Index Cond'])
  add('Hash Cond', node['Hash Cond'])
  add('Join Filter', node['Join Filter'])
  add('Recheck Cond', node['Recheck Cond'])
  add(
    'Sort Key',
    type(node['Sort Key']) == 'table' and table.concat(node['Sort Key'], ', ') or node['Sort Key']
  )
  add('Sort Method', node['Sort Method'])
  add(
    'Sort Space Used',
    node['Sort Space Used']
        and (tostring(node['Sort Space Used']) .. ' kB (' .. tostring(node['Sort Space Type'] or '') .. ')')
      or nil
  )
  add('Rows Removed by Filter', node['Rows Removed by Filter'])
  add('Shared Hit Blocks', node['Shared Hit Blocks'])
  add('Shared Read Blocks', node['Shared Read Blocks'])
  add(
    'Temp Read / Written',
    (node['Temp Read Blocks'] or node['Temp Written Blocks'])
        and (tostring(node['Temp Read Blocks'] or 0) .. ' / ' .. tostring(
          node['Temp Written Blocks'] or 0
        ))
      or nil
  )

  if #lines == 0 then
    table.insert(lines, '  No additional operator properties.')
  end

  local width = math.min(82, math.max(48, math.floor(vim.o.columns * 0.7)))
  local height = math.min(#lines, math.max(4, math.floor(vim.o.lines * 0.65)))
  detail_popup = require('sqmeow.ui.popup').open({
    title = title,
    bottom = ' q / <Esc> close ',
    lines = lines,
    width = width,
    height = height,
    filetype = 'sqmeow-explain-detail',
    wrap = true,
    on_close = close_detail,
  })
end

--- The current explain view, if its buffer and window are still valid.
---@return sqmeow.ExplainView|nil
local function shown()
  if
    view
    and vim.api.nvim_buf_is_valid(view.buf)
    and vim.api.nvim_win_is_valid(view.win)
    and vim.api.nvim_win_get_buf(view.win) == view.buf
  then
    return view
  end
  return nil
end

---@param v sqmeow.ExplainView
local function draw(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end

  v.line_to_node = {}
  local lines = {}
  local hls = {}

  local entry = v.entry
  local root = v.root
  local stats = v.stats
  local is_analyze = v.is_analyze
  local root_cost = root['Total Cost'] or 0

  local mode_str = is_analyze and 'ANALYZE + BUFFERS' or 'ESTIMATED (read-safe)'
  local plan_ms = format_ms(entry['Planning Time'])
  local exec_ms = is_analyze and format_ms(entry['Execution Time'])
    or ('cost ' .. string.format('%.1f', root_cost))

  table.insert(
    lines,
    ('  PostgreSQL Execution Plan  ·  %s  ·  %s'):format(v.connection or 'postgres', mode_str)
  )
  table.insert(hls, { row = 0, sc = 0, ec = -1, hl = 'SqmeowExplainTitle' })

  local summary = ('  Plan: %s   Exec: %s   Buffers: %d hit / %d read'):format(
    plan_ms,
    exec_ms,
    stats.shared_hit,
    stats.shared_read
  )
  if stats.seq_scans > 0 then
    summary = summary
      .. ('   ⚠ %d Seq Scan%s'):format(stats.seq_scans, stats.seq_scans == 1 and '' or 's')
  end
  if stats.mismatches > 0 then
    summary = summary
      .. ('   ⚠ %d Est Mismatch%s'):format(stats.mismatches, stats.mismatches == 1 and '' or 'es')
  end
  table.insert(lines, summary)
  table.insert(hls, {
    row = 1,
    sc = 0,
    ec = -1,
    hl = (stats.seq_scans > 0 or stats.mismatches > 0) and 'SqmeowExplainWarn' or 'SqmeowExplainOk',
  })

  local rule_w = math.max(
    60,
    (vim.api.nvim_win_is_valid(v.win) and vim.api.nvim_win_get_width(v.win) or 100) - 4
  )
  table.insert(lines, '  ' .. ('─'):rep(rule_w))
  table.insert(hls, { row = 2, sc = 0, ec = -1, hl = 'SqmeowRule' })
  table.insert(lines, '')

  local function walk(node, prefix, is_last, is_root)
    local meta = node._meta or {}
    local children = node.Plans or {}
    local connector = is_root and '  ' or (prefix .. (is_last and '└─ ' or '├─ '))
    local fold_glyph = (#children > 0) and (meta.collapsed and '▶ ' or '▼ ') or '• '

    local label = node['Node Type'] or 'Operator'
    if node['Relation Name'] then
      label = label .. ' on ' .. node['Relation Name']
    end
    if node['Index Name'] then
      label = label .. ' (' .. node['Index Name'] .. ')'
    end

    local left = connector .. fold_glyph .. label
    local left_target = 52
    local pad_n = math.max(2, left_target - vim.fn.strdisplaywidth(left))

    local bar = cost_bar(meta.pct, 10)
    local pct_str = string.format('%5.1f%%', meta.pct or 0)
    local time_str = is_analyze and string.format('%8s', format_ms(meta.excl_time))
      or string.format('%8.1f', meta.excl_cost or 0)
    local rows_str
    if is_analyze and node['Actual Rows'] ~= nil then
      rows_str = string.format(
        'rows: %-6s (est %s)',
        format_num(node['Actual Rows']),
        format_num(node['Plan Rows'])
      )
    else
      rows_str = string.format('est rows: %s', format_num(node['Plan Rows']))
    end
    local flags_str = (#(meta.flags or {}) > 0) and ('  [' .. table.concat(meta.flags, ', ') .. ']')
      or ''

    local line = left
      .. (' '):rep(pad_n)
      .. bar
      .. ' '
      .. pct_str
      .. '  '
      .. time_str
      .. '  '
      .. rows_str
      .. flags_str
    local row_idx = #lines
    table.insert(lines, line)
    v.line_to_node[row_idx] = node

    local sev_hl = node_severity_hl(meta, node['Node Type'])
    local bar_start = #left + pad_n
    table.insert(hls, { row = row_idx, sc = #connector, ec = #left, hl = sev_hl })
    table.insert(
      hls,
      { row = row_idx, sc = bar_start, ec = bar_start + #bar + 1 + #pct_str, hl = sev_hl }
    )
    if flags_str ~= '' then
      table.insert(
        hls,
        { row = row_idx, sc = #line - #flags_str, ec = #line, hl = 'SqmeowExplainFlag' }
      )
    end

    if not meta.collapsed then
      local child_prefix = is_root and '  ' or (prefix .. (is_last and '   ' or '│  '))
      for index, child in ipairs(children) do
        walk(child, child_prefix, index == #children, false)
      end
    end
  end

  walk(root, '', true, true)

  table.insert(lines, '')
  table.insert(lines, '  ── Query ──')
  table.insert(hls, { row = #lines - 1, sc = 0, ec = -1, hl = 'SqmeowExplainDim' })
  for _, sql_line in ipairs(vim.split(v.sql or '', '\n', { plain = true })) do
    table.insert(lines, '  ' .. sql_line)
    table.insert(hls, { row = #lines - 1, sc = 0, ec = -1, hl = 'SqmeowExplainDim' })
  end

  vim.api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  require('sqmeow.ui.buffer').set_lines(v.buf, lines)

  for _, item in ipairs(hls) do
    local opts = { hl_group = item.hl }
    if item.ec and item.ec ~= -1 then
      opts.end_col = item.ec
    end
    pcall(vim.api.nvim_buf_set_extmark, v.buf, ns, item.row, item.sc, opts)
  end
end

---@param dir integer
local function jump_node(dir)
  local v = shown()
  if not v then
    return
  end
  local rows = vim.tbl_keys(v.line_to_node)
  table.sort(rows)
  if #rows == 0 then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(v.win)[1] - 1
  local target = nil
  if dir > 0 then
    for _, row in ipairs(rows) do
      if row > cur then
        target = row
        break
      end
    end
  else
    for index = #rows, 1, -1 do
      if rows[index] < cur then
        target = rows[index]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(v.win, { target + 1, 0 })
  end
end

---@return table|nil
local function current_node()
  local v = shown()
  if not v then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(v.win)[1] - 1
  return v.line_to_node[cur]
end

--- Close the explain plan window and any open operator details popup.
function M.close()
  close_detail()
  if not view then
    return
  end
  local win = view.win
  local buf = view.buf
  view = nil
  if vim.api.nvim_win_is_valid(win) then
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    else
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

--- Actions bound in the explain plan buffer.
M.actions = {
  next_operator = function()
    jump_node(1)
  end,
  prev_operator = function()
    jump_node(-1)
  end,
  details = function()
    local node = current_node()
    if node then
      show_node_details(node)
    end
  end,
  toggle_fold = function()
    local v = shown()
    local node = current_node()
    if v and node and node.Plans and #node.Plans > 0 and node._meta then
      node._meta.collapsed = not node._meta.collapsed
      local cur = vim.api.nvim_win_get_cursor(v.win)
      draw(v)
      local count = vim.api.nvim_buf_line_count(v.buf)
      pcall(vim.api.nvim_win_set_cursor, v.win, { math.min(cur[1], count), 0 })
    end
  end,
  yank_json = function()
    local v = shown()
    if not v then
      return
    end
    vim.fn.setreg('"', v.raw_json)
    pcall(vim.fn.setreg, '+', v.raw_json)
    notify('copied raw EXPLAIN JSON to clipboard')
  end,
  help = function()
    require('sqmeow.ui.help').open('explain')
  end,
  close = M.close,
}

--- Open or reuse the explain buffer and render a parsed PostgreSQL plan document.
---@param plan_doc table
---@param raw_json string
---@param sql_text string
---@param opts? { is_analyze?: boolean, connection?: string }
---@return boolean rendered
function M.render(plan_doc, raw_json, sql_text, opts)
  opts = opts or {}
  local entry = (type(plan_doc) == 'table' and plan_doc[1]) or plan_doc
  local root = type(entry) == 'table' and entry.Plan or nil
  if not root then
    notify('could not parse EXPLAIN JSON output', vim.log.levels.ERROR)
    return false
  end

  local is_analyze = opts.is_analyze == true
  local root_time = entry['Execution Time'] or root['Actual Total Time'] or 0
  local root_cost = root['Total Cost'] or 0
  local stats = M.enrich(root, root_time, root_cost, is_analyze)

  local existing = shown()
  local buf, win
  if existing then
    buf = existing.buf
    win = existing.win
    vim.api.nvim_set_current_win(win)
  else
    buf = require('sqmeow.ui.buffer').scratch('sqmeow://explain', 'sqmeow-explain')
    vim.cmd.split()
    win = vim.api.nvim_get_current_win()
    local layout = require('sqmeow.ui.layout')
    layout.set_buffer(win, buf, { release = true })
    local wo = vim.wo[win]
    wo.wrap = false
    wo.cursorline = true
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = 'no'
    wo.spell = false
    layout.fixbuf(win)
    require('sqmeow.keymap').apply('explain', buf, M.actions)
    local group = vim.api.nvim_create_augroup('sqmeow.explain', { clear = true })
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = group,
      buffer = buf,
      desc = 'Forget the explain plan view',
      callback = function()
        if view and view.buf == buf then
          close_detail()
          view = nil
        end
      end,
    })
  end

  view = {
    buf = buf,
    win = win,
    entry = entry,
    root = root,
    raw_json = raw_json,
    sql = sql_text,
    is_analyze = is_analyze,
    connection = opts.connection or 'postgres',
    stats = stats,
    line_to_node = {},
  }

  draw(view)
  pcall(vim.api.nvim_win_set_cursor, win, { 5, 0 })
  return true
end

--- Handle an engine `call:state` event. Returns `true` when the call belongs to
--- an internal silent EXPLAIN run so `sqmeow.rpc.events.on_call` does not open
--- the result grid, overwrite `state.call`, or record history.
---@param payload table
---@return boolean handled
function M.on_call(payload)
  if type(payload) ~= 'table' then
    return false
  end
  local call_id = payload.call_id
  if in_flight and (not call_id or not silent_calls[call_id]) then
    local state = require('sqmeow.core.state')
    if not state.call or state.call.call_id ~= call_id then
      table.insert(buffered_events, payload)
      return true
    end
  end

  local pending = call_id and silent_calls[call_id]
  if not pending then
    return false
  end

  if payload.state == 'error' or payload.state == 'cancelled' then
    silent_calls[call_id] = nil
    if active_call_id == call_id then
      active_call_id = nil
    end
    vim.schedule(function()
      notify('explain failed: ' .. tostring(payload.error or payload.state), vim.log.levels.ERROR)
    end)
    return true
  end

  if payload.state == 'done' then
    silent_calls[call_id] = nil
    if active_call_id == call_id then
      active_call_id = nil
    end
    local gen = generation
    vim.schedule(function()
      if gen ~= generation then
        return
      end
      local reply, verr = require('sqmeow.rpc.client').request('rows', {
        call_id = call_id,
        offset = 0,
        limit = 10,
      })
      if gen ~= generation then
        return
      end
      local raw = type(reply) == 'table' and reply.rows and reply.rows[1] and reply.rows[1][1]
        or nil
      if not raw then
        notify('explain returned no plan rows: ' .. tostring(verr or 'empty'), vim.log.levels.ERROR)
        return
      end
      local raw_str = type(raw) == 'table' and vim.json.encode(raw) or tostring(raw)
      local ok_dec, decoded = pcall(vim.json.decode, raw_str)
      if not ok_dec or type(decoded) ~= 'table' then
        notify('failed to decode EXPLAIN JSON output', vim.log.levels.ERROR)
        return
      end
      M.render(decoded, raw_str, pending.sql, {
        is_analyze = pending.is_analyze,
        connection = pending.connection,
      })
    end)
  end

  return true
end

--- Execute a silent EXPLAIN query against `connection` and open the plan viewer.
---@param connection table Active connection from `sqmeow.core.state`.
---@param sql string
---@param opts? { analyze?: boolean }
---@return integer|nil call_id
---@return string|nil err
function M.run(connection, sql, opts)
  local dialect = connection.dialect or ''
  local explain_sql, is_analyze, build_err = M.build_query(dialect, sql, opts)
  if not explain_sql then
    notify(build_err or 'cannot explain query', vim.log.levels.WARN)
    return nil, build_err
  end

  require('sqmeow.rpc.events').ensure()
  local rpc = require('sqmeow.rpc.client')

  in_flight = true
  buffered_events = {}
  local call_id, req_err = rpc.request('execute', {
    conn_id = connection.id,
    sql = explain_sql,
  })
  if call_id then
    active_call_id = call_id
    silent_calls[call_id] = {
      sql = M.strip_explain(sql),
      is_analyze = is_analyze,
      connection = connection.name or dialect,
    }
  end
  in_flight = false

  local replay = buffered_events
  buffered_events = {}

  if not call_id then
    notify(req_err or 'explain query was refused', vim.log.levels.ERROR)
    return nil, req_err
  end

  for _, ev in ipairs(replay) do
    M.on_call(ev)
  end
  return call_id
end

--- The call id of an in-flight silent EXPLAIN run, if any.
---@return integer|nil
function M.active_call_id()
  return active_call_id
end

--- Clear pending silent calls on engine restart or stop.
function M.invalidate()
  generation = generation + 1
  silent_calls = {}
  active_call_id = nil
  in_flight = false
  buffered_events = {}
end

--- The explain view's state, for tests.
---@return sqmeow.ExplainView|nil
function M.state()
  return view
end

return M
