// The Oracle Database adapter through the plugin, the engine and a real server.

import { it } from 'node:test';
import { assert, cellIs, contains, refusedByDriver } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { doubleQuote, relationships } from './cases/relationships.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { sqlSafety } from './cases/sql_safety.mjs';
import { suite } from './cases/suite.mjs';
import { names } from './nvim.mjs';
import { serverUrl } from './servers.mjs';

const PAUSE =
  'create or replace function audit_pause return number as begin dbms_session.sleep(0.3); return 0; end;';
const BLOCK =
  'create or replace function audit_block return number as begin dbms_session.sleep(1); return 0; end;';

suite('oracle', serverUrl('oracle'), (ctx) => {
  sqlCrud(ctx, {
    create: 'create table sqmeow_crud_smoke (id int primary key, name varchar2(32))',
    prepare: true,
  });
  sqlSafety(ctx, {
    create: 'create table sqmeow_rollback_smoke (id int primary key, name varchar2(32))',
    prepare: true,
  });
  nativeBind(ctx, {
    sql: `${HEADER}select :text as first, :text as repeated, :missing as missing from dual`,
    text: "Alice' ; DELETE FROM users -- 日本",
  });
  relationships(ctx, { schema: 'SQMEOW', quote: doubleQuote });
  queryBuffers(ctx, {
    source: "SELECT 'a;b' AS note FROM dual;\nSELECT 2 AS n FROM dual;",
    lines: [0, 1],
    markers: ["'a;b'", '2 AS n'],
    cap: 'select level from dual connect by level <= 2',
    unenforced: true,
  });
  serverSmoke(ctx, { dialect: 'oracle', query: 'select 42 as answer from dual', values: ['42'] });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'oracle');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(await ctx.db.connect('oracle://sqmeow:sqmeow@127.0.0.1:1/FREE', { keep: false }));
  });

  it('selects rows with their columns', async () => {
    const result = await ctx.db.run("select 1 as id, 'alice' as name from dual");
    assert.deepEqual(names(result), ['ID', 'NAME']);
    cellIs(result, 0, 0, 'integer', '1');
    cellIs(result, 0, 1, 'text', 'alice');
  });

  it('routine source preserves ordered body lines', async () => {
    const { db } = ctx;
    const schema = await db.defaultSchema();
    await db.run(
      'CREATE OR REPLACE FUNCTION SQMEOW_SOURCE_FUNC(v NUMBER) RETURN NUMBER AS\nBEGIN\nRETURN v + 17;\nEND;',
    );
    await db.run('CREATE OR REPLACE PROCEDURE SQMEOW_SOURCE_PROC AS\nBEGIN\nNULL;\nEND;');
    const fn = await db.routineSource(schema, 'SQMEOW_SOURCE_FUNC', 'function');
    assert.equal(fn.error, undefined, fn.error);
    assert.ok(fn.source.startsWith('CREATE OR REPLACE FUNCTION'), fn.source);
    contains(fn.source, 'RETURN v + 17;\nEND;');
    contains((await db.routineSource(schema, 'SQMEOW_SOURCE_PROC', 'procedure')).source, 'NULL;\nEND;');
    assert.ok((await db.routineSource(schema, 'SQMEOW_SOURCE_PROC', 'function')).error);
    await db.run('DROP FUNCTION SQMEOW_SOURCE_FUNC');
    await db.run('DROP PROCEDURE SQMEOW_SOURCE_PROC');
  });

  it('cancelled writes queued behind a running query never start', async () => {
    const { db } = ctx;
    await db.run('drop table if exists audit_cancel_regression');
    await db.run('create table audit_cancel_regression (id number)');
    await db.run(BLOCK);
    const held = await db.run('select 1 from dual');
    const submit = [
      async () => {
        const { call_id } = await db.execute('insert into audit_cancel_regression values (1)');
        return { id: call_id, wait: async () => (await db.wait(call_id)).state };
      },
      async () => {
        const { call_id } = await db.execute(
          '-- @param id int\ninsert into audit_cancel_regression values (:id)',
          { parameters: { id: '1' } },
        );
        return { id: call_id, wait: async () => (await db.wait(call_id)).state };
      },
      async () => {
        const handle = await db.applyStart(['insert into audit_cancel_regression values (1)'], held.call_id);
        return { id: held.call_id, wait: async () => (await db.applyWait(handle)).error };
      },
    ];
    for (const queue of submit) {
      const active = await db.execute('select audit_block() from dual');
      await db.sleep(50);
      const queued = await queue();
      await db.cancel(queued.id);
      contains(await queued.wait(), 'cancelled');
      assert.equal((await db.wait(active.call_id)).state, 'done');
      assert.equal((await db.run('select id from audit_cancel_regression')).count, 0);
    }
    await db.run('drop table audit_cancel_regression');
    await db.run('drop function audit_block');
  });

  it('cancelling apply rolls back before commit and reuse', async () => {
    const { db } = ctx;
    await db.run('drop table if exists audit_cancel_apply');
    await db.run('create table audit_cancel_apply (id number)');
    await db.run('insert into audit_cancel_apply values (1)');
    await db.run(PAUSE);
    const held = await db.run('select id from audit_cancel_apply');
    const handle = await db.applyStart(
      ['update audit_cancel_apply set id=2', 'update audit_cancel_apply set id=id + audit_pause()'],
      held.call_id,
    );
    await db.sleep(100);
    await db.cancel(held.call_id);
    contains((await db.applyWait(handle)).error, 'cancelled');
    cellIs(await db.run('select id from audit_cancel_apply'), 0, 0, 'integer', '1');
    await db.run('drop table audit_cancel_apply');
    await db.run('drop function audit_pause');
  });

  it('a cancelled apply rolls back before the next request', async () => {
    const { db } = ctx;
    await db.run('drop table if exists audit_abandoned_apply');
    await db.run('create table audit_abandoned_apply (id number)');
    await db.run('insert into audit_abandoned_apply values (1)');
    await db.run(PAUSE);
    const held = await db.run('select id from audit_abandoned_apply');
    const handle = await db.applyStart(
      ['update audit_abandoned_apply set id=2', 'update audit_abandoned_apply set id=id + audit_pause()'],
      held.call_id,
    );
    await db.sleep(100);
    await db.cancel(held.call_id);
    // Submitted before the apply reports back: it must already see the rollback.
    cellIs(await db.run('select id from audit_abandoned_apply'), 0, 0, 'integer', '1');
    assert.ok((await db.applyWait(handle)).error);
    await db.run('drop table audit_abandoned_apply');
    await db.run('drop function audit_pause');
  });

  it('atomic edits reject a hidden commit before any write', async () => {
    const { db } = ctx;
    await db.run('drop table if exists audit_atomic_guard');
    await db.run('create table audit_atomic_guard (id number)');
    const held = await db.run('select * from audit_atomic_guard');
    const done = await db.apply(['insert into audit_atomic_guard values (1)', 'commit'], held.call_id);
    contains(done.error, 'atomic Oracle edits');
    assert.equal((await db.run('select * from audit_atomic_guard')).count, 0);
    await db.run('drop table audit_atomic_guard');
  });
});
