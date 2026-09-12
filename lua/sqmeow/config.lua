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
  -- Types: 'file', 'env', 'memory'.
  sources = {
    { type = 'file' },
    { type = 'env' },
  },

  -- Connections declared inline. Equivalent to a `memory` source, and handy for a single database
  -- that does not deserve a file.
  connections = {},

  core = {
    -- Absolute path to the engine binary. `nil` means the managed one.
    path = nil,
    -- Download the engine on first use when it is missing.
    auto_install = true,
    -- One of 'error', 'warn', 'info', 'debug', 'trace'.
    log_level = 'warn',
  },

  ui = {
    -- 'ide' is drawer left, editor top right, result bottom right.
    layout = 'ide',
    drawer = { width = 36, position = 'left' },
    result = { height = 16, page_size = 100, max_column_width = 48 },
    border = 'rounded',
    winbar = true,
    persist_session = false,
  },

  query = {
    -- Rows held per result. Reached, the result is marked truncated rather than failed.
    max_rows = 100000,
    -- Milliseconds before a query is cancelled. 0 disables the timeout.
    timeout_ms = 0,
    -- Results kept for reopening from the call log.
    history_size = 32,
    -- Write finished queries to a file, so the log survives a restart.
    persist_history = true,
    -- Queries kept in the log. The oldest are dropped once there are twice as many.
    history_limit = 500,
    -- Where the log is written. Empty means `stdpath('state')/sqmeow/history.jsonl`.
    history_file = '',
  },

  integrations = {
    -- 'auto' picks the first of telescope, fzf-lua and snacks that is installed.
    picker = 'auto',
    -- Expose the lualine component. Adding it to a statusline stays the user's job.
    lualine = true,
    notify = true,
  },

  -- Every character the plugin draws that is not text. The defaults are Nerd Font glyphs, so a
  -- terminal without one needs its own set here. Colours are not set here: redefine the matching
  -- `SqmeowIcon*` highlight group instead.
  icons = {
    -- The kind of thing a drawer row names.
    connection = '󰆼',
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
    ['function'] = '󰊕',
    procedure = '󰡱',

    -- The headings a schema is drawn as, each above the things it holds.
    tables = '󰓫',
    views = '󰈈',
    functions = '󰊕',
    procedures = '󰡱',

    -- One per dialect, so a drawer holding three of them tells them apart without reading a word.
    postgres = '',
    mysql = '',
    sqlite = '',

    -- What sits before a drawer row: whether its children are showing, or that it has none.
    markers = { open = '', closed = '', leaf = ' ' },

    -- Cycled while a query runs, one frame every 80 milliseconds. Any number of frames works.
    spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },

    -- What the engine draws the result grid with. The three separators are ignored unless they
    -- are exactly one column wide, since a wider one would put the rule out of step with the
    -- header above it. The ellipsis may be any width.
    grid = { vertical = '│', horizontal = '─', cross = '┼', ellipsis = '…' },
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
  ['connections'] = true,
  ['keymaps'] = true,
}

-- Options with no usable default to infer a type from.
local nullable = {
  ['core.path'] = 'string',
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

    if default == nil and not nullable[where] then
      table.insert(errors, ('unknown option `%s`'):format(where))
    elseif freeform[where] then
      if type(value) ~= 'table' then
        table.insert(errors, ('`%s` must be a table, got %s'):format(where, type(value)))
      end
    elseif nullable[where] then
      if type(value) ~= nullable[where] then
        table.insert(
          errors,
          ('`%s` must be a %s, got %s'):format(where, nullable[where], type(value))
        )
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

return M
