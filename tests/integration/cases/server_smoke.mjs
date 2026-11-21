// One connection and query per server through the Lua API, reading the row the way the detail
// view does. Moved from the Lua suite's test_servers.lua.

import { it } from 'node:test';
import { assert } from './assert.mjs';

/**
 * Register the smoke case.
 * @param {object} options
 * @param {string} options.dialect What the engine should say it connected to.
 * @param {string} options.query
 * @param {string[]} [options.values] The first cell of each result, when the server's answer is
 *   known.
 * @param {object} [options.connect] Extra connect options.
 * @param {string} [options.prepare] Run first, on its own.
 * @param {string} [options.url] Connect here instead of the suite's URL.
 */
export function serverSmoke(ctx, { dialect, query, values, connect = {}, prepare, url }) {
  it('connects and executes through RPC', async () => {
    const { db } = ctx;
    const previous = db.conn;
    const connection = await db.open(url ?? ctx.url, { name: `smoke-${dialect}`, ...connect });
    try {
      assert.equal(connection.dialect, dialect);
      const current = await db.lua("return require('sqmeow.core.state').current_connection().dialect");
      assert.equal(current, dialect);
      if (prepare) await db.run(prepare);
      const summary = await db.run(query);
      assert.ok(summary.count > 0);
      const results = summary.results ?? [summary];
      const row = await db.request('row', { call_id: summary.call_id, row: 0 });
      assert.ok(row.ok && row.value.length > 0, row.error);
      for (const [index, value] of (values ?? []).entries()) {
        const reply = await db.request('row', { call_id: results[index].call_id, row: 0 });
        assert.equal(reply.value[0].value, value);
      }
    } finally {
      await db.disconnect(connection.id);
      db.conn = previous;
    }
  });
}
