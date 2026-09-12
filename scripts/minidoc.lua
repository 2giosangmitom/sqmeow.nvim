-- How `doc/sqmeow.txt` is built. Sourced by `MiniDoc.generate()` when it is called with no
-- arguments, which is what `just docs` does.
--
-- The file order here is the section order in the output, so it is decided deliberately rather
-- than left to whatever a directory listing returns. Only the public surface is in it: the
-- modules underneath are free to change shape and have no business in a help file.

local doc = require('mini.doc')

if _G.MiniDoc == nil then
  doc.setup()
end

local input = {
  'lua/sqmeow/init.lua',
  'lua/sqmeow/config.lua',
  'lua/sqmeow/keymap.lua',
  'lua/sqmeow/api.lua',
  'lua/sqmeow/pickers.lua',
  'lua/sqmeow/status.lua',
}

-- The name each file's `M` stands for, so `M.setup()` is tagged `sqmeow.setup()` rather than
-- something no reader could type at a `:help` prompt.
local modules = {
  ['lua/sqmeow/init.lua'] = 'sqmeow',
  ['lua/sqmeow/config.lua'] = 'sqmeow.config',
  ['lua/sqmeow/keymap.lua'] = 'sqmeow.keymap',
  ['lua/sqmeow/api.lua'] = 'sqmeow.api',
  ['lua/sqmeow/pickers.lua'] = 'sqmeow.pickers',
  ['lua/sqmeow/status.lua'] = 'sqmeow.status',
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
---
--- mini.doc infers both from the line after the annotation, which is written as `function M.foo`,
--- so without this every tag in the help file would read `M.foo()`.
hooks.block_pre = function(block)
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
---
--- The default hook runs first, because it is what strips the delimiter lines that would
--- otherwise sit above the title, and the modeline it adds at the end stays as it is.
hooks.write_pre = function(lines)
  lines = doc.default_hooks.write_pre(lines)

  table.insert(lines, 1, '*sqmeow.txt*  A database client for Neovim')
  table.insert(lines, 2, '')
  return lines
end

doc.generate(input, 'doc/sqmeow.txt', { hooks = hooks })
