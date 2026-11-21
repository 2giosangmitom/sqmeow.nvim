// The ClickHouse adapter through the plugin, the engine and a real server.

import { it } from 'node:test';
import { assert, cellIs, contains, readOnly, refusedByDriver } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { DEFAULT_MAX_ROWS, queryBuffers } from './cases/query_buffers.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('clickhouse', serverUrl('clickhouse'), (ctx) => {
  nativeBind(ctx, { sql: `${HEADER}select :text, :text, :missing`, text: "x'; SELECT 99; -- \\ 雪\n" });
  queryBuffers(ctx, {
    source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
    lines: [0, 1],
    markers: ["'a;b'", '2 AS n'],
    cap: 'select number from numbers(2)',
  });
  serverSmoke(ctx, { dialect: 'clickhouse', query: 'select 42 as answer', values: ['42'] });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'clickhouse');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(await ctx.db.connect('clickhouse://127.0.0.1:1', { keep: false }));
  });

  it('routine source reads sql function definition', async () => {
    const { db } = ctx;
    await db.run('CREATE OR REPLACE FUNCTION sqmeow_source_func AS (v) -> v + 17');
    const done = await db.routineSource('default', 'sqmeow_source_func', 'function');
    assert.equal(done.error, undefined, done.error);
    assert.equal(done.source.split('\n\n').length, 1, done.source);
    contains(done.source, 'CREATE FUNCTION');
    contains(done.source, 'v + 17');
    assert.ok((await db.routineSource('default', 'sqmeow_source_func', 'procedure')).error);
    await db.run('DROP FUNCTION sqmeow_source_func');
  });

  it('a read-only connection refuses writes', async () => {
    const { db } = ctx;
    const writer = db.conn;
    const reader = await db.open(ctx.url, { read_only: true });
    try {
      await db.run('select 1');
      contains(await db.fail('create table ro_refused (a Int8) engine = Memory'), 'read-only');
    } finally {
      await db.disconnect(reader.id);
      db.conn = writer;
    }
  });

  it('results are read-only', async () => {
    const result = await ctx.db.run('select 1 as a');
    readOnly(result);
    assert.ok((await ctx.db.apply(['select 1'], result.call_id)).error);
  });

  it('commands create read update and delete rows', async () => {
    const { db } = ctx;
    await db.run('DROP TABLE IF EXISTS sqmeow_crud_smoke');
    await db.run(
      'CREATE TABLE sqmeow_crud_smoke (id Int32, name String) ENGINE = MergeTree ORDER BY id',
    );
    await db.run("INSERT INTO sqmeow_crud_smoke VALUES (1, 'alice')");
    const selected = await db.run('SELECT name FROM sqmeow_crud_smoke WHERE id = 1');
    const schema = await db.defaultSchema();
    const tables = await db.introspect([schema, 'tables']);
    assert.ok(tables.nodes.some((node) => node.name === 'sqmeow_crud_smoke'));
    const columns = await db.introspect([schema, 'tables', 'sqmeow_crud_smoke']);
    assert.equal(columns.nodes.length, 2);
    assert.equal(selected.count, 1);
    cellIs(selected, 0, 0, 'text', 'alice');
    await db.run(
      "ALTER TABLE sqmeow_crud_smoke UPDATE name = 'bob' WHERE id = 1 SETTINGS mutations_sync = 1",
    );
    cellIs(await db.run('SELECT name FROM sqmeow_crud_smoke WHERE id = 1'), 0, 0, 'text', 'bob');
    await db.run('ALTER TABLE sqmeow_crud_smoke DELETE WHERE id = 1 SETTINGS mutations_sync = 1');
    assert.equal((await db.run('SELECT * FROM sqmeow_crud_smoke')).count, 0);
    await db.run('DROP TABLE sqmeow_crud_smoke');
  });

  it('stops at the row cap', async () => {
    await ctx.db.configure({ max_rows: 10 });
    try {
      const result = await ctx.db.run('select number from numbers(100)');
      assert.equal(result.count, 10);
      assert.equal(result.truncated, true);
    } finally {
      await ctx.db.configure({ max_rows: DEFAULT_MAX_ROWS });
    }
  });

  it('reports a server error', async () => {
    contains(await ctx.db.fail('select nope from nowhere'), 'nowhere');
    assert.equal((await ctx.db.run('select 1')).count, 1);
  });
});
