--- Plugin entry point. Registers `:Sqmeow` and `<Plug>` mappings lazily.
---
--- UI colors are always available; the rest loads on first use.

if vim.g.loaded_sqmeow then
  return
end
vim.g.loaded_sqmeow = true

require('sqmeow.ui.highlights').setup()
require('sqmeow.commands').register()
require('sqmeow.keymap').register_plug()
