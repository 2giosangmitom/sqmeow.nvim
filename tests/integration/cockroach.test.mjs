// The PostgreSQL adapter through the plugin and the engine against a real CockroachDB server.

import { it } from 'node:test';
import { assert, cellIs } from './cases/assert.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { doubleQuote, relationships } from './cases/relationships.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('cockroach', serverUrl('cockroach'), (ctx) => {
  sqlCrud(ctx, {
    create: 'create table sqmeow_crud_smoke (id int primary key, name varchar(32))',
    prepare: true,
  });
  relationships(ctx, { schema: 'public', quote: doubleQuote });
  queryBuffers(ctx, {
    source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
    lines: [0, 1],
    markers: ["'a;b'", '2 AS n'],
    cap: 'select * from generate_series(1, 2)',
  });
  serverSmoke(ctx, { dialect: 'postgres', query: 'select 42 as answer', values: ['42'] });

  it('the server really is cockroach', async () => {
    assert.equal(ctx.connection.dialect, 'postgres');
    const version = (await ctx.db.run('select version()')).cells[0][0].value;
    assert.ok(version.startsWith('CockroachDB'), version);
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
});
