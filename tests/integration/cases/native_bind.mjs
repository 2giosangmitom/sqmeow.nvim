// Query parameters bind natively: injection-like text stays data, a repeated name binds the same
// value, and a typed NULL default stays NULL.

import { it } from 'node:test';
import { assert, cellIs, isNull } from './assert.mjs';

/**
 * Register the native bind case.
 * @param {{ sql: string, text: string }} options `sql` declares `text` and `missing` with
 *   `-- @param` lines (`missing int = NULL`) and selects `:text, :text, :missing`.
 */
export function nativeBind(ctx, { sql, text }) {
  it('bound text repeats and typed null stays null', async () => {
    const result = await ctx.db.run(sql, { parameters: { text } });
    assert.equal(result.count, 1);
    cellIs(result, 0, 0, 'text', text);
    cellIs(result, 0, 1, 'text', text);
    isNull(result, 0, 2);
  });
}

/** The `-- @param` header the native bind cases share. */
export const HEADER = '-- @param text text\n-- @param missing int = NULL\n';
