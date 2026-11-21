// The DuckDB adapter through the plugin, the engine and a real in-memory database.

import { join } from 'node:path';
import { afterEach, beforeEach, it } from 'node:test';
import { assert, cellIs, contains, readOnly } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { DEFAULT_MAX_ROWS, queryBuffers } from './cases/query_buffers.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { sqlSafety } from './cases/sql_safety.mjs';
import { suite } from './cases/suite.mjs';

const URL = 'duckdb::memory:';
// Runs until it is cancelled on one thread.
const ENDLESS = 'SELECT sum(a.i * b.i) FROM range(1000000) AS a(i), range(1000000) AS b(i)';

/** Start `ENDLESS` and wait until the engine reports it running. */
async function occupy(db) {
  const active = await db.execute(ENDLESS);
  assert.ok(active.call_id, active.error);
  await db.sleep(50);
  assert.ok(await db.call('running', active.call_id), 'the blocking query should still run');
  return active.call_id;
}

/** Queue `submit` behind a running query, cancel it, and check it never wrote. */
async function cancelledWrite(db, submit) {
  await db.run('SET threads=1');
  await db.run('CREATE TABLE cancelled_writes(id INTEGER)');
  // Held before the connection is busy: an apply is cancelled through a held result's id.
  const held = await db.run('SELECT 1');
  const active = await occupy(db);
  const queued = await submit(held);
  await db.sleep(20);
  assert.ok((await db.cancel(queued.id)).ok, 'the engine should take the cancellation');
  const outcome = await queued.wait();
  assert.ok(await db.call('running', active), 'cancelling queued work leaves the active query');
  assert.ok((await db.cancel(active)).ok);
  assert.equal((await db.wait(active)).state, 'cancelled');
  const rows = await db.run('SELECT * FROM cancelled_writes');
  assert.equal(rows.count, 0, 'cancelled queued work must never reach SQL');
  return outcome;
}

