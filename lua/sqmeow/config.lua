--- Configuration defaults and validation.
---@tag sqmeow-config
---@toc_entry Configuration

local M = {}

--- Default configuration.
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
M.defaults = {
  -- Where connections are loaded from, in order: `file`, `env`, or `command`, which runs `command`
  -- and reads the JSON array of connections it prints.
  sources = {
    { type = 'file' },
    { type = 'env' },
  },

  core = {
    -- The directory the plugin keeps its files in.
    path = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow'),
    -- One of 'error', 'warn', 'info', 'debug', 'trace'.
    log_level = 'warn',
  },

  ui = {
    drawer = { width = 36 },
    result = {
      height = 16,
      page_size = 100,
      max_column_width = 48,
      -- Marks each column of the grid header with what it holds, or with the key it is.
      column_icons = true,
      -- What a SQL `NULL` reads as. Distinct from an empty string, which is drawn as nothing.
      null_text = 'NULL',
    },
    -- The border of every dialog.
    border = 'default',
    winbar = true,
    -- Reopen the saved connections, the current one, and the drawer nodes that were open when
    -- Neovim last quit, the first time the drawer opens.
    persist_session = false,
  },

  query = {
    -- Rows held per result. Reached, the result is marked truncated rather than failed. 0 holds every
    -- row.
    max_rows = 100000,
    -- Milliseconds before a query is cancelled. 0 disables the timeout.
    timeout_ms = 0,
    -- Runs whose results the engine holds in memory. An older one is read back from disk when shown.
    history_size = 32,
    -- Save the queries you run, and the rows they returned, under `core.path`.
    persist_history = true,
    -- Queries kept in the log, each with its result. The oldest go once there are twice as many.
    history_limit = 500,
    -- Ask before a DELETE or UPDATE without WHERE, a DROP, a TRUNCATE, or emptying a database.
    confirm_destructive = true,
  },

  -- Every character the plugin draws that is not text.
  icons = {
    -- The kind of thing a drawer row names.
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
    key = '',
    sequence = '󰎠',
    role = '󰀄',

    -- The headings a schema is drawn as, each above the things it holds.
    tables = '󰓫',
    views = '󰈈',
    functions = '󰊕',
    procedures = '󰡱',
    sequences = '󰎠',
    roles = '󰀄',
    -- A Redis database's groups, one per type of value, all drawn with the same glyph.
    keys = '',

    -- One per dialect, so a drawer holding several of them tells them apart without reading a word.
    postgres = '',
    mysql = '',
    sqlite = '',
    duckdb = '󰇥',
    redis = '',
    mongodb = '',
    scylla = '󰆼',
    surrealdb = '',

    -- What sits before a drawer row: whether its children are showing, or that it has none.
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

-- Options whose shape is the user's to decide, so only "is it a table" is checked.
local freeform = {
  ['sources'] = true,
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
