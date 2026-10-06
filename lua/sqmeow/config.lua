--- Configuration defaults and validation.
---
--- Pass only the options you want to change to |sqmeow.setup()|. Each setup
--- starts from the defaults and discards the previous setup call's options.
--- Nested option tables are merged. See |sqmeow-sources| for connection discovery
--- and |sqmeow-keymaps| for mappings.
---
--- Limits include `query.max_rows` (retained rows),
--- `ui.result.page_size` (displayed rows per page), and `query.timeout_ms`
--- (execution deadline). A zero row limit is unlimited; a zero timeout is off.
--- `query.history_size` is in-memory retention, while `query.history_limit`
--- controls the visible persistent log. See |sqmeow-history| for storage paths.
---@tag sqmeow-config
---@toc_entry Configuration

local M = {}

--- Default configuration. Pass only changed fields to setup. Icons control display glyphs.
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
M.defaults = {
  core = {
    -- The directory the plugin keeps its files in.
    path = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow'),
    -- One of 'error', 'warn', 'info', 'debug', 'trace'.
    log_level = 'warn',
  },

  ui = {
    drawer = {
      -- Where the drawer is anchored: 'left' or 'right'.
      position = 'left',
      width = 36,
    },
    result = {
      height = 16,
      page_size = 100,
      max_column_width = 48,
      -- Show type and key icons in column headers.
      column_icons = true,
      -- What a SQL `NULL` reads as. Distinct from an empty string, which is drawn as nothing.
      null_text = 'NULL',
      -- Pin column header when scrolling down past the first visible lines.
      sticky_header = true,
      -- Display active column name and type in the winbar.
      winbar_column_info = true,
    },
    -- The border of every dialog.
    border = 'default',
    winbar = true,
    -- Reopen the saved connections, the current one, and the drawer nodes that were open when
    -- Neovim last quit, the first time the drawer opens.
    persist_session = false,
  },

  query = {
    -- Maximum retained rows per result. Results exceeding the cap are truncated. 0 keeps all rows.
    max_rows = 100000,
    -- Milliseconds before a query is cancelled. 0 disables the timeout.
    timeout_ms = 0,
    -- Query results kept in memory. Older archived results are loaded from disk when reopened.
    history_size = 32,
    -- Save the queries you run, and the rows they returned, under `core.path`.
    persist_history = true,
    -- Queries shown in the log. Prune the oldest entries when storage exceeds twice this limit.
    history_limit = 500,
    -- Ask before a DELETE or UPDATE without WHERE, a DROP, a TRUNCATE, or emptying a database.
    confirm_destructive = true,
  },

  -- Every character the plugin draws that is not text.
  icons = {
    -- Drawer node icons.
    connection = '󰆼',
    database = '󰆼',
    schema = '󰙅',
    table = '󰓫',
    view = '󰈈',
    ['materialized view'] = '󰈈',
    relation = '󰓫',
    column = '󰠵',
    scratchpads = '󰉋',
    scratchpad = '󰈙',
    query = '󰐊',
    history = '󰋚',
    -- Before how long a query took, in the result's winbar. An empty string leaves it out.
    elapsed = '󱎫',

    -- Beside a connection, saying what state it is in.
    connected = '●',
    connecting = '●',
    error = '●',
    disconnected = '●',
    ['function'] = '󰊕',
    procedure = '󰡱',
    package = '󰏓',
    key = '',
    sequence = '󰎠',
    role = '󰀄',

    -- Schema section icons.
    tables = '󰓫',
    views = '󰈈',
    functions = '󰊕',
    procedures = '󰡱',
    packages = '󰏓',
    sequences = '󰎠',
    roles = '󰀄',
    -- A Redis database's groups, one per type of value, all drawn with the same glyph.
    keys = '',

    -- Database dialect icons.
    postgres = '',
    mysql = '',
    sqlite = '',
    duckdb = '󰇥',
    redis = '',
    mongodb = '',
    scylla = '󰆼',
    surrealdb = '',
    clickhouse = '',
    oracle = '',
    mssql = '',

    -- Tree expansion markers. Leaves have no children.
    markers = { open = '', closed = '', leaf = ' ' },

    -- What the result grid is drawn with.
    grid = { vertical = '│', horizontal = '─', cross = '┼', ellipsis = '…' },

    -- Before a result row with staged changes. Each is one column wide.
    edit = { changed = '~', deleted = '-', added = '+' },

    -- Column type and key icons, in the grid header and the drawer.
    types = {
      text = '󰀬',
      number = '󰎠',
      boolean = '󰔡',
      temporal = '󰃭',
      json = '󰘦',
      uuid = '󰯮',
      binary = '󰈔',
      unknown = '󰠵',
      primary_key = '󰌆',
      foreign_key = '󰌋',
    },

    -- Glyphs for particular type names, overriding the class they would fall in.
    type_names = {},
  },

  -- Merged by action name over the built-in mappings. Set an action to `false` to drop it.
  keymaps = {},

  -- Mask the password in every URL the plugin displays.
  redact_urls = true,
}
--minidoc_afterlines_end

--- The active configuration. Replaced wholesale by `setup()`.
M.current = vim.deepcopy(M.defaults)

-- User-defined mappings: validate the table type, not its keys.
local freeform = {
  ['keymaps'] = true,
  -- Keyed by whatever the database calls its types, so the keys cannot be known in advance.
  ['icons.type_names'] = true,
}

local function join(path, key)
  return path == '' and key or (path .. '.' .. key)
end

local function validate(user, defaults, path, errors)
  if type(user) ~= 'table' then
    table.insert(errors, ('`%s` must be a table, got %s'):format(path, type(user)))
    return
  end

  for key, value in pairs(user) do
    local where = join(path, key)
    local default = defaults[key]

    if default == nil then
      table.insert(errors, ('unknown option `%s`'):format(where))
    elseif freeform[where] then
      if type(value) ~= 'table' then
        table.insert(errors, ('`%s` must be a table, got %s'):format(where, type(value)))
      end
    elseif type(default) == 'table' and not vim.islist(default) then
      validate(value, default, where, errors)
    elseif type(value) ~= type(default) then
      table.insert(errors, ('`%s` must be a %s, got %s'):format(where, type(default), type(value)))
    elseif where == 'ui.drawer.position' and value ~= 'left' and value ~= 'right' then
      table.insert(errors, "`ui.drawer.position` must be 'left' or 'right'")
    end
  end
end

--- Validates a user configuration against the defaults.
---@param opts table Configuration as passed to `setup()`.
---@return string[] # Every problem found, so one call reports them all.
function M.validate(opts)
  local errors = {}
  validate(opts, M.defaults, '', errors)

  table.sort(errors)
  return errors
end

--- Merges a user configuration over the defaults and makes it current.
---@param opts table|nil Configuration as passed to `setup()`.
---@return table config The merged configuration.
---@return string[] errors Problems found.
function M.apply(opts)
  opts = opts or {}
  local errors = M.validate(opts)
  M.current = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  return M.current, errors
end

--- Returns the active configuration.
---@return table config
function M.get()
  return M.current
end

--- Returns the border style dialogs are drawn with.
---@return string|string[] style
function M.border()
  local style = M.get().ui.border
  if style ~= 'default' then
    return style
  end

  local winborder = vim.fn.exists('+winborder') == 1 and vim.o.winborder or ''
  if winborder == '' then
    return 'default'
  end
  if winborder:find(',', 1, true) then
    return vim.split(winborder, ',', { plain = true })
  end
  return winborder
end

return M
