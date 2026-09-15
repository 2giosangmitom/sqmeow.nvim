--- Plugin entry point. Registers `:Sqmeow` and `<Plug>` mappings lazily.
---
--- Everything else loads on first use, so the plugin costs nothing at startup.

if vim.g.loaded_sqmeow then
  return
end
vim.g.loaded_sqmeow = true

require('sqmeow.commands').register()
require('sqmeow.keymap').register_plug()
