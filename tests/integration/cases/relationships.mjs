// Catalog discovery with structured names and three distinct foreign keys, one of them a
// self-reference, read back through `structure` and `relationships`.

import { it } from 'node:test';
import { assert } from './assert.mjs';

const PARENT = 'rel.parent';
const CHILD = 'rel.child';

export async function relationshipFixture(db, schema, quote) {
  const parent = `${quote(schema)}.${quote(PARENT)}`;
  const child = `${quote(schema)}.${quote(CHILD)}`;
  for (const table of [child, parent]) await db.query(`drop table ${table}`);
  const [a, b, c, d, e, f, p, q] = ['a', 'b', 'c', 'd', 'e', 'f', 'p', 'q'].map(quote);
  const self = quote('rel.self');
  const first = quote('rel.first');
  const second = quote('rel.second');
  await db.run(
    `create table ${parent} (${a} integer, ${b} integer, ${p} integer, ${q} integer, primary key (${b}, ${a}), constraint ${self} foreign key (${p}, ${q}) references ${parent} (${b}, ${a}))`,
  );
  await db.run(
    `create table ${child} (${c} integer, ${d} integer, ${e} integer, ${f} integer, constraint ${first} foreign key (${d}, ${c}) references ${parent} (${b}, ${a}), constraint ${second} foreign key (${e}, ${f}) references ${parent} (${b}, ${a}))`,
  );

  const structure = await db.structure(schema, PARENT);
  assert.equal(structure.error, undefined, structure.error);
  assert.ok(structure.columns.some((column) => column.primary_key));

  const outgoing = await db.relationships(schema, CHILD);
  assert.equal(outgoing.error, undefined, outgoing.error);
  const keys = outgoing.relationships;
  assert.equal(keys.length, 2);
  assert.notEqual(keys[0].name, keys[1].name);
  for (const key of keys) {
    assert.equal(key.source_schema, schema);
    assert.equal(key.source_relation, CHILD);
    assert.equal(key.target_schema, schema);
    assert.equal(key.target_relation, PARENT);
  }
  const named = keys.find((key) => key.name === 'rel.first');
  assert.ok(named, JSON.stringify(keys));
  assert.deepEqual(named.columns, ['d', 'c']);
  assert.deepEqual(named.referenced, ['b', 'a']);

  const incoming = (await db.relationships(schema, PARENT)).relationships;
  assert.equal(incoming.length, 3);
  for (const key of keys) assert.ok(incoming.some((other) => deepEqual(other, key)), key.name);
  const selfKeys = incoming.filter((key) => key.source_relation === PARENT);
  assert.equal(selfKeys.length, 1);
  assert.deepEqual(selfKeys[0].columns, ['p', 'q']);
  assert.deepEqual(selfKeys[0].referenced, ['b', 'a']);

  await db.run(`drop table ${child}`);
  await db.run(`drop table ${parent}`);
}

function deepEqual(left, right) {
  try {
    assert.deepEqual(left, right);
    return true;
  } catch {
    return false;
  }
}

/** Double-quoted identifiers, as standard SQL writes them. */
export const doubleQuote = (name) => `"${name.replaceAll('"', '""')}"`;
/** Backtick identifiers, as MySQL writes them. */
export const backtick = (name) => `\`${name.replaceAll('`', '``')}\``;
/** Bracketed identifiers, as T-SQL writes them. */
export const bracket = (name) => `[${name.replaceAll(']', ']]')}]`;

/**
 * Register the relationship case.
 * @param {{ schema?: string, quote: (name: string) => string }} options Without `schema`, the
 *   connection's default schema.
 */
export function relationships(ctx, { schema, quote }) {
  it('relationships preserve catalog endpoints', async () => {
    const named = schema ?? (await ctx.db.defaultSchema());
    assert.ok(named, 'the connection should have a default schema');
    await relationshipFixture(ctx.db, named, quote);
  });
}
