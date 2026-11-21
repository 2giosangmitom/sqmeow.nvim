// Cases every CQL server must pass. They share one keyspace, and each owns its table.

import { before, it } from 'node:test';
import { assert, cellIs, isNull, refusedByDriver } from './assert.mjs';
import { queryBuffers } from './query_buffers.mjs';
import { serverSmoke } from './server_smoke.mjs';

const KEYSPACE =
  "CREATE KEYSPACE IF NOT EXISTS sqmeow WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}";

async function table(db, name, definition, conn_id) {
  await db.run(`DROP TABLE IF EXISTS sqmeow.${name}`, { conn_id });
  await db.run(`CREATE TABLE sqmeow.${name} (${definition})`, { conn_id });
}

export function scyllaCases(ctx) {
  before(async () => {
    // Creating a keyspace on a fresh server can take a while to agree on its schema.
    await ctx.db.run(KEYSPACE, { timeout: 60000 });
  });

  queryBuffers(ctx, {
    source: 'SELECT cluster_name FROM system.local;\n/* ; */ SELECT cluster_name FROM system.local;',
    lines: [0, 1],
    markers: [null, '/* ; */'],
    cap: 'SELECT keyspace_name FROM system_schema.keyspaces',
    unenforced: true,
  });
  serverSmoke(ctx, { dialect: 'scylla', query: 'select keyspace_name from system_schema.keyspaces' });

  it('native binds preserve text nulls and complete edit keys', async () => {
    const { db } = ctx;
    await table(db, 'bound_smoke', 'pk int, ck int, first text, repeated text, missing int, PRIMARY KEY (pk, ck)');
    const text = "it's \\ data; ' OR true -- :name ?";
    const header = '-- @param pk int\n-- @param ck int\n-- @param text text\n-- @param missing int = NULL\n';
    await db.run(
      `${header}INSERT INTO sqmeow.bound_smoke (pk, ck, first, repeated, missing) VALUES (:pk, :ck, :text, :text, :missing)`,
      { parameters: { pk: '1', ck: '2', text } },
    );
    const result = await db.run(
      '-- @param pk int\n-- @param ck int\nSELECT pk, ck, first, repeated, missing FROM sqmeow.bound_smoke WHERE pk = :pk AND ck = :ck',
      { parameters: { pk: '1', ck: '2' } },
    );
    cellIs(result, 0, 2, 'text', text);
    cellIs(result, 0, 3, 'text', text);
    isNull(result, 0, 4);
    assert.ok(result.source, 'a select naming the whole key is editable');
    assert.equal((await db.run('SELECT pk, first FROM sqmeow.bound_smoke')).source, undefined);
    const structure = await db.structure('sqmeow', 'bound_smoke');
    assert.equal(structure.columns.filter((column) => column.primary_key).length, 2);

    const updated = await db.edit(result.call_id, {
      updates: [{ row: 0, cells: [{ column: 2, value: 'updated' }] }],
    });
    assert.equal(updated.error, undefined, updated.error);
    cellIs(
      await db.run('SELECT first FROM sqmeow.bound_smoke WHERE pk = 1 AND ck = 2'),
      0,
      0,
      'text',
      'updated',
    );
    const duplicate = await db.edit(result.call_id, {
      inserts: [
        [
          { column: 0, value: '1' },
          { column: 1, value: '2' },
        ],
      ],
    });
    assert.ok(duplicate.error, 'inserting an existing key must not silently overwrite it');
    await db.run('DROP TABLE sqmeow.bound_smoke');
  });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'scylla');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(await ctx.db.connect('scylla://127.0.0.1:1/', { keep: false }));
  });

  it('commands create read update and delete rows', async () => {
    const { db } = ctx;
    await table(db, 'typed', 'id int PRIMARY KEY, name text, seen timestamp');
    await db.run(
      "INSERT INTO sqmeow.typed (id, name, seen) VALUES (1, 'alice', '2024-01-02 03:04:05.678+0000')",
    );
    const result = await db.run('SELECT id, name, seen FROM sqmeow.typed');
    assert.equal(result.count, 1);
    cellIs(result, 0, 0, 'integer', '1');
    cellIs(result, 0, 1, 'text', 'alice');
    cellIs(result, 0, 2, 'timestamp', '2024-01-02 03:04:05.678+0000');
    await db.run("UPDATE sqmeow.typed SET name = 'bob' WHERE id = 1");
    cellIs(await db.run('SELECT name FROM sqmeow.typed WHERE id = 1'), 0, 0, 'text', 'bob');
    await db.run('DELETE FROM sqmeow.typed WHERE id = 1');
    assert.equal((await db.run('SELECT * FROM sqmeow.typed')).count, 0);
    await db.run('DROP TABLE sqmeow.typed');
  });

  it('an error keeps the connection', async () => {
    const { db } = ctx;
    assert.ok(await db.fail('SELECT * FROM sqmeow.no_such_table'));
    await db.run('SELECT release_version FROM system.local');
  });

  it('cancel after server write reports partial progress', async () => {
    const { db } = ctx;
    const worker = db.conn;
    const observer = await db.connect(ctx.url, { keep: false });
    await table(db, 'audit_cancel_reply', 'id int PRIMARY KEY');
    const held = await db.run('SELECT id FROM sqmeow.audit_cancel_reply');
    // Enough writes that the cancellation lands between two of them.
    const count = 3000;
    const statements = Array.from(
      { length: count },
      (_, index) => `INSERT INTO sqmeow.audit_cancel_reply (id) VALUES (${index + 1})`,
    );
    const handle = await db.applyStart(statements, held.call_id, { conn: worker });
    let written = false;
    for (let attempt = 0; attempt < 300 && !written; attempt += 1) {
      const seen = await db.run('SELECT id FROM sqmeow.audit_cancel_reply WHERE id = 1', {
        conn_id: observer.id,
      });
      written = seen.count > 0;
      if (!written) await db.sleep(10);
    }
    assert.ok(written, 'the first write must reach the server before cancellation');
    await db.cancel(held.call_id);
    const done = await db.applyWait(handle);
    // Writes already sent cannot be taken back, so the outcome says how far it got.
    assert.ok(done.error, 'a cancelled apply reports it');
    assert.ok(!/^nothing was applied/.test(done.error), done.error);
    const progress = done.error.match(/(\d+) of (\d+)/);
    assert.ok(progress, done.error);
    const [, sent, total] = progress.map(Number);
    assert.equal(total, count);
    assert.ok(sent >= 1 && sent < count, done.error);
    const rows = await db.run('SELECT count(*) FROM sqmeow.audit_cancel_reply', {
      conn_id: observer.id,
    });
    assert.equal(Number(rows.cells[0][0].value), sent, 'no write runs after the one it reports');
    await db.run('DROP TABLE sqmeow.audit_cancel_reply');
    await db.disconnect(observer.id);
  });

}
