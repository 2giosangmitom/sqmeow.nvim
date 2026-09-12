--- The telescope entry point.
---
--- Registers the same pickers under `:Telescope sqmeow ...`, because that is where a telescope
--- user looks for them. Each one is the same function `require('sqmeow.pickers')` exposes, so
--- there is nothing here that can drift: this file is a set of names, not a second implementation.
---
--- >vim
---   :Telescope sqmeow relations
--- <

local ok, telescope = pcall(require, 'telescope')
if not ok then
  error('sqmeow: this extension needs telescope.nvim')
end

local function forward(name)
  return function(opts)
    require('sqmeow.pickers').open(name, opts)
  end
end

return telescope.register_extension({
  exports = {
    -- `:Telescope sqmeow` with no picker named asks which one.
    sqmeow = forward(nil),
    connections = forward('connections'),
    relations = forward('relations'),
    history = forward('history'),
    scratchpads = forward('scratchpads'),
    columns = forward('columns'),
  },
})
