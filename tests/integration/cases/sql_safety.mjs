// An apply is one transaction: a failing statement takes the ones before it back.

import { it } from 'node:test';
import { assert, cellIs, contains } from './assert.mjs';

const select = 'select name from sqmeow_rollback_smoke where id = 1';

export async function failedApplyRollsBack(db, create) {
  await db.run(create);
  await db.run("insert into sqmeow_rollback_smoke values (1, 'before')");
  const seen = await db.run(select);
  const failed = await db.apply(
    [
      "update sqmeow_rollback_smoke set name = 'after' where id = 1",
      'insert into sqmeow_rollback_missing values (1)',
    ],
    seen.call_id,
  );
  contains(failed.error, 'sqmeow_rollback_missing', { caseless: true });
  cellIs(await db.run(select), 0, 0, 'text', 'before');

  const reused = await db.apply(
    ["update sqmeow_rollback_smoke set name = 'reused' where id = 1"],
    seen.call_id,
  );
  assert.equal(reused.error, undefined, reused.error);
  cellIs(await db.run(select), 0, 0, 'text', 'reused');
  await db.run('drop table sqmeow_rollback_smoke');
}

/**
 * Register the rollback case.
 * @param {{ create: string, prepare?: boolean }} options
 */
export function sqlSafety(ctx, { create, prepare = false }) {
  it('a failing statement rolls back the ones before it', async () => {
    if (prepare) await ctx.db.query('drop table if exists sqmeow_rollback_smoke');
    await failedApplyRollsBack(ctx.db, create);
  });
}
