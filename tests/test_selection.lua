local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local helpers = dofile('tests/helpers.lua')
local api = require('sqmeow.api')

local captured
local original_execute, original_selection
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      captured = nil
      original_execute = helpers.swap(api, 'execute', function(sql, opts)
        captured = { sql = sql, opts = opts }
        return 42
      end)
      original_selection = vim.o.selection
      vim.o.selection = 'inclusive'
    end,
    post_case = function()
      api.execute = original_execute
      vim.cmd('normal! \27')
      vim.o.selection = original_selection
    end,
  },
})

local function buffer(lines)
  local buf = helpers.temp_buf(lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function visual(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'nx', false)
end

T['active selection ignores stale marks'] = function()
  local buf = buffer({ 'SELECT 1;', 'SELECT 2;', 'DELETE FROM important;' })
  vim.api.nvim_buf_set_mark(buf, '<', 3, 0, {})
  vim.api.nvim_buf_set_mark(buf, '>', 3, 20, {})
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  visual('V')
  eq(api.execute_selection(), 42)
  eq(captured.sql, 'SELECT 2;')
  eq(captured.opts.source_buf, buf)
end

T['characterwise exclusive selection excludes its endpoint'] = function()
  buffer({ 'SELECT 1;DELETE FROM important;' })
  vim.o.selection = 'exclusive'
  visual('gg0v9l')
  api.execute_selection()
  eq(captured.sql, 'SELECT 1;')
end

T['blockwise selection never includes unselected SQL'] = function()
  buffer({ 'xxSELECT 1; DROP TABLE a;', 'xxSELECT 2; DROP TABLE b;' })
  visual('gg02l<C-v>8lj')
  api.execute_selection()
  eq(captured.sql, 'SELECT 1;\nSELECT 2;')
end

T['reversed selection preserves multibyte characters'] = function()
  buffer({ 'a猫🐱z' })
  visual('gg0llvh')
  api.execute_selection()
  eq(captured.sql, '猫🐱')
end

T['explicit command ranges ignore stale visual marks'] = function()
  local buf = buffer({ 'DELETE FROM important;', 'SELECT 2;', 'SELECT 3;' })
  vim.api.nvim_buf_set_mark(buf, '<', 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, '>', 1, 20, {})
  require('sqmeow.commands').subcommands.execute.run({}, { range = 2, line1 = 2, line2 = 3 })
  eq(captured.sql, 'SELECT 2;\nSELECT 3;')
end

local queries = {
  sqlite = "SELECT 'a;b';",
  duckdb = "SELECT 'a;b';",
  postgres = 'SELECT $$a;b$$;',
  mysql = "SELECT 'a;b';",
  mssql = 'DECLARE @n int=2;\nSELECT @n;',
  oracle = "SELECT q'[a;b]' FROM dual;",
  clickhouse = "SELECT 'a;b';",
  scylla = 'SELECT * FROM system.local;',
  surrealdb = "RETURN 'a;b';",
  redis = 'ECHO "a;b"',
  mongodb = '{"ping":1}',
}
for dialect, query in pairs(queries) do
  T[dialect .. ' reads unsaved selection and whole buffer'] = function()
    local path = helpers.temp_file({ 'saved stale query' })
    local buf = buffer(vim.split(query, '\n', { plain = true }))
    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].modified = true
    vim.b[buf].sqmeow_connection = dialect
    visual('ggVG')
    api.execute_selection()
    eq(captured.sql, query)
    eq(captured.opts.source_buf, buf)
    api.execute_buffer()
    eq(captured.sql, query)
    eq(vim.fn.readfile(path), { 'saved stale query' })
  end
end

return T