suite(
  'duckdb',
  URL,
  (ctx) => {
    beforeEach(async () => {
      await ctx.db.open(URL);
    });
    afterEach(async () => {
      await ctx.db.disconnect();
    });

    sqlCrud(ctx, { create: 'create table sqmeow_crud_smoke (id int primary key, name varchar(32))' });
    sqlSafety(ctx, {
      create: 'create table sqmeow_rollback_smoke (id int primary key, name varchar(32))',
    });
    nativeBind(ctx, {
      sql: `${HEADER}select cast(:text as varchar), cast(:text as varchar), cast(:missing as integer)`,
      text: "alice' OR true; DROP TABLE people; -- :name ?",
    });
    queryBuffers(ctx, {
      source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
      lines: [0, 1],
      markers: ["'a;b'", '2 AS n'],
      cap: 'select * from range(2)',
    });

    it('cancelled execute never starts a queued write', async () => {
      const { db } = ctx;
      const outcome = await cancelledWrite(db, async () => {
        const { call_id } = await db.execute('INSERT INTO cancelled_writes VALUES (1)');
        return { id: call_id, wait: () => db.wait(call_id) };
      });
      assert.equal(outcome.state, 'cancelled');
    });

    it('cancelled bound execute never starts a queued write', async () => {
      const { db } = ctx;
      const outcome = await cancelledWrite(db, async () => {
        const { call_id } = await db.execute('-- @param id int\nINSERT INTO cancelled_writes VALUES (:id)', {
          parameters: { id: '1' },
        });
        return { id: call_id, wait: () => db.wait(call_id) };
      });
      assert.equal(outcome.state, 'cancelled');
    });

    it('cancelled apply never starts a queued transaction', async () => {
      const { db } = ctx;
      const outcome = await cancelledWrite(db, async (held) => {
        const handle = await db.applyStart(['INSERT INTO cancelled_writes VALUES (1)'], held.call_id);
        return { id: held.call_id, wait: () => db.applyWait(handle) };
      });
      contains(outcome.error, 'cancelled');
    });

    it('cancelling queued work does not interrupt the active query', async () => {
      const { db } = ctx;
      await db.run('SET threads=1');
      const active = await db.execute('SELECT sum(i) FROM range(300000000) AS t(i)');
      await db.sleep(10);
      const queued = await db.execute('SELECT 2');
      await db.sleep(10);
      assert.ok((await db.cancel(queued.call_id)).ok);
      assert.equal((await db.wait(queued.call_id, 3000)).state, 'cancelled');
      const rows = await db.wait(active.call_id, 10000);
      assert.equal(rows.state, 'done', rows.error);
      assert.equal(rows.count, 1);
    });

    it('cancelling active work keeps the connection usable', async () => {
      const { db } = ctx;
      await db.run('SET threads=1');
      const { call_id } = await db.execute(ENDLESS);
      await db.sleep(20);
      await db.cancel(call_id);
      assert.equal((await db.wait(call_id, 5000)).state, 'cancelled');
      await db.run('SELECT 1');
    });

    it('abandoning apply rolls back before the next request', async () => {
      const { db } = ctx;
      await db.run('SET threads=1');
      await db.run('CREATE TABLE abandoned(id INTEGER); INSERT INTO abandoned VALUES (1)');
      const held = await db.run('SELECT 1');
      const handle = await db.applyStart(['UPDATE abandoned SET id=2', ENDLESS], held.call_id);
      await db.sleep(50);
      await db.cancel(held.call_id);
      contains((await db.applyWait(handle, 5000)).error, 'nothing was applied');
      cellIs(await db.run('SELECT id FROM abandoned', { timeout: 5000 }), 0, 0, 'integer', '1');
    });

    it('relationships preserve catalog endpoints', async () => {
      const { db } = ctx;
      await db.run('create schema "schema.with.dot"');
      await db.run(
        'create table "schema.with.dot"."parent.""table" (a integer, b integer, primary key (b, a))',
      );
      await db.run(
        'create table "schema.with.dot"."child.""table" (c integer, d integer, e integer, f integer, foreign key (d, c) references "schema.with.dot"."parent.""table" (b, a), foreign key (e, f) references "schema.with.dot"."parent.""table" (b, a))',
      );
      const outgoing = (await db.relationships('schema.with.dot', 'child."table')).relationships;
      const incoming = (await db.relationships('schema.with.dot', 'parent."table')).relationships;
      assert.deepEqual(outgoing, incoming);
      assert.equal(outgoing.length, 2);
      const key = outgoing.find((entry) => entry.columns.join() === 'd,c');
      assert.equal(key.source_schema, 'schema.with.dot');
      assert.equal(key.source_relation, 'child."table');
      assert.equal(key.target_schema, 'schema.with.dot');
      assert.equal(key.target_relation, 'parent."table');
      assert.deepEqual(key.referenced, ['b', 'a']);
    });

    it('a read-only file is refused writes by duckdb', async () => {
      const { db } = ctx;
      const url = `duckdb:${join(db.data, `sqmeow-ro-${process.pid}.duckdb`)}`;
      const writer = await db.open(url);
      await db.run('create table t (id integer)');
      await db.disconnect(writer.id);
      // The engine closes the file after answering, so the read-only open may need a moment.
      let reader;
      for (let attempt = 0; attempt < 50; attempt += 1) {
        reader = await db.connect(url, { read_only: true });
        if (reader.state === 'connected') break;
        await db.sleep(100);
      }
      assert.equal(reader.state, 'connected', reader.error);
      await db.run('select * from t');
      contains(await db.fail('insert into t values (1)'), 'read-only');
      await db.disconnect(reader.id);
    });

    it('grouped rows have no editable source', async () => {
      const { db } = ctx;
      await db.run('create table grouped_people (id integer primary key, name varchar)');
      await db.run("insert into grouped_people values (1, 'alice'), (2, 'alice')");
      readOnly(await db.run('select name, count(*) from grouped_people group by name'));
    });

    it('opens an in-memory database', async () => {
      const connection = await ctx.db.open(URL);
      assert.equal(connection.dialect, 'duckdb');
      await ctx.db.disconnect(connection.id);
    });

    it('reads back rows it wrote', async () => {
      const { db } = ctx;
      await db.run('create table people (id integer primary key, name varchar)');
      await db.run("insert into people values (1, 'alice'), (2, 'bob')");
      const result = await db.run('select id, name from people order by id');
      assert.equal(result.count, 2);
      cellIs(result, 0, 0, 'integer', '1');
      cellIs(result, 1, 1, 'text', 'bob');
    });

    it('stops at the row cap and says so', async () => {
      await ctx.db.configure({ max_rows: 10 });
      try {
        const result = await ctx.db.run('select * from range(1000)');
        assert.equal(result.count, 10);
        assert.equal(result.truncated, true);
      } finally {
        await ctx.db.configure({ max_rows: DEFAULT_MAX_ROWS });
      }
    });

    it('reports an error and keeps working', async () => {
      assert.ok(await ctx.db.fail('select from where'));
      assert.equal((await ctx.db.run('select 1')).count, 1);
    });
  },
  { connect: false },
);
