--- Configuration defaults and validation.
---
--- Every option has a default, so `setup()` is optional and calling it with a partial table only
--- overrides what it names. Validation runs once, at `setup()`, and names the offending key,
--- because a typo in a nested option is otherwise invisible until the feature it controls
--- misbehaves much later.
---
---@tag sqmeow-config
---@toc_entry Configuration

local M = {}

--- Default configuration.
---
--- This table is the single source of truth. What follows is inlined from it when the help file
--- is built, so the documented defaults cannot drift from the ones the code uses.
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
M.defaults = {
  -- Where connections are loaded from, in order. Later sources do not shadow earlier ones; every
  -- source contributes, and a duplicate name is reported rather than silently dropped.
  -- Types: 'file', 'env'. Connections are never declared here: a URL routinely carries a
  -- password, and this table tends to live in a dotfiles repository. `:Sqmeow add` saves one.
  sources = {
    { type = 'file' },
    { type = 'env' },
  },

  core = {
    -- The directory the plugin keeps its files in: the installed engine, saved connections,
    -- scratchpads, and the query log with the results it shows again.
    path = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow'),
    -- One of 'error', 'warn', 'info', 'debug', 'trace'.
    log_level = 'warn',
  },

  ui = {
    drawer = { width = 36 },
    -- `column_icons` marks each column of the grid header with what it holds, or with the key it
    -- is. Worth turning off in a terminal without a patched font, and in a very wide result where
    -- the columns are better spent on values.
    result = {
      height = 16,
      page_size = 100,
      max_column_width = 48,
      -- Marks each column of the grid header with what it holds, or with the key it is. Worth
      -- turning off in a terminal without a patched font.
      column_icons = true,
      -- What a SQL `NULL` reads as. Distinct from an empty string, which is drawn as nothing.
      null_text = 'NULL',
    },
    -- The border of every dialog. 'default' follows Neovim's own 'winborder'; any nui border
    -- style, such as 'rounded', sets one for this plugin alone.
    border = 'default',
    winbar = true,
    persist_session = false,
  },

  query = {
    -- Rows held per result. Reached, the result is marked truncated rather than failed.
    max_rows = 100000,
    -- Milliseconds before a query is cancelled. 0 disables the timeout.
    timeout_ms = 0,
    -- Results the engine holds in memory, so showing a recent one again reads nothing from disk.
    history_size = 32,
    -- Save the queries you run, and the rows they returned, under `core.path`, so the log and its
    -- results survive a restart. False keeps both to the session.
    persist_history = true,
    -- Queries kept in the log, each with its result. The oldest go once there are twice as many.
    history_limit = 500,
  },

  -- Every character the plugin draws that is not text. The defaults are Nerd Font glyphs, so a
  -- terminal without one needs its own set here. Colours are not set here: redefine the matching
  -- `SqmeowIcon*` highlight group instead.
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

    -- Beside a connection, saying what state it is in. One glyph in four colours: the difference
    -- is `SqmeowConnected`, `SqmeowConnecting`, `SqmeowConnectionError` and `SqmeowDisconnected`,
    -- not the character.
    connected = '●',
    connecting = '●',
    error = '●',
    disconnected = '●',
    ['function'] = '󰊕',
    procedure = '󰡱',
    key = '',

    -- The headings a schema is drawn as, each above the things it holds.
    tables = '󰓫',
    views = '󰈈',
    functions = '󰊕',
    procedures = '󰡱',
    -- A Redis database's groups, one per type of value, all drawn with the same glyph.
    keys = '',

    -- One per dialect, so a drawer holding several of them tells them apart without reading a word.
    postgres = '',
    mysql = '',
    sqlite = '',
    redis = '',

    -- What sits before a drawer row: whether its children are showing, or that it has none.
    markers = { open = '', closed = '', leaf = ' ' },

    -- What the result grid is drawn with: between the columns, along the rule under their names,
    -- where the two meet, and at the end of a value too wide for its column. Keep the three
    -- separators one column wide, or the rule will be out of step with the header above it. The
    -- ellipsis may be any width, since a truncated value is measured with it.
    grid = { vertical = '│', horizontal = '─', cross = '┼', ellipsis = '…' },

    -- What each column of the grid header is marked with, and what the drawer marks its columns
    -- with. The first eight are classes rather than type names: three dialects spell the same
    -- idea five ways between them, and an icon per spelling is a table nobody can read. The two
    -- keys win over the class, because what rows are found by is the more useful thing to know.
    -- Set one to an empty string to draw that kind of column plain.
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

    -- Glyphs for particular type names, overriding the class they would fall in. The escape hatch
    -- for anyone who wants `varchar` to look different from `text`: the classes above are coarse
    -- on purpose, and this is how to disagree with where a line was drawn. Keyed by the database's
    -- own name for the type, in any spelling and with or without its parameters.
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

--- Validate a user configuration against the defaults.
---
---@param opts table Configuration as passed to `setup()`.
---@return string[] # Every problem found, so one call reports them all.
function M.validate(opts)
  local errors = {}
  validate(opts, M.defaults, '', errors)

  table.sort(errors)
  return errors
end

--- Merge a user configuration over the defaults and make it current.
---
---@param opts table|nil Configuration as passed to `setup()`.
---@return table config The merged configuration.
---@return string[] errors Problems found. The configuration is still merged when non-empty.
function M.apply(opts)
  opts = opts or {}
  local errors = M.validate(opts)
  M.current = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  return M.current, errors
end

--- Read the active configuration.
---
---@return table config
function M.get()
  return M.current
end

--- The border style dialogs are drawn with.
---
--- `ui.border`, unless it is 'default', which means Neovim's 'winborder', so a border chosen once
--- for every floating window reaches this plugin's too. nui takes the named styles as they are,
--- but not the custom form, eight characters separated by commas, which it needs as a list.
---
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
