--- The WHERE and ORDER BY bar docked above the result grid.

local M = {}

local utils = require('sqmeow.utils')

local NAMESPACE = vim.api.nvim_create_namespace('sqmeow.filter')

--- The label drawn before each line, padded to one width, by what the bar takes.
local LABELS = {
  sql = { 'WHERE    ', 'ORDER BY ' },
  mongodb = { 'FILTER   ', 'SORT     ' },
}

--- The query operators completion offers for MongoDB.
local OPERATORS = {
  '$and',
  '$or',
  '$nor',
  '$not',
  '$eq',
  '$ne',
  '$gt',
  '$gte',
  '$lt',
  '$lte',
  '$in',
  '$nin',
  '$exists',
  '$regex',
}

--- Words completion offers after the column names.
local KEYWORDS = {
  'AND',
  'OR',
  'NOT',
  'IN',
  'IS',
  'NULL',
  'LIKE',
  'BETWEEN',
  'ASC',
  'DESC',
  'NULLS FIRST',
  'NULLS LAST',
}

--- How many past filters each connection keeps.
local RECENT_LIMIT = 50

---@type table|nil
local bar = nil
--- The grid the bar sits on: its window, its height before the bar, and its connection.
---@type { win: integer, height: integer|nil, conn_id: integer }|nil
local grid = nil
--- Filters applied before, newest first, by connection id, each `{ where, order_by }`.
local recent = {}
--- The labels and completion words of the bar that is open, which follow its database.
local labels, words = LABELS.sql, nil

--- What the bar opened with, and which recent filter it shows instead, 0 for none.
local opened, recalled = { '', '' }, 0

--- Put a WHERE and an ORDER BY in the bar, under their labels.
local function show(bufnr, where, order_by)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { where, order_by })
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  for number, label in ipairs(labels) do
    vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, number - 1, 0, {
      virt_text = { { label, 'SqmeowHeader' } },
      virt_text_pos = 'inline',
      -- Text typed at the start of the line goes after the label.
      right_gravity = false,
    })
  end
end

local function remember(conn_id, where, order_by)
  if where == '' and order_by == '' then
    return
  end
  local list = vim.tbl_filter(function(entry)
    return entry[1] ~= where or entry[2] ~= order_by
  end, recent[conn_id] or {})
  table.insert(list, 1, { where, order_by })
  recent[conn_id] = vim.list_slice(list, 1, RECENT_LIMIT)
end

--- Show an older filter for a positive step, a newer one for a negative step.
local function recall(step)
  if not (bar and grid) then
    return
  end
  local list = recent[grid.conn_id] or {}
  local at = recalled + step
  if at < 0 or at > #list then
    return
  end
  recalled = at
  local entry = at == 0 and opened or list[at]
  show(bar.bufnr, entry[1], entry[2])
end

--- Whether the bar is open.
---@return boolean
function M.is_open()
  return bar ~= nil
end

--- Close the bar without filtering.
function M.close()
  if not bar then
    return
  end
  local closing, under = bar, grid
  bar, grid = nil, nil
  local focused = vim.api.nvim_get_current_win() == closing.winid
  if focused then
    vim.cmd.stopinsert()
  end
  closing:unmount()

  if under and vim.api.nvim_win_is_valid(under.win) then
    if under.height then
      pcall(vim.api.nvim_win_set_height, under.win, under.height)
    end
    if focused then
      vim.api.nvim_set_current_win(under.win)
    end
  end
end

--- Run the result's query again with what the bar holds.
function M.apply()
  if not (bar and grid) then
    return
  end
  -- Accepts a completion rather than filtering with half a word.
  if vim.fn.pumvisible() == 1 then
    return vim.api.nvim_feedkeys(vim.keycode('<C-y>'), 'n', false)
  end

  local lines = vim.api.nvim_buf_get_lines(bar.bufnr, 0, 2, false)
  local where, order_by = vim.trim(lines[1] or ''), vim.trim(lines[2] or '')
  local conn_id = grid.conn_id
  if require('sqmeow.ui.result').filter(where, order_by) then
    remember(conn_id, where, order_by)
    M.close()
  end
