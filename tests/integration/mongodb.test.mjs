// The MongoDB adapter through the plugin, the engine and a real server.

import { it } from 'node:test';
import { assert, cellIs, contains, isNull, refusedByDriver } from './cases/assert.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { suite } from './cases/suite.mjs';
import { column, names } from './nvim.mjs';
import { serverUrl } from './servers.mjs';

function empty(db, collection) {
  return db.run(`{"delete": "${collection}", "deletes": [{"q": {}, "limit": 0}]}`);
}

suite('mongodb', serverUrl('mongodb'), (ctx) => {
  queryBuffers(ctx, {
    source: '// note\n{"ping":1}\n{"ping": 1}',
    lines: [1, 2],
    markers: ['{"ping":1}', '{"ping": 1}'],
    cap: '{"aggregate":1,"pipeline":[{"$documents":[{"note":"a;b"},{"note":"c"}]}],"cursor":{}}',
    unenforced: true,
  });
  serverSmoke(ctx, { dialect: 'mongodb', query: '{"ping": 1}' });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'mongodb');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(
      await ctx.db.connect('mongodb://127.0.0.1:1/x?serverSelectionTimeoutMS=500', { keep: false }),
    );
  });

  it('only a find keeping its ids can be edited', async () => {
    const { db } = ctx;
    await empty(db, 'projected');
    await db.run('{"insert": "projected", "documents": [{"_id": 1, "v": 1}]}');
    const kept = await db.run('{"find": "projected", "projection": {"v": 1}}');
    assert.ok(kept.source, 'a find keeping _id is editable');
    const dropped = await db.run('{"find": "projected", "projection": {"_id": 0}}');
    assert.equal(dropped.source, undefined);
    const elsewhere = await db.run('{"find": "projected_nowhere", "$db": "sqmeow_empty"}');
    assert.equal(elsewhere.source?.kind, 'collection');
    assert.ok(elsewhere.source.name.startsWith('sqmeow_empty.'), elsewhere.source.name);
    const edited = await db.edit(kept.call_id, {
      updates: [{ row: 0, cells: [{ column: column(kept, 'v'), value: '2' }] }],
    });
    assert.equal(edited.error, undefined, edited.error);
    const updated = await db.run('{"find": "projected"}');
    cellIs(updated, 0, column(updated, 'v'), 'integer', '2');
    await db.run('{"drop": "projected"}');
  });

  it('a write the server refuses fails the apply', async () => {
    const { db } = ctx;
    await empty(db, 'refused');
    await db.run('{"insert": "refused", "documents": [{"_id": 1}]}');
    const found = await db.run('{"find": "refused"}');
    const edited = await db.edit(found.call_id, { inserts: [[{ column: 0, value: '1' }]] });
    assert.equal(edited.stage, 'apply', edited.error);
    contains(edited.error, 'E11000');
    await db.run('{"drop": "refused"}');
  });

  it('commands create read update and delete rows', async () => {
    const { db } = ctx;
    await empty(db, 'insert_find');
    const inserted = await db.run(
      '{"insert": "insert_find", "documents": [{"_id": 1, "name": "alice", "tags": ["a"]}, {"_id": 2, "name": "bob", "age": 30}]}',
    );
    assert.equal(inserted.affected, 2);
    const schema = await db.defaultSchema();
    const collections = await db.introspect([schema, 'tables']);
    assert.ok(collections.nodes.some((node) => node.name === 'insert_find'));
    const fields = await db.introspect([schema, 'tables', 'insert_find']);
    assert.ok(fields.nodes.some((node) => node.name === '_id' && node.primary_key));

    const found = await db.run('{"find": "insert_find", "sort": {"_id": 1}}');
    assert.deepEqual(names(found), ['_id', 'name', 'tags', 'age']);
    cellIs(found, 0, 1, 'text', 'alice');
    cellIs(found, 0, 2, 'json', '["a"]');
    isNull(found, 1, 2);
    cellIs(found, 1, 3, 'integer', '30');
    await db.run(
      '{"update": "insert_find", "updates": [{"q": {"_id": 1}, "u": {"$set": {"name": "updated"}}}]}',
    );
    const updated = await db.run('{"find": "insert_find", "filter": {"_id": 1}}');
    cellIs(updated, 0, column(updated, 'name'), 'text', 'updated');
    await empty(db, 'insert_find');
    assert.equal((await db.run('{"find": "insert_find"}')).count, 0);
    await db.run('{"drop": "insert_find"}');
  });

  it('reports an error and keeps working', async () => {
    const { db } = ctx;
    contains(await db.fail('{"nope": 1}'), 'no such command', { caseless: true });
    assert.deepEqual(names(await db.run('{"ping": 1}')), ['ok']);
  });
});
