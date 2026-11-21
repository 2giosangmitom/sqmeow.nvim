// Assertions over the plain results `it.run` answers.

import assert from 'node:assert/strict';
import { cell } from '../nvim.mjs';

/** Assert one cell's engine type and text, as the row detail shows it. */
export function cellIs(result, row, column, type, value, message) {
  const found = cell(result, row, column);
  assert.ok(found, `no cell ${row},${column} in ${JSON.stringify(result)}`);
  assert.deepEqual(
    { type: found.type, value: found.value },
    { type, value },
    message ?? `cell ${row},${column}`,
  );
}

/** Assert a cell is NULL. */
export function isNull(result, row, column) {
  cellIs(result, row, column, 'null', null);
}

/** Assert `text` contains `needle`, case-insensitively when asked. */
export function contains(text, needle, { caseless = false } = {}) {
  const haystack = String(text ?? '');
  const ok = caseless
    ? haystack.toLowerCase().includes(needle.toLowerCase())
    : haystack.includes(needle);
  assert.ok(ok, `expected ${JSON.stringify(haystack)} to contain ${JSON.stringify(needle)}`);
}

/** Assert a connection attempt failed with a driver error rather than an unsupported URL. */
export function refusedByDriver(connection) {
  assert.equal(connection.state, 'error', JSON.stringify(connection));
  assert.ok(connection.error, 'the failure should say why');
  assert.ok(
    !connection.error.includes('unsupported database URL'),
    `a known scheme should reach its driver: ${connection.error}`,
  );
}

/** Assert a result has no editable source. */
export function readOnly(result, what = result.sql) {
  assert.equal(result.state, 'done', `${what}: ${result.error}`);
  assert.equal(result.source, undefined, `${what} should not be editable`);
}

export { assert };
