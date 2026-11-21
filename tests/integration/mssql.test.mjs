// SQL Server through the plugin, the engine and a real server.

import { it } from 'node:test';
import { assert, cellIs, contains } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { bracket, relationships } from './cases/relationships.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { sqlSafety } from './cases/sql_safety.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('mssql', serverUrl('mssql'), (ctx) => {
  sqlCrud(ctx, {
    create: 'create table sqmeow_crud_smoke (id int primary key, name varchar(32))',
    prepare: true,
  });
  sqlSafety(ctx, {
    create: 'create table sqmeow_rollback_smoke (id int primary key, name varchar(32))',
    prepare: true,
  });
  nativeBind(ctx, {
    sql: `${HEADER}SELECT :text AS first, :text AS repeated, :missing AS missing`,
    text: "'; DROP TABLE dbo.sqmeow_bound; -- 日本🐱 @P99",
  });
  relationships(ctx, { schema: 'dbo', quote: bracket });
  queryBuffers(ctx, {
    source: "DECLARE @n int=7;\nSELECT @n AS n;\nGO -- next\nSELECT N'a;b' AS note;",
    lines: [0, 3],
    markers: ['@n AS n', "N'a;b'"],
    cap: 'SELECT 1 AS n UNION ALL SELECT 2',
    unenforced: true,
  });
  serverSmoke(ctx, { dialect: 'mssql', query: 'select 42 as answer', values: ['42'] });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'mssql');
  });

  it('selects a literal row', async () => {
    const result = await ctx.db.run('SELECT 1 AS id');
    assert.equal(result.count, 1);
    cellIs(result, 0, 0, 'integer', '1');
  });

  it('reports an error and keeps working', async () => {
    contains(await ctx.db.fail('SELECT nope FROM nowhere'), 'nowhere');
    assert.equal((await ctx.db.run('SELECT 1 AS id')).count, 1);
  });

  it('routine source preserves function and procedure bodies', async () => {
    const { db } = ctx;
    await db.run(
      'CREATE OR ALTER FUNCTION dbo.sqmeow_source_func(@v int) RETURNS int AS BEGIN RETURN @v + 17; END',
    );
    await db.run("CREATE OR ALTER PROCEDURE dbo.sqmeow_source_proc AS SELECT 'procedure body';");
    contains((await db.routineSource('dbo', 'sqmeow_source_func', 'function')).source, 'RETURN @v + 17');
    contains(
      (await db.routineSource('dbo', 'sqmeow_source_proc', 'procedure')).source,
      'procedure body',
    );
    assert.ok((await db.routineSource('dbo', 'sqmeow_source_proc', 'function')).error);
    await db.run('DROP FUNCTION dbo.sqmeow_source_func');
    await db.run('DROP PROCEDURE dbo.sqmeow_source_proc');
  });

  // Moved from test_buffer_execution.lua.
  it('keeps variables within GO batches', async () => {
    const failure = await ctx.db.lua(GO_BATCHES, [ctx.url]);
    assert.equal(failure, null, failure);
  });

  // Moved from test_buffer_execution.lua.
  it('read-only checks filter fragments before execution', async () => {
    const { db } = ctx;
    const writer = db.conn;
    const reader = await db.open(ctx.url, { name: 'mssql_readonly', read_only: true });
    try {
      const refused = await db.execute('SELECT 1 AS n', {
        where: '1=1; DELETE FROM sqmeow_should_never_be_executed',
      });
      assert.equal(refused.call_id, undefined);
      contains(refused.error, 'read-only');
      const result = await db.run('SELECT 1 AS n', { where: 'n=1' });
      assert.ok(result.count > 0);
    } finally {
      await db.disconnect(reader.id);
      db.conn = writer;
    }
  });
});

const GO_BATCHES = `
local url = ...
local query = require('sqmeow.api.query')
local connection = it.connect(url, { name = 'mssql_batches' })
local buf = vim.api.nvim_create_buf(false, true)
local ok, err = pcall(function()
  assert(connection.state == 'connected', connection.error)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'DECLARE @n int = 7;', 'SELECT @n AS n;', 'GO', 'SELECT 99 AS n;' })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local statement = it.wait_call(assert(query.execute_statement()))
  assert(statement.state == 'done', statement.error)
  assert(statement.cells[1][1].value == '7', 'the statement sees the batch variable')
  local whole = it.wait_call(assert(query.execute_buffer()))
  assert(whole.state == 'done', whole.error)
  assert(whole.cells[1][1].value == '7', 'the buffer starts on the first batch')
  assert(#whole.results == 2, 'each batch is a result')
  assert(whole.results[2].cells[1][1].value == '99', 'the second batch runs')
end)
pcall(vim.api.nvim_buf_delete, buf, { force = true })
it.disconnect(connection.id)
if not ok then
  return tostring(err)
end
return vim.NIL
`;
