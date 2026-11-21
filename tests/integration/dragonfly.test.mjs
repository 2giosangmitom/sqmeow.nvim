// The Redis adapter through the plugin, the engine and a real Dragonfly server.

import { it } from 'node:test';
import { contains } from './cases/assert.mjs';
import { redisCases } from './cases/redis_cases.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('dragonfly', serverUrl('dragonfly'), (ctx) => {
  redisCases(ctx);

  it('the server really is dragonfly', async () => {
    // Otherwise a URL pointed at a Redis server would pass every case above and prove nothing.
    const info = await ctx.db.run('INFO server');
    contains(info.cells[0]?.[0]?.value, 'dragonfly_version');
  });
});
