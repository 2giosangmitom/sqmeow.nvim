--- The plugin's highlight groups.

local M = {}

--- Group name to the standard group it follows.
M.links = {
  SqmeowWinbar = 'Title',
  SqmeowHeader = 'Title',
  -- Every line the grid draws itself.
  SqmeowRule = 'WinSeparator',
  SqmeowNull = 'Comment',
  SqmeowNumber = 'Number',
  SqmeowText = 'Normal',
  SqmeowTruncated = 'WarningMsg',
  SqmeowError = 'ErrorMsg',
  SqmeowMarker = 'Comment',

  -- The connection dialog.
  SqmeowFormLabel = 'Label',
  SqmeowFormValue = 'Normal',
  SqmeowFormEdit = 'Visual',

  -- Staged edits in the result float.
  SqmeowChanged = 'DiffChange',
  SqmeowDeleted = 'DiffDelete',
  SqmeowInserted = 'DiffAdd',

  -- The row detail: a column's name, then its type.
  SqmeowDetailName = 'Identifier',
  SqmeowDetailType = 'Type',

  SqmeowIconConnection = 'Directory',
  SqmeowIconSchema = 'Directory',
  SqmeowIconTable = 'Type',
  SqmeowIconView = 'Special',
  SqmeowIconColumn = 'Identifier',
  SqmeowIconScratchpad = 'String',
  SqmeowIconElapsed = 'Special',
  SqmeowIconQuery = 'Function',
  SqmeowIconHistory = 'Statement',

  -- The dot beside a connection.
  SqmeowConnected = 'DiagnosticOk',
  SqmeowConnecting = 'DiagnosticWarn',
  SqmeowConnectionError = 'Error',
  SqmeowDisconnected = 'Normal',
  SqmeowIconFunction = 'Function',
  SqmeowIconProcedure = 'Macro',

  -- The glyph before each column name in the result grid, and beside each column in the drawer.
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
  SqmeowIconDuckdb = 'Constant',
  SqmeowIconRedis = 'Constant',
  SqmeowIconMongodb = 'String',
  SqmeowIconScylla = 'Constant',
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
