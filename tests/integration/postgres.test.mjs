// The PostgreSQL adapter through the plugin, the engine and a real server.

import { it } from 'node:test';
import { assert, cellIs, contains, refusedByDriver } from './cases/assert.mjs';
import { HEADER, nativeBind } from './cases/native_bind.mjs';
import { queryBuffers } from './cases/query_buffers.mjs';
import { doubleQuote, relationships } from './cases/relationships.mjs';
import { serverSmoke } from './cases/server_smoke.mjs';
import { sqlCrud } from './cases/sql_crud.mjs';
import { sqlSafety } from './cases/sql_safety.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('postgres', serverUrl('postgres'), (ctx) => {
  sqlCrud(ctx, {
    create: 'create temporary table sqmeow_crud_smoke (id int primary key, name varchar(32))',
  });
  sqlSafety(ctx, {
    create: 'create temporary table sqmeow_rollback_smoke (id int primary key, name varchar(32))',
  });
  nativeBind(ctx, {
    sql: `${HEADER}select cast(:text as text), cast(:text as text), cast(:missing as int)`,
    text: "it's \\ data; ' OR true -- $1 ?",
  });
  relationships(ctx, { schema: 'public', quote: doubleQuote });
  queryBuffers(ctx, {
    source: "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;",
    lines: [0, 1],
    markers: ["'a;b'", '2 AS n'],
    cap: 'select * from generate_series(1, 2)',
  });
  serverSmoke(ctx, { dialect: 'postgres', query: 'select 42 as answer', values: ['42'] });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'postgres');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(await ctx.db.connect('postgres://nobody@127.0.0.1:1/none', { keep: false }));
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

  it('routine source preserves bodies overloads and kind', async () => {
    const { db } = ctx;
    await db.run(
      'create or replace function public.sqmeow_source(v integer) returns integer language sql as $$ select v + 17 $$',
    );
    await db.run(
      "create or replace function public.sqmeow_source(v text) returns text language sql as $$ select v || 'body' $$",
    );
    await db.run(
      "create or replace procedure public.sqmeow_source_proc() language plpgsql as $$ begin raise notice 'procedure body'; end $$",
    );
    const functions = await db.routineSource('public', 'sqmeow_source', 'function');
    assert.equal(functions.error, undefined, functions.error);
    // Overloads come back together, each a definition of its own.
    const definitions = functions.source.split(/\n\n(?=CREATE OR REPLACE FUNCTION)/);
    assert.equal(definitions.length, 2, functions.source);
    assert.ok(definitions.every((sql) => sql.startsWith('CREATE OR REPLACE FUNCTION')));
    assert.ok(definitions.some((sql) => sql.includes('v + 17')));
    assert.ok(definitions.some((sql) => sql.includes("'body'")));
    const procedure = await db.routineSource('public', 'sqmeow_source_proc', 'procedure');
    contains(procedure.source, 'procedure body');
    assert.ok((await db.routineSource('public', 'sqmeow_source_proc', 'function')).error);
    assert.ok((await db.routineSource('public', "sqmeow_source' OR true --", 'function')).error);
    await db.run('drop function public.sqmeow_source(integer), public.sqmeow_source(text)');
    await db.run('drop procedure public.sqmeow_source_proc()');
  });

  it('cancellation after insert preserves success and reuse', async () => {
    const { db } = ctx;
    await db.run('drop table if exists audit_late_cancel');
    await db.run('create table audit_late_cancel (id int)');
    const { call_id } = await db.execute(
      'do $$ begin insert into audit_late_cancel values (1); perform pg_sleep(0.3); end $$',
    );
    await db.sleep(100);
    await db.cancel(call_id);
    const outcome = await db.wait(call_id);
    assert.equal(outcome.state, 'done', `a completed write must keep its success: ${outcome.error}`);
    assert.equal((await db.run('select * from audit_late_cancel')).count, 1);
    await db.run('drop table audit_late_cancel');
  });

  it('read cancellation keeps the connection usable', async () => {
    const { db } = ctx;
    const { call_id } = await db.execute('select pg_sleep(2)');
    await db.sleep(100);
    await db.cancel(call_id);
    assert.equal((await db.wait(call_id)).state, 'cancelled');
    await db.run('select 1');
  });

  it('a read-only connection stays read-only after set_config', async () => {
    const { db } = ctx;
    // A function that writes, so a statement that looks like a read reaches the server.
    await db.run('drop table if exists read_only_target');
    await db.run('create table read_only_target (id int)');
    await db.run(
      'create or replace function read_only_probe() returns int language sql as $$ insert into read_only_target values (1) returning 1 $$',
    );
    const writer = db.conn;
    const reader = await db.open(ctx.url, { read_only: true });
    try {
      await db.run("select set_config('default_transaction_read_only', 'off', false)");
      contains(await db.fail('create table read_only_probe (id int)'), 'read-only');
      // The server, not just the statement check, refuses the write.
      contains(await db.fail('select read_only_probe()'), 'read-only');
    } finally {
      await db.disconnect(reader.id);
      db.conn = writer;
    }
    assert.equal((await db.run('select * from read_only_target')).count, 0);
    await db.run('drop function read_only_probe()');
    await db.run('drop table read_only_target');
  });

  it('a cancelled apply cannot be committed by a later apply', async () => {
    const { db } = ctx;
    const observer = db.conn;
    await db.run('drop table if exists native_aborted_apply');
    await db.run('create table native_aborted_apply (v int)');
    await db.run('insert into native_aborted_apply values (10)');
    const worker = await db.connect(ctx.url, { keep: false });
    const held = await db.run('select 1', { conn_id: worker.id });
    const handle = await db.applyStart(
      ['update native_aborted_apply set v = 11', 'select pg_sleep(2) /* native_aborted_apply */'],
      held.call_id,
      { conn: worker.id },
    );
    let active = false;
    for (let attempt = 0; attempt < 200 && !active; attempt += 1) {
      const seen = await db.run(
        "select count(*)::int8 from pg_stat_activity where state = 'active' and query = 'select pg_sleep(2) /* native_aborted_apply */'",
        { conn_id: observer },
      );
      active = seen.cells[0][0].value === '1';
      if (!active) await db.sleep(10);
    }
    assert.ok(active, 'the first update must have run before the apply is cancelled');
    await db.cancel(held.call_id);
    assert.ok((await db.applyWait(handle, 5000)).error, 'a cancelled apply reports it');
    const reuse = await db.apply(['select 1'], held.call_id, { conn: worker.id, timeout: 5000 });
    cellIs(
      await db.run('select v from native_aborted_apply', { conn_id: observer }),
      0,
      0,
      'integer',
      '10',
      `a later apply must not commit abandoned edits (reuse: ${reuse.error})`,
    );
    await db.disconnect(worker.id);
    await db.run('drop table native_aborted_apply', { conn_id: observer });
  });

  it('fetches a real postgres definition through the drawer editor', async (t) => {
    const { db } = ctx;
    if (!(await db.lua('return it.nui'))) {
      t.skip('needs nui.nvim under .tests; run the UI suite once');
      return;
    }
    const failure = await db.lua(DRAWER_ROUTINES, [ctx.url]);
    assert.equal(failure, null, failure);
  });
});

