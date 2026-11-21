// The ScyllaDB adapter through the plugin, the engine and a real Apache Cassandra server.

import { it } from 'node:test';
import { assert } from './cases/assert.mjs';
import { scyllaCases } from './cases/scylla_cases.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('cassandra', serverUrl('cassandra'), (ctx) => {
  scyllaCases(ctx);

  it('the server really is cassandra', async () => {
    // ScyllaDB reports 3.0.8 here.
    const result = await ctx.db.run('SELECT release_version FROM system.local');
    const version = result.cells[0][0].value;
    assert.ok(version.startsWith('5'), version);
  });
});
