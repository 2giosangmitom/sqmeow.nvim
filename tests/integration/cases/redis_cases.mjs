// Cases every Redis-protocol server must pass.

import { it } from 'node:test';
import { assert, cellIs, contains, refusedByDriver } from './assert.mjs';
import { queryBuffers } from './query_buffers.mjs';
import { serverSmoke } from './server_smoke.mjs';

export function redisCases(ctx) {
  queryBuffers(ctx, {
    source: '# note\nECHO "a;b"\nECHO "日本🐱"',
    lines: [1, 2],
    markers: ['a;b', '日本🐱'],
    unenforced: true,
  });
  serverSmoke(ctx, {
    dialect: 'redis',
    query: 'SET test:lua:visits 41\nINCR test:lua:visits',
    values: ['OK', '42'],
  });

  it('connects and reports its dialect', () => {
    assert.equal(ctx.connection.dialect, 'redis');
  });

  it('refuses a server that is not there', async () => {
    refusedByDriver(await ctx.db.connect('redis://127.0.0.1:1/0', { keep: false }));
  });

  it('commands create read update and delete rows', async () => {
    const { db } = ctx;
    await db.run('SET test:string "hello world"');
    cellIs(await db.run('GET test:string'), 0, 0, 'text', 'hello world');
    const structure = await db.structure('db0', 'test:string');
    assert.equal(structure.error, undefined, structure.error);
    assert.ok(
      structure.properties.some(([name, value]) => name === 'type' && value === 'string'),
      JSON.stringify(structure.properties),
    );
    await db.run('SET test:string updated');
    cellIs(await db.run('GET test:string'), 0, 0, 'text', 'updated');
    await db.run('DEL test:string');
    cellIs(await db.run('EXISTS test:string'), 0, 0, 'integer', '0');
  });

  it('cancelling a blocked command stops it', async () => {
    const { db } = ctx;
    await db.run('DEL test:never');
    const { call_id } = await db.execute('BLPOP test:never 2');
    await db.sleep(50);
    await db.cancel(call_id);
    assert.equal((await db.wait(call_id, 3000)).state, 'cancelled', 'blocked command must answer cancellation');
    cellIs(await db.run('PING'), 0, 0, 'text', 'PONG');
  });

  it('reports an error and keeps working', async () => {
    const { db } = ctx;
    contains(await db.fail('NOPE'), 'unknown command', { caseless: true });
    cellIs(await db.run('PING'), 0, 0, 'text', 'PONG');
  });
}
