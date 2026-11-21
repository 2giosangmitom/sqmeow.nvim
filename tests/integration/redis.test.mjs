// The Redis adapter through the plugin, the engine and a real Redis server.

import { redisCases } from './cases/redis_cases.mjs';
import { suite } from './cases/suite.mjs';
import { serverUrl } from './servers.mjs';

suite('redis', serverUrl('redis'), (ctx) => {
  redisCases(ctx);
});