// Moved from test_drawer_edit.lua: the drawer's edit (e) and inspect (K) actions fetch a routine's
// definition into a bound editor and a read-only popup, without replacing the current result.
const DRAWER_ROUTINES = `
local url = ...
local drawer = require('sqmeow.ui.drawer')
local state = require('sqmeow.core.state')
local connection = it.connect(url, { name = 'routine-edit-smoke' })
local id = connection.id
local opts = { conn_id = id }
local function content()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')
end
local original = drawer.current_node
local ok, err = pcall(function()
  assert(it.run('CREATE OR REPLACE FUNCTION public.sqmeow_editor_body(n integer) RETURNS integer LANGUAGE sql AS $$ SELECT n + 17 $$', opts).state == 'done')
  assert(it.run('CREATE OR REPLACE PROCEDURE public.sqmeow_editor_proc() LANGUAGE plpgsql AS $$ BEGIN NULL; END $$', opts).state == 'done')
  local selected
  drawer.current_node = function()
    return selected
  end
  for _, routine in ipairs({
    { name = 'sqmeow_editor_body', kind = 'function', body = 'SELECT n + 17' },
    { name = 'sqmeow_editor_proc', kind = 'procedure', body = 'BEGIN NULL; END' },
  }) do
    selected = {
      kind = routine.kind,
      name = routine.name,
      conn_id = id,
      path = { 'public', routine.kind == 'function' and 'functions' or 'procedures', routine.name },
    }
    local call_id = state.call.call_id
    drawer.actions.edit()
    it.wait('the routine definition should reach its bound editor', function()
      return vim.api.nvim_buf_get_name(0):find('[Routine: public.' .. routine.name .. ']', 1, true) ~= nil
    end, 5000)
    assert(vim.b.sqmeow_connection == 'routine-edit-smoke', 'the editor is bound to its connection')
    assert(content():find(routine.body, 1, true), 'the editor holds the body')
    assert(state.call.call_id == call_id, 'editing leaves the result alone')
    vim.api.nvim_buf_delete(0, { force = true })
    drawer.actions.structure()
    it.wait('K should inspect the routine definition in a read-only popup', function()
      return vim.api.nvim_win_get_config(0).relative ~= ''
        and vim.bo.modifiable == false
        and content():find(routine.body, 1, true) ~= nil
    end, 5000)
    assert(vim.b.sqmeow_editor == nil, 'the popup is not an editor')
    assert(vim.bo.filetype == 'sql', 'the popup highlights SQL')
    assert(state.call.call_id == call_id, 'inspecting leaves the result alone')
    require('sqmeow.ui.structure').close()
  end
end)
drawer.current_node = original
it.run('DROP FUNCTION IF EXISTS public.sqmeow_editor_body(integer)', opts)
it.run('DROP PROCEDURE IF EXISTS public.sqmeow_editor_proc()', opts)
it.disconnect(id)
if not ok then
  return tostring(err)
end
return vim.NIL
`;
