// A CRUD round trip every SQL dialect must pass, through queries and through staged edits.

import { it } from 'node:test';
import { assert, cellIs } from './assert.mjs';

const select = 'select name from sqmeow_crud_smoke where id = 1';
const editable = 'select id, name from sqmeow_crud_smoke where id = 1';

function update(value) {
  return { updates: [{ row: 0, cells: [{ column: 1, value }] }] };
}

/** Create, read, update and delete rows, then edit one through a plan, and refuse a stale edit. */
export async function crudRoundTrip(db, create) {
  await db.run(create);
  await db.run("insert into sqmeow_crud_smoke (id, name) values (1, 'alice')");
  const selected = await db.run(select);
  assert.equal(selected.count, 1);
  cellIs(selected, 0, 0, 'text', 'alice');

  await db.run("update sqmeow_crud_smoke set name = 'bob' where id = 1");
  cellIs(await db.run(select), 0, 0, 'text', 'bob');

  const result = await db.run(editable);
  assert.equal(result.source?.kind, 'table', 'a select from one table is editable');
  assert.equal(result.source.tables.length, 1);
  assert.ok(result.columns[1].editable, 'the name column can be written back');
  const planned = await db.plan(result.call_id, update('planned'));
  assert.ok(planned.ok, planned.error);
  // Edits locate rows by their primary key, not by the values they show.
  const statement = planned.value.join('\n');
  assert.match(statement, /where[\s\S]*\bid\b/i, statement);
  assert.ok(!statement.includes("'bob'"), `edits must locate rows by their primary key: ${statement}`);
  const applied = await db.apply(planned.value, result.call_id);
  assert.equal(applied.error, undefined, applied.error);
  cellIs(await db.run(select), 0, 0, 'text', 'planned');

  const refreshed = await db.run(editable);
  const stale = await db.plan(refreshed.call_id, update('missing'));
  assert.ok(stale.ok, stale.error);
  await db.run('delete from sqmeow_crud_smoke where id = 1');
  assert.equal((await db.run('select * from sqmeow_crud_smoke')).count, 0);
  const late = await db.apply(stale.value, refreshed.call_id);
  assert.ok(late.error, 'a stale edit must not silently succeed after its row was deleted');
  await db.run('drop table sqmeow_crud_smoke');
}

/**
 * Register the CRUD case.
 * @param {{ db: import('../nvim.mjs').Editor }} ctx
 * @param {{ create: string, prepare?: boolean }} options `prepare` drops a leftover table first.
 */
export function sqlCrud(ctx, { create, prepare = false }) {
  it('commands create read update and delete rows', async () => {
    if (prepare) await ctx.db.query('drop table if exists sqmeow_crud_smoke');
    await crudRoundTrip(ctx.db, create);
  });
}
