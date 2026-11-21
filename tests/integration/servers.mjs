// Where each database server the suite needs is listening.
//
// `serverUrl(dialect)` answers `SQMEOW_TEST_<DIALECT>_URL` when it is set, else the URL of the
// compose service when Docker reports it running (Oracle: healthy), else null so the cases skip.

import { execFileSync } from 'node:child_process';
import { root } from './nvim.mjs';

export const SERVERS = {
  mssql: {
    service: 'mssql',
    url: 'mssql://sa:Sqmeow_Test123%21@127.0.0.1:51433/master?trust_server_certificate=true',
  },
  postgres: { service: 'postgres', url: 'postgres://sqmeow:sqmeow@127.0.0.1:55432/sqmeow' },
  mysql: { service: 'mysql', url: 'mysql://root:sqmeow@127.0.0.1:53306/sqmeow' },
  mariadb: { service: 'mariadb', url: 'mysql://root:sqmeow@127.0.0.1:53307/sqmeow' },
  clickhouse: { service: 'clickhouse', url: 'clickhouse://sqmeow:sqmeow@127.0.0.1:58123/default' },
  redis: { service: 'redis', url: 'redis://127.0.0.1:56379/0' },
  dragonfly: { service: 'dragonfly', url: 'redis://127.0.0.1:56380/0' },
  mongodb: { service: 'mongodb', url: 'mongodb://127.0.0.1:57017/sqmeow' },
  scylla: { service: 'scylla', url: 'scylla://127.0.0.1:59042/' },
  cassandra: { service: 'cassandra', url: 'cassandra://127.0.0.1:59043/' },
  surrealdb: { service: 'surrealdb', url: 'surrealdb://root:root@127.0.0.1:58000/sqmeow' },
  oracle: {
    service: 'oracle',
    url: 'oracle://sqmeow:sqmeow@127.0.0.1:51521/FREEPDB1',
    healthy: true,
  },
  cockroach: { service: 'cockroach', url: 'postgres://root@127.0.0.1:56257/defaultdb' },
};

/** The message a skipped dialect reports. */
export const SKIP = 'start it with mise run db:up';

function compose(args) {
  try {
    // `--profile '*'` so services behind a profile, such as mariadb, are found too.
    return execFileSync('docker', ['compose', '--profile', '*', ...args], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    return '';
  }
}

/**
 * The URL to test `dialect` against, or null when no server is there.
 * @param {keyof typeof SERVERS} dialect
 * @returns {string|null}
 */
export function serverUrl(dialect) {
  const override = process.env[`SQMEOW_TEST_${dialect.toUpperCase()}_URL`];
  if (override) return override;
  const server = SERVERS[dialect];
  if (!server) throw new Error(`no server is known for ${dialect}`);
  if (server.healthy) {
    return compose(['ps', server.service]).includes('(healthy)') ? server.url : null;
  }
  return compose(['ps', '--status', 'running', '--quiet', server.service]).trim()
    ? server.url
    : null;
}
