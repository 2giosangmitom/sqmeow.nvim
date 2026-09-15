--- Generates `doc/sqmeow.txt` from EmmyLua annotations.
---
--- The input order controls the sections in the help file. Each Lua file's
--- `M` is rewritten to its public module name (e.g. `sqmeow.config`) by the
--- `block_pre` hook so tags and signatures read as `sqmeow.xxx`.

local doc = require('mini.doc')

if _G.MiniDoc == nil then
  doc.setup()
end

local input = {
  'lua/sqmeow/init.lua',
  'lua/sqmeow/config.lua',
  'lua/sqmeow/keymap.lua',
  'lua/sqmeow/api.lua',
}

-- The name each file's `M` stands for.
local modules = {
  ['lua/sqmeow/init.lua'] = 'sqmeow',
  ['lua/sqmeow/config.lua'] = 'sqmeow.config',
  ['lua/sqmeow/keymap.lua'] = 'sqmeow.keymap',
  ['lua/sqmeow/api.lua'] = 'sqmeow.api',
}

--- The module a block was parsed out of, or nil when it did not come from a file.
local function module_of(block)
  local path = block.parent and block.parent.info and block.parent.info.path or ''
  for suffix, name in pairs(modules) do
    if path:sub(-#suffix) == suffix then
      return name
    end
  end
  return nil
end

local hooks = vim.deepcopy(doc.default_hooks)

--- Rewrite `M.` into the module's own name, in the tag and in the signature.
hooks.block_pre = function(block)
  local first = block.info.afterlines[1] or ''
  local explicit = block:has_descendant(function(node)
    return type(node) == 'table'
      and node.type == 'section'
      and (node.info.id == '@tag' or node.info.id == '@eval')
  end)
  if first:match('^local ') and not explicit then
    return block:clear_lines()
  end

  local name = module_of(block)
  if name then
    block.info.afterlines = vim.tbl_map(function(line)
      -- Both forms the inference reads: `function M.foo(...)` and a plain `M.foo = ...`.
      local rewritten = line:gsub('^function M%.', 'function ' .. name .. '.')
      return (rewritten:gsub('^M%.', name .. '.'))
    end, block.info.afterlines)
  end

  doc.default_hooks.block_pre(block)
end

--- Put the help file's own tag and title at the very top.
hooks.write_pre = function(lines)
  lines = doc.default_hooks.write_pre(lines)

  table.insert(lines, 1, '*sqmeow.txt*  A database client for Neovim')
  table.insert(lines, 2, '')
  return lines
end

doc.generate(input, 'doc/sqmeow.txt', { hooks = hooks })
