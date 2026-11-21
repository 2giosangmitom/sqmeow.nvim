// MySQL-protocol compatibility on an actual MariaDB server, through the plugin and the engine.

import { it } from 'node:test';
import { assert, cellIs } from './cases/assert.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { backtick, relationships } from './cases/relationships.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('mariadb', serverUrl('mariadb'), (ctx) => {
  sqlCrud(ctx, {
    create:
      'create table sqmeow_crud_smoke (id int primary key, name varchar(32)) engine = InnoDB',
    prepare: true,
  });
  relationships(ctx, { quote: backtick });
  queryBuffers(ctx, {
    source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
    lines: [0, 1],
    markers: ["'a;b'", '2 AS n'],
    cap: 'select 1 union all select 2',
  });
  serverSmoke(ctx, { dialect: 'mysql', query: 'select 42 as answer', values: ['42'] });

  it('selects rows with their columns', async () => {
    assert.equal(ctx.connection.dialect, 'mysql');
    const result = await ctx.db.run("select 1 as id, 'alice' as name");
    assert.deepEqual(
      result.columns.map((column) => column.name),
      ['id', 'name'],
    );
    cellIs(result, 0, 0, 'integer', '1');
    cellIs(result, 0, 1, 'text', 'alice');
  });
});
