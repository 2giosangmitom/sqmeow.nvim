// The MySQL adapter through the plugin, the engine and a real server.

import { it } from 'node:test';
import { assert, cellIs, contains, refusedByDriver } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { backtick, relationships } from './cases/relationships.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { sqlSafety } from './cases/sql_safety.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('mysql', serverUrl('mysql'), (ctx) => {
  sqlCrud(ctx, {
    create:
      'create table sqmeow_crud_smoke (id int primary key, name varchar(32)) engine = InnoDB',
    prepare: true,
  });
  sqlSafety(ctx, {
    create: 'create temporary table sqmeow_rollback_smoke (id int primary key, name varchar(32))',
  });
  nativeBind(ctx, {
    sql: `${HEADER}select cast(:text as char), cast(:text as char), cast(:missing as signed)`,
    text: "it's \\ data; ' OR true -- $1 ?",
  });
  relationships(ctx, { quote: backtick });
  queryBuffers(ctx, {
    source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
    lines: [0, 1],
    markers: ["'a;b'", '2 AS n'],
    cap: 'select 1 union all select 2',
  });
  serverSmoke(ctx, { dialect: 'mysql', query: 'select 42 as answer', values: ['42'] });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'mysql');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(await ctx.db.connect('mysql://nobody@127.0.0.1:1/none', { keep: false }));
  });

  it('selects rows with their columns', async () => {
    const result = await ctx.db.run("select 1 as id, 'alice' as name");
    assert.deepEqual(
      result.columns.map((column) => column.name),
      ['id', 'name'],
    );
    cellIs(result, 0, 0, 'integer', '1');
    cellIs(result, 0, 1, 'text', 'alice');
  });

  it('routine source preserves function and procedure bodies', async () => {
    const { db } = ctx;
    const schema = await db.defaultSchema();
    await db.run('drop function if exists sqmeow_source_func');
    await db.run('drop procedure if exists sqmeow_source_proc');
    await db.run('create function sqmeow_source_func(v int) returns int deterministic return v + 17');
    await db.run("create procedure sqmeow_source_proc() begin select 'procedure body'; end");
    const fn = await db.routineSource(schema, 'sqmeow_source_func', 'function');
    contains(fn.source, 'FUNCTION');
    contains(fn.source, 'v + 17');
    const procedure = await db.routineSource(schema, 'sqmeow_source_proc', 'procedure');
    contains(procedure.source, 'procedure body');
    assert.ok((await db.routineSource(schema, "sqmeow_source_func`'--", 'function')).error);
    await db.run('drop function sqmeow_source_func');
    await db.run('drop procedure sqmeow_source_proc');
  });

  it('procedure results keep each schema and value', async () => {
    const { db } = ctx;
    await db.run('drop procedure if exists audit_multi_results');
    await db.run(
      'create procedure audit_multi_results() begin select 1 as a; select 2 as b, 3 as c; end',
    );
    const call = await db.run('call audit_multi_results()');
    const tabular = (call.results ?? [call]).filter((result) => result.columns?.length > 0);
    assert.equal(tabular.length, 2);
    assert.equal(tabular[0].columns[0].name, 'a');
    assert.equal(tabular[1].columns[0].name, 'b');
    assert.equal(tabular[1].columns[1].name, 'c');
    cellIs(tabular[1], 0, 1, 'integer', '3');
    await db.run('drop procedure audit_multi_results');
  });

  it('cancellation after insert preserves success and reuse', async () => {
    const { db } = ctx;
    await db.run('drop table if exists audit_late_cancel');
    await db.run('create table audit_late_cancel (id int)');
    await db.run('drop procedure if exists audit_late_write');
    await db.run(
      'create procedure audit_late_write() begin insert into audit_late_cancel values (1); do sleep(0.3); end',
    );
    const { call_id } = await db.execute('call audit_late_write()');
    await db.sleep(100);
    await db.cancel(call_id);
    const outcome = await db.wait(call_id);
    assert.equal(outcome.state, 'done', `a completed write must keep its success: ${outcome.error}`);
    assert.equal((await db.run('select * from audit_late_cancel')).count, 1);
    await db.run('drop procedure audit_late_write');
    await db.run('drop table audit_late_cancel');
  });

  it('read cancellation keeps the connection usable', async () => {
    const { db } = ctx;
    const { call_id } = await db.execute('select sleep(2), 1');
    await db.sleep(100);
    await db.cancel(call_id);
    const outcome = await db.wait(call_id);
    if (outcome.state !== 'cancelled') {
      // MySQL may answer SLEEP's documented interrupted value instead of ER_QUERY_INTERRUPTED.
      assert.equal(outcome.state, 'done', outcome.error);
      cellIs(outcome, 0, 0, 'integer', '1');
      assert.ok(outcome.elapsed_ms < 1000, `${outcome.elapsed_ms} ms`);
    }
    await db.run('select 1');
  });

  it('atomic edits reject a hidden commit before changing rows', async () => {
    const { db } = ctx;
    await db.run('create temporary table guarded_apply (id int primary key, value int)');
    await db.run('insert into guarded_apply values (1, 10)');
    const held = await db.run('select * from guarded_apply');
    const done = await db.apply(['update guarded_apply set value = 20 where id = 1; commit'], held.call_id);
    assert.ok(done.error, 'a hidden commit must be refused');
    cellIs(await db.run('select value from guarded_apply'), 0, 0, 'integer', '10');
    await db.run('drop temporary table guarded_apply');
  });

  it('a cancelled edit batch is not committed on reuse', async () => {
    const { db } = ctx;
    const observer = db.conn;
    await db.run('drop table if exists abandoned_apply');
    await db.run('create table abandoned_apply (id int primary key, value int) engine = InnoDB');
    await db.run('insert into abandoned_apply values (1, 10)');
    const worker = await db.connect(ctx.url, { keep: false });
    const session = await db.run('select cast(connection_id() as signed)', { conn_id: worker.id });
    const id = session.cells[0][0].value;
    const handle = await db.applyStart(
      ['update abandoned_apply set value = 20 where id = 1', 'select sleep(2) /* sqmeow_abandoned_apply */'],
      session.call_id,
      { conn: worker.id },
    );
    let active = false;
    for (let attempt = 0; attempt < 300 && !active; attempt += 1) {
      const seen = await db.run(
        `select count(*) from information_schema.processlist where id = ${id} and info = 'select sleep(2) /* sqmeow_abandoned_apply */'`,
        { conn_id: observer },
      );
      active = seen.cells[0][0].value === '1';
      if (!active) await db.sleep(10);
    }
    assert.ok(active, 'the update must reach the server before the apply is cancelled');
    await db.cancel(session.call_id);
    assert.ok((await db.applyWait(handle, 5000)).error, 'a cancelled apply reports it');
    const reuse = await db.apply(['update abandoned_apply set value = 30 where id = 1'], session.call_id, {
      conn: worker.id,
    });
    await db.disconnect(worker.id);
    // A locking read waits for the cancelled transaction to release its row lock.
    const rows = await db.run('select value from abandoned_apply where id = 1 for update', {
      conn_id: observer,
      timeout: 5000,
    });
    const value = rows.cells[0][0].value;
    assert.notEqual(value, '20', 'cancelled edits must remain uncommitted');
    assert.equal(value, reuse.error ? '10' : '30', `reuse: ${reuse.error}`);
    await db.run('drop table abandoned_apply', { conn_id: observer });
  });

  it('a read-only connection is refused writes by the server', async () => {
    const { db } = ctx;
    await db.run('drop table if exists read_only_target');
    await db.run('create table read_only_target (id int)');
    await db.run('drop function if exists read_only_probe');
    await db.run(
      'create function read_only_probe() returns int deterministic modifies sql data begin insert into read_only_target values (1); return 1; end',
    );
    const writer = db.conn;
    const reader = await db.open(ctx.url, { read_only: true });
    try {
      await db.run('select 1');
      contains(await db.fail('create table read_only_probe (id int)'), 'read-only');
      // A read the statement check lets through is still refused by the session.
      contains(await db.fail('select read_only_probe()'), 'READ ONLY');
    } finally {
      await db.disconnect(reader.id);
      db.conn = writer;
    }
    await db.run('drop function read_only_probe');
    await db.run('drop table read_only_target');
  });
});
