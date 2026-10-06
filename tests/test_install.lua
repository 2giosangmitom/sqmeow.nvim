local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local install = require('sqmeow.server.install')

local T = MiniTest.new_set()

T['archive_url points at the requested release and target'] = function()
  for _, target in ipairs({
    { 'x86_64-unknown-linux-musl', 'tar.gz' },
    { 'aarch64-apple-darwin', 'tar.gz' },
    { 'x86_64-pc-windows-msvc', 'zip' },
  }) do
    eq(
      install.archive_url('1.2.3', target[1]),
      ('https://github.com/2giosangmitom/sqmeow.nvim/releases/download/v1.2.3/sqmeow-core-%s.%s'):format(
        target[1],
        target[2]
      )
    )
  end
end

return T
