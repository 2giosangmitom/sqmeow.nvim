// The frame every dialect file shares: one Neovim per file, connected before the first case.

import { after, before, describe } from 'node:test';
import { start } from '../nvim.mjs';
import { SKIP } from '../servers.mjs';

/**
 * Describe `dialect`'s cases, skipped when there is no `url` to test against.
 * @param {string} dialect
 * @param {string|null} url
 * @param {(ctx: { db: import('../nvim.mjs').Editor, url: string, connection: object }) => void} body
 * @param {{ connect?: object|false }} options Passed to `connect`, or `false` to leave it to the
 *   cases.
 */
export function suite(dialect, url, body, { connect = {} } = {}) {
  describe(dialect, { skip: url ? false : SKIP }, () => {
    const ctx = { db: null, url, connection: null };
    before(async () => {
      ctx.db = await start();
      if (connect !== false) ctx.connection = await ctx.db.open(url, connect);
    });
    after(async () => {
      await ctx.db?.stop();
    });
    body(ctx);
  });
}
