// Buffer statement boundaries through every backend: a whole buffer runs each statement, a line
// picks the one it sits in, and the row cap holds per request.

import { it } from 'node:test';
import { assert, contains } from './assert.mjs';

/** `query.max_rows` as the plugin ships it. */
export const DEFAULT_MAX_ROWS = 100000;

/**
 * Register the buffer boundary case.
 * @param {object} options
 * @param {string} options.source Two statements whose separators hide in strings or comments.
 * @param {number[]} options.lines The zero-based line each statement starts on.
 * @param {(string|null)[]} options.markers Text only the matching statement holds; null when a
 *   statement's text is all inside another's, so only the others' markers are checked.
 * @param {string} [options.cap] A query of at least two rows, read with a one-row cap.
 * @param {boolean} [options.unenforced] The server has no read-only sessions, which a read-only
 *   connection must say.
 * @param {object} [options.connect] Extra connect options for the read-only connection.
 */
export function queryBuffers(ctx, { source, lines, markers, cap, unenforced = false, connect = {} }) {
  it('buffer statements keep their boundaries', async () => {
    const { db } = ctx;
    const whole = await db.run(source);
    const results = whole.results ?? [whole];
    assert.equal(results.length, lines.length, JSON.stringify(results.map((r) => r.sql)));
    for (const result of results) {
      assert.equal(result.state, 'done', result.error);
      assert.ok(result.count > 0, `${result.sql} should return rows`);
    }
    for (const [index, line] of lines.entries()) {
      const one = await db.run(source, { line });
      assert.equal(one.results, undefined, `line ${line} picks one statement`);
      assert.ok(one.count > 0, `${one.sql} should return rows`);
      if (markers[index]) contains(one.sql, markers[index]);
      for (const other of markers.filter((marker, at) => marker && at !== index)) {
        assert.ok(!one.sql.includes(other), `line ${line} ran ${one.sql}`);
      }
    }
    if (cap) {
      await db.configure({ max_rows: 1 });
      try {
        const capped = await db.run(cap);
        assert.equal(capped.count, 1);
        assert.equal(capped.truncated, true);
        // A prior request's cap must not leak into the next one's text.
        const next = await db.run(source, { line: lines[0] });
        if (markers[0]) contains(next.sql, markers[0]);
        assert.equal(next.results, undefined);
      } finally {
        await db.configure({ max_rows: DEFAULT_MAX_ROWS });
      }
    }
    if (unenforced) {
      const guarded = await db.connect(ctx.url, { ...connect, read_only: true, keep: false });
      assert.equal(guarded.state, 'connected', guarded.error);
      contains(guarded.notice, 'no read-only sessions');
      await db.disconnect(guarded.id);
    }
  });
}
