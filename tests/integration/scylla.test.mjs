// The ScyllaDB adapter through the plugin, the engine and a real ScyllaDB server.

import { it } from 'node:test';
import { scyllaCases } from './cases/scylla_cases.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('scylla', serverUrl('scylla'), (ctx) => {
  scyllaCases(ctx);

  it('the server really is scylla', async () => {
    // Only ScyllaDB has this table.
    await ctx.db.run('SELECT version FROM system.versions');
  });
});
