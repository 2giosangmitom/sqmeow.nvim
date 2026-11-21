local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.start({ '-u', 'NONE' })
      child.lua('vim.opt.rtp:append(...)', { vim.uv.cwd() })
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local function expect_highlights()
  local links = require('sqmeow.ui.highlights').links
  for group, target in pairs(links) do
    eq(child.lua_get('vim.api.nvim_get_hl(0, { name = ..., link = true }).link', { group }), target)
  end
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "SqmeowDeletedText" }).strikethrough'), true)
  eq(
    child.lua_get('vim.api.nvim_get_hl(0, { name = "SqmeowIconQuery", link = false }).fg ~= nil'),
    true
  )
end

T['plugin load defines colors without setup or a plugin manager'] = function()
  child.cmd('runtime plugin/sqmeow.lua')
  expect_highlights()
end

T['colorscheme changes restore colors without setup'] = function()
  child.cmd('runtime plugin/sqmeow.lua')
  child.cmd('colorscheme default')
  expect_highlights()
end

T['user highlights survive initialization and repeated setup'] = function()
  child.lua('vim.api.nvim_set_hl(0, "SqmeowIconQuery", { fg = "#123456" })')
  child.cmd('runtime plugin/sqmeow.lua')
  child.lua('require("sqmeow").setup(); require("sqmeow").setup()')
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "SqmeowIconQuery" }).fg'), 0x123456)
  eq(child.lua_get('#vim.api.nvim_get_autocmds({ group = "sqmeow.highlights" })'), 1)
end

return T
