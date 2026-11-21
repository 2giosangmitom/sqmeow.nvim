// The SQLite adapter through the plugin, the engine and a real in-memory database.

import { beforeEach, afterEach, it } from 'node:test';
import { assert, cellIs, contains, readOnly } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { DEFAULT_MAX_ROWS, queryBuffers } from './cases/query_buffers.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { sqlSafety } from './cases/sql_safety.mjs';
import { suite } from './cases/suite.mjs';

const URL = 'sqlite::memory:';

async function seed(db) {
  await db.run('create table people (id integer primary key, name text, score real, avatar blob)');
  await db.run(
    "insert into people (id, name, score, avatar) values (1, 'alice', 9.5, x'deadbeef'), (2, 'bob', 7.0, null), (3, null, null, null)",
  );
}

suite(
  'sqlite',
  URL,
  (ctx) => {
    // Every case gets a database of its own, as each Rust case opened one.
    beforeEach(async () => {
      await ctx.db.open(URL);
    });
    afterEach(async () => {
      await ctx.db.disconnect();
    });

    sqlCrud(ctx, { create: 'create table sqmeow_crud_smoke (id int primary key, name varchar(32))' });
    sqlSafety(ctx, {
      create: 'create table sqmeow_rollback_smoke (id int primary key, name varchar(32))',
    });
    nativeBind(ctx, {
      sql: `${HEADER}select :text, :text, :missing`,
      text: "it's \\ data; ' OR true -- ?1",
    });
    queryBuffers(ctx, {
      source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
      lines: [0, 1],
      markers: ["'a;b'", '2 AS n'],
      cap: 'select 1 union all select 2',
    });

    it('routine source reports unsupported instead of an empty definition', async () => {
      const done = await ctx.db.routineSource('main', 'abs', 'function');
      contains(done.error, 'not supported');
      assert.equal(done.source, undefined);
    });

    it('relationships preserve catalog endpoints', async () => {
      const { db } = ctx;
      await db.run(
        'create table "parent.""table" ("second.key" integer, "first key" integer, primary key ("first key", "second.key"))',
      );
      await db.run(
        'create table "child.""table" (a integer, b integer, c integer, d integer, foreign key (b, a) references "parent.""table", foreign key (c, d) references "parent.""table" ("second.key", "first key"))',
      );
      const outgoing = (await db.relationships('main', 'child."table')).relationships;
      const incoming = (await db.relationships('main', 'parent."table')).relationships;
      assert.deepEqual(outgoing, incoming);
      assert.equal(outgoing.length, 2);
      assert.notEqual(outgoing[0].name, outgoing[1].name);
      for (const key of outgoing) {
        assert.equal(key.source_schema, 'main');
        assert.equal(key.source_relation, 'child."table');
        assert.equal(key.target_schema, 'main');
        assert.equal(key.target_relation, 'parent."table');
      }
      const implicit = outgoing.find((key) => key.columns.join() === 'b,a');
      assert.deepEqual(implicit.referenced, ['first key', 'second.key']);
      const explicit = outgoing.find((key) => key.columns.join() === 'c,d');
      assert.deepEqual(explicit.referenced, ['second.key', 'first key']);
      const unrelated = await db.relationships('main', 'unrelated');
      assert.deepEqual(unrelated.relationships, []);
    });

    it('structure reports partial indexes collations and implicit references', async () => {
      const { db } = ctx;
      await db.run('create table Parent (code text collate nocase primary key)');
      await db.run(
        'create table child (id integer primary key, code text references parent, active integer)',
      );
      await db.run('create unique index child_active on child (code) where active = 1');
      await db.run('create unique index child_code on child (code collate binary)');

      const child = await db.structure('main', 'child');
      assert.equal(child.error, undefined, child.error);
      const partial = child.indexes.find((index) => index.name === 'child_active');
      // A partial unique index still enforces uniqueness among the rows it covers.
      assert.ok(partial.unique && partial.partial);
      assert.deepEqual(partial.columns, ['code']);
      const full = child.indexes.find((index) => index.name === 'child_code');
      assert.ok(full.unique && !full.partial);
      assert.deepEqual(full.collations, ['BINARY']);
      const parent = await db.structure('main', 'Parent');
      assert.deepEqual(parent.indexes[0].collations, ['NOCASE']);

      const [key] = child.foreign_keys;
      assert.equal(key.target, 'parent');
      assert.deepEqual([key.target_schema, key.target_relation], ['main', 'Parent']);
      // `references parent` names no column, so it points at the primary key.
      assert.deepEqual(key.referenced, ['code']);
      const code = child.columns.find((column) => column.name === 'code');
      assert.match(code.references, /\.code$/);
    });

    it('a read-only connection is refused writes', async () => {
      const { db } = ctx;
      await db.open(URL, { read_only: true });
      await db.run('select 1');
      contains(await db.fail('create table t (id integer)'), 'read-only');
    });

    it('grouped or combined rows are read-only', async () => {
      await seed(ctx.db);
      for (const sql of [
        'select id, name from people union all select id, name from people',
        'select name, count(*) from people group by name',
        'select a.*, b.* from people a join people b on b.id = a.id',
      ]) {
        readOnly(await ctx.db.run(sql), sql);
      }
    });

    it('opens an in-memory database with each sqlite scheme', async () => {
      for (const url of ['sqlite::memory:', 'sqlite3::memory:', 'SQLite::memory:', 'FILE::memory:']) {
        const connection = await ctx.db.open(url);
        cellIs(await ctx.db.run('select 42'), 0, 0, 'integer', '42');
        await ctx.db.disconnect(connection.id);
      }
    });

    it('refuses an unknown scheme', async () => {
      const connection = await ctx.db.connect('unknown://localhost/x', { keep: false });
      assert.notEqual(connection.state, 'connected');
      contains(connection.error, 'unsupported database URL');
    });

    it('selects rows with their columns', async () => {
      await seed(ctx.db);
      const result = await ctx.db.run('select id, name from people order by id');
      assert.equal(result.count, 3);
      assert.deepEqual(
        result.columns.map((column) => column.name),
        ['id', 'name'],
      );
      cellIs(result, 0, 0, 'integer', '1');
      cellIs(result, 0, 1, 'text', 'alice');
    });

    it('survives an error and keeps working', async () => {
      await seed(ctx.db);
      for (const [sql, message] of [
        ['select from where', 'syntax'],
        ['select nope from people', 'nope'],
      ]) {
        contains(await ctx.db.fail(sql), message);
        assert.equal((await ctx.db.run('select count(*) from people')).count, 1);
      }
    });

    it('stops at the row cap and says so', async () => {
      await ctx.db.configure({ max_rows: 10 });
      try {
        const result = await ctx.db.run(
          'with recursive n(x) as (select 1 union all select x + 1 from n where x < 1000) select x from n',
        );
        assert.equal(result.count, 10);
        assert.equal(result.truncated, true);
      } finally {
        await ctx.db.configure({ max_rows: DEFAULT_MAX_ROWS });
      }
    });

    it('a select from one table is edited through its primary key', async () => {
      const { db } = ctx;
      await seed(db);
      const result = await db.run(
        'select id, name as who, upper(name) as shout from people order by id',
      );
      assert.equal(result.source?.kind, 'table');
      const [table] = result.source.tables;
      assert.equal(table.name, 'people');
      // The alias is written back to the column it names, and the expression cannot be written.
      assert.deepEqual(
        table.columns.find((entry) => entry.index === 1),
        { index: 1, name: 'name' },
      );
      assert.equal(
        table.columns.find((entry) => entry.index === 2),
        undefined,
      );
      assert.ok(result.columns[1].editable);
      assert.ok(!result.columns[2].editable);

      const edited = await db.edit(result.call_id, {
        updates: [{ row: 0, cells: [{ column: 1, value: "o'ally" }] }],
        deletes: [1],
        inserts: [
          [
            { column: 0, value: '9' },
            { column: 1, value: 'zed' },
          ],
        ],
      });
      assert.equal(edited.error, undefined, edited.error);

      const after = await db.run('select id, name from people order by id');
      assert.deepEqual(
        after.rows.map((row) => row[0]),
        [1, 3, 9],
      );
      cellIs(after, 0, 1, 'text', "o'ally");
      cellIs(after, 2, 1, 'text', 'zed');
    });
  },
  { connect: false },
);
