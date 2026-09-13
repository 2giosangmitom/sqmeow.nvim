--- The plugin's highlight groups.
---
--- Every group links to a standard one, so any colourscheme works without knowing this plugin
--- exists, and any group can be overridden without patching the source. No colour is ever
--- hardcoded here: a hex value would be wrong in half the colourschemes people use.

local M = {}

--- Group name to the standard group it follows.
---
--- The `SqmeowIcon*` groups are how a colourscheme reaches the drawer's icons. They are separate
--- from the text beside them on purpose: an icon carries the kind of a thing, and colouring it is
--- most of what makes a tree readable at a glance. The icons themselves are set under `icons` in
--- the configuration; their colours are set here. The expand markers share one group,
--- `SqmeowMarker`, because they say whether a row is open rather than what it holds.
M.links = {
  SqmeowWinbar = 'Title',
  SqmeowHeader = 'Title',
  -- Every line the grid draws itself: the rule under the column names and the separators
  -- between the columns. One group for both, so they cannot end up different colours.
  SqmeowRule = 'WinSeparator',
  SqmeowNull = 'Comment',
  SqmeowNumber = 'Number',
  SqmeowText = 'Normal',
  SqmeowTruncated = 'WarningMsg',
  SqmeowError = 'ErrorMsg',
  SqmeowMarker = 'Comment',

  -- The connection dialog. The edit box follows `Visual` so it reads as the one field being
  -- worked on, whatever the colourscheme.
  SqmeowFormLabel = 'Label',
  SqmeowFormValue = 'Normal',
  SqmeowFormEdit = 'Visual',

  SqmeowIconConnection = 'Directory',
  SqmeowIconSchema = 'Directory',
  SqmeowIconTable = 'Type',
  SqmeowIconView = 'Special',
  SqmeowIconColumn = 'Identifier',
  SqmeowIconScratchpad = 'String',
  SqmeowIconQuery = 'Function',
  SqmeowIconHistory = 'Statement',

  -- The dot beside a connection. Standard diagnostic groups, so it is green and red in every
  -- colourscheme without this plugin naming a colour.
  SqmeowConnected = 'DiagnosticOk',
  SqmeowDisconnected = 'DiagnosticError',
  -- The name of the connection a query runs on when the buffer does not name its own.
  SqmeowActive = 'Title',
  SqmeowIconFunction = 'Function',
  SqmeowIconProcedure = 'Macro',

  -- The glyph before each column name in the result grid, and beside each column in the drawer.
  -- Each follows the group a colourscheme already uses for that kind of value, so a grid of types
  -- reads the way the same types read in a source file. The two keys follow the groups for things
  -- that identify and link, which is what a key does.
  SqmeowIconTypeText = 'String',
  SqmeowIconTypeNumber = 'Number',
  SqmeowIconTypeBoolean = 'Boolean',
  SqmeowIconTypeTemporal = 'Constant',
  SqmeowIconTypeJson = 'Structure',
  SqmeowIconTypeUuid = 'Special',
  SqmeowIconTypeBinary = 'Comment',
  SqmeowIconTypeUnknown = 'Comment',
  SqmeowIconKeyPrimary = 'Identifier',
  SqmeowIconKeyForeign = 'Function',
  SqmeowIconPostgres = 'Constant',
  SqmeowIconMysql = 'Constant',
  SqmeowIconSqlite = 'Constant',
  SqmeowIconRedis = 'Constant',
  SqmeowIconKey = 'Identifier',
}

--- Define the groups, leaving any the user has already defined alone.
function M.setup()
  for group, target in pairs(M.links) do
    -- `default = true` is what makes a user's own definition win, whether it was set before or
    -- after this ran.
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

return M