end

--- Column names and keywords, as an `omnifunc`.
---@param findstart integer
---@param base string
---@return integer|table
function M.complete(findstart, base)
  if findstart == 1 then
    local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col('.') - 1)
    return #before - #before:match('[%w_$]*$')
  end

  local result = require('sqmeow.ui.result')
  local call = require('sqmeow.state').call
  local prefix = base:lower()
  local items = {}
  local names = call and result.filter_names(call) or {}
  for index, column in ipairs(call and call.columns or {}) do
    local name = names[index]
    if vim.startswith(name:lower(), prefix) then
      -- A JSON key is always quoted.
      local bare = words == nil and name:match('^[%l_][%l%d_]*$') ~= nil
      table.insert(items, {
        word = bare and name or result.quote(name),
        abbr = name,
        menu = column.type_name,
        kind = 'c',
      })
    end
  end
  if prefix ~= '' then
    for _, keyword in ipairs(words or KEYWORDS) do
      if vim.startswith(keyword:lower(), prefix) then
        table.insert(items, { word = keyword, kind = 'k' })
      end
    end
  end
  return items
end

--- Actions the bar's keys are bound to.
M.actions = {
  apply = M.apply,
  close = M.close,
  older = function()
    recall(1)
  end,
  newer = function()
    recall(-1)
  end,
}

--- Open the bar above the result grid, with the cursor on one of its lines.
---@param line integer 1 for WHERE, 2 for ORDER BY.
function M.open(line)
  local result = require('sqmeow.ui.result')
  local call = require('sqmeow.state').call
  local win = result.window()
  if not (call and call.call_id and win) then
    return utils.notify('there is no result to filter', vim.log.levels.WARN)
  end
  if not result.filterable(call) then
    return utils.notify(
      'a MongoDB result is filtered in its query, and its connection is closed',
      vim.log.levels.WARN
    )
  end
  local mongodb = result.dialect(call) == 'mongodb'
  labels, words = mongodb and LABELS.mongodb or LABELS.sql, mongodb and OPERATORS or nil
  if bar then
    vim.api.nvim_set_current_win(bar.winid)
    return vim.api.nvim_win_set_cursor(bar.winid, { line, 0 })
  end

  local nui, err = utils.nui({ 'split', 'popup' }, 'the filter bar')
  if not nui then
    return utils.notify(err, vim.log.levels.ERROR)
  end

  local options = {
    enter = true,
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'wipe',
      swapfile = false,
      filetype = 'sqmeow-filter',
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = 'no',
      wrap = false,
      winfixheight = true,
      winbar = '',
    },
  }
  grid = { win = win, conn_id = call.conn_id }
  if result.is_float() then
    bar = nui.Popup(vim.tbl_extend('force', options, {
      relative = { type = 'win', winid = win },
      position = { row = 0, col = 0 },
      size = { width = vim.api.nvim_win_get_width(win), height = 2 },
      zindex = 50,
    }))
  else
    grid.height = vim.api.nvim_win_get_height(win)
    bar = nui.Split(vim.tbl_extend('force', options, {
      relative = { type = 'win', winid = win },
      position = 'top',
      size = 2,
    }))
  end
  bar:mount()

  local spec = result.spec()
  opened, recalled = { spec.where or '', spec.order_by or '' }, 0
  show(bar.bufnr, opened[1], opened[2])
  -- Highlighted as its language without being a buffer a language server would attach to.
  local language = mongodb and 'json' or 'sql'
  if not pcall(vim.treesitter.start, bar.bufnr, language) then
    vim.bo[bar.bufnr].syntax = language
  end
  vim.bo[bar.bufnr].omnifunc = "v:lua.require'sqmeow.ui.filter'.complete"

  require('sqmeow.keymap').apply('filter', bar.bufnr, M.actions)
  bar:on('BufLeave', M.close, { once = true })

  vim.api.nvim_win_set_cursor(bar.winid, { line, #opened[line] })
  vim.cmd.startinsert({ bang = true })
end

return M
