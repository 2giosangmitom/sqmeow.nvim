// The SurrealDB adapter through the plugin, the engine and a real server.
//
// The suite's connection is the namespace; each case works in a database of its own, opened as a
// connection with `database` set, as the drawer opens one from a namespace.

import { it } from 'node:test';
import { assert, cellIs, contains, isNull, readOnly } from './cases/assert.mjs';
import { HEADER } from './cases/native_bind.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { suite } from './cases/suite.mjs';
import { column } from './nvim.mjs';
import { serverUrl } from './servers.mjs';

const URL = serverUrl('surrealdb');

suite('surrealdb', URL, (ctx) => {
  /** Make an empty database `name` and connect to it; answers a function that closes it. */
  async function fresh(name) {
    const { db } = ctx;
    const namespace = ctx.connection.id;
    await db.run(`REMOVE DATABASE IF EXISTS ${name}; DEFINE DATABASE ${name}`, { conn_id: namespace });
    const connection = await db.open(ctx.url, { database: name });
    return async () => {
      await db.disconnect(connection.id);
      await db.query(`REMOVE DATABASE IF EXISTS ${name}`, { conn_id: namespace });
      db.conn = namespace;
    };
  }

  queryBuffers(ctx, {
    source: "RETURN 'a;b';\nRETURN '日本🐱';",
    lines: [0, 1],
    markers: ["'a;b'", '日本🐱'],
    cap: 'RETURN [1, 2]',
    unenforced: true,
  });
  serverSmoke(ctx, {
    dialect: 'surrealdb',
    url: `${URL}/lua`,
    prepare: 'DEFINE DATABASE IF NOT EXISTS lua',
    query: 'RETURN 42',
    values: ['42'],
  });

  it('routine source reads function body', async () => {
    const close = await fresh('routine_source');
    try {
      const { db } = ctx;
      await db.run('DEFINE FUNCTION fn::sqmeow_source_func($v: int) { RETURN $v + 17; }');
      const done = await db.routineSource('routine_source', 'fn::sqmeow_source_func', 'function');
      assert.equal(done.error, undefined, done.error);
      assert.equal(done.source.split('\n\n').length, 1, done.source);
      contains(done.source, 'DEFINE FUNCTION fn::sqmeow_source_func');
      contains(done.source, '$v + 17');
      assert.ok((await db.routineSource('routine_source', 'fn::missing', 'function')).error);
    } finally {
      await close();
    }
  });

  it('running transaction reports actual commit after cancel', async () => {
    const close = await fresh('cancel_outcome');
    try {
      const { db } = ctx;
      await db.run('DEFINE TABLE probe SCHEMALESS');
      const { call_id } = await db.execute(
        'BEGIN TRANSACTION; CREATE probe:one SET n=1; SLEEP 300ms; COMMIT TRANSACTION;',
      );
      await db.sleep(100);
      await db.cancel(call_id);
      const outcome = await db.wait(call_id);
      assert.equal(outcome.state, 'done', `a committed transaction is not cancelled: ${outcome.error}`);
      assert.equal((await db.run('SELECT * FROM probe')).count, 1);
    } finally {
      await close();
    }
  });

  it('cancelling apply reports the actual commit', async () => {
    const close = await fresh('cancel_apply');
    try {
      const { db } = ctx;
      const held = await db.run('DEFINE TABLE probe SCHEMALESS');
      const handle = await db.applyStart(
        ['CREATE probe:one SET n = { SLEEP 300ms; RETURN 1; }'],
        held.call_id,
      );
      await db.sleep(100);
      await db.cancel(held.call_id);
      const done = await db.applyWait(handle);
      assert.equal(done.error, undefined, `a committed apply is not cancelled: ${done.error}`);
      assert.equal((await db.run('SELECT * FROM probe')).count, 1);
    } finally {
      await close();
    }
  });

  it('a running transaction finishes before the connection is reused', async () => {
    const close = await fresh('abandoned_transaction');
    try {
      const { db } = ctx;
      await db.run('DEFINE TABLE probe SCHEMALESS');
      const running = await db.execute(
        'BEGIN TRANSACTION; CREATE probe:one SET n=1; SLEEP 300ms; COMMIT TRANSACTION;',
      );
      await db.sleep(50);
      // Submitted while the transaction is still sleeping; it must see the committed record.
      assert.equal((await db.run('SELECT * FROM probe')).count, 1);
      assert.equal((await db.wait(running.call_id)).state, 'done');
    } finally {
      await close();
    }
  });

  it('queued cancel never writes or interrupts the active query', async () => {
    const close = await fresh('cancel_queue');
    try {
      const { db } = ctx;
      const held = await db.run('DEFINE TABLE probe SCHEMALESS');
      const active = await db.execute('SLEEP 300ms; RETURN 1');
      await db.sleep(20);
      const submit = [
        async () => {
          const { call_id } = await db.execute('CREATE probe SET n=1');
          return { id: call_id, wait: async () => (await db.wait(call_id)).state };
        },
        async () => {
          const { call_id } = await db.execute('-- @param n int\nCREATE probe SET n=:n', {
            parameters: { n: '1' },
          });
          return { id: call_id, wait: async () => (await db.wait(call_id)).state };
        },
        async () => {
          const handle = await db.applyStart(['CREATE probe SET n=1'], held.call_id);
          return { id: held.call_id, wait: async () => (await db.applyWait(handle)).error };
        },
      ];
      for (const queue of submit) {
        const queued = await queue();
        await db.cancel(queued.id);
        contains(await queued.wait(), 'cancelled');
      }
      const finished = await db.wait(active.call_id);
      assert.equal(finished.state, 'done', finished.error);
      assert.equal((await db.run('SELECT * FROM probe')).count, 0);
    } finally {
      await close();
    }
  });

  it('native parameters repeat without interpolating text', async () => {
    const close = await fresh('bound_text');
    try {
      const { db } = ctx;
      await db.run("CREATE person:alice SET name = 'Alice'");
      const text = "'; DELETE person; RETURN 'injected'; -- :name $other";
      const result = await db.run(`${HEADER}RETURN [:text, :text, :missing]`, {
        parameters: { text },
      });
      assert.equal(result.count, 3);
      cellIs(result, 0, 0, 'text', text);
      cellIs(result, 1, 0, 'text', text);
      isNull(result, 2, 0);
      assert.equal((await db.run('SELECT * FROM person')).count, 1);
    } finally {
      await close();
    }
  });

  it('stale edits roll back and computed results are not editable', async () => {
    const close = await fresh('edit_safety');
    try {
      const { db } = ctx;
      await db.run('CREATE person:alice SET age = 3; CREATE person:bob SET age = 4');
      for (const sql of ['RETURN 1', 'SELECT age FROM person', 'SELECT count() FROM person GROUP ALL']) {
        readOnly(await db.run(sql), sql);
      }
      const result = await db.run('SELECT * FROM person ORDER BY id');
      assert.ok(result.source, 'a whole-record select is editable');
      const changes = {
        updates: [{ row: 0, cells: [{ column: column(result, 'age'), value: '5' }] }],
        deletes: [1],
      };
      await db.run('DELETE person:bob');
      const edited = await db.edit(result.call_id, changes);
      contains(edited.error, 'no record had that id');
      cellIs(await db.run('SELECT age FROM person:alice'), 0, 0, 'integer', '3');
    } finally {
      await close();
    }
  });

  it('commands create read update and delete rows', async () => {
    const close = await fresh('crud_smoke');
    try {
      const { db } = ctx;
      await db.run("CREATE person:alice SET name = 'alice'");
      const selected = await db.run('SELECT name FROM person:alice');
      assert.equal(selected.count, 1);
      cellIs(selected, 0, 0, 'text', 'alice');
      await db.run("UPDATE person:alice SET name = 'bob'");
      cellIs(await db.run('SELECT name FROM person:alice'), 0, 0, 'text', 'bob');
      await db.run('DELETE person:alice');
      assert.equal((await db.run('SELECT * FROM person')).count, 0);
    } finally {
      await close();
    }
  });

  it('connects and lists the databases of its namespace', async () => {
    const close = await fresh('listed');
    try {
      const { db } = ctx;
      assert.equal(ctx.connection.dialect, 'surrealdb');
      const top = await db.introspect([], ctx.connection.id);
      const databases = top.nodes.filter((node) => node.kind === 'database').map((node) => node.name);
      assert.ok(databases.includes('listed'), JSON.stringify(databases));
      const one = await db.connect(ctx.url, { database: 'listed', keep: false });
      assert.equal(one.current_database, 'listed');
      const inside = await db.introspect([], one.id);
      assert.ok(!inside.nodes.some((node) => node.kind === 'database'), 'a database lists no databases');
      await db.disconnect(one.id);
    } finally {
      await close();
    }
  });

  it('a transaction block answers with its last statement', async () => {
    const close = await fresh('blocks');
    try {
      const { db } = ctx;
      const result = await db.run(
        'BEGIN TRANSACTION; CREATE thing:1 SET n = 1; SELECT * FROM thing; COMMIT TRANSACTION',
      );
      assert.equal(result.count, 1);
      assert.ok(await db.fail('SELECT * FROM'));
    } finally {
      await close();
    }
  });
});
