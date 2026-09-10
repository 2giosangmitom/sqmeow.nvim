--- The plugin's highlight groups.
---
--- Every group links to a standard one, so any colourscheme works without knowing this plugin
--- exists, and any group can be overridden without patching the source. No colour is ever
--- hardcoded here: a hex value would be wrong in half the colourschemes people use.

local M = {}

--- Group name to the standard group it follows.
M.links = {
  SqmeowWinbar = 'Title',
  SqmeowHeader = 'Title',
  SqmeowRule = 'WinSeparator',
  SqmeowNull = 'Comment',
  SqmeowNumber = 'Number',
  SqmeowText = 'Normal',
  SqmeowTruncated = 'WarningMsg',
  SqmeowError = 'ErrorMsg',
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
