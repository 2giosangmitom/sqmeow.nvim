// One headless Neovim per test file, running the plugin from this checkout and driven through the
// official Node client. The Lua side lives in init.lua and helpers.lua (`require('integration')`).

import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { attach } from 'neovim';

const here = dirname(fileURLToPath(import.meta.url));
export const root = join(here, '..', '..');

// The client logs every message through winston and patches console by default. Keep the test
// output to what node:test prints.
const silent = { level: 'error', info() {}, warn() {}, error() {}, debug() {} };

/** Milliseconds a single helper may wait inside Neovim before it fails the case. */
export const TIMEOUT = 30000;

/**
 * Start Neovim with the plugin loaded and an isolated data directory.
 * @returns {Promise<Editor>}
 */
export async function start() {
  const data = mkdtempSync(join(tmpdir(), 'sqmeow-it-'));
  const proc = spawn(
    'nvim',
    ['--headless', '--embed', '--clean', '-n', '-u', join(here, 'init.lua')],
    { cwd: data, env: { ...process.env, SQMEOW_IT_DATA: data }, stdio: ['pipe', 'pipe', 'pipe'] },
  );
  let stderr = '';
  proc.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  const nvim = attach({ proc, options: { logger: silent } });
  try {
    // Fails if init.lua did not finish, which would otherwise surface as a confusing nil later.
    const ready = await nvim.lua("return package.loaded.integration ~= nil");
    if (ready !== true) throw new Error('init.lua did not load the helpers');
  } catch (error) {
    proc.kill();
    throw new Error(`Neovim did not start: ${error.message}\n${stderr}`);
  }
  return new Editor(nvim, proc, data);
}

/** Calls into the helpers of one running Neovim. */
export class Editor {
  constructor(nvim, proc, data) {
    this.nvim = nvim;
    this.proc = proc;
    this.data = data;
    /** The connection `run` and friends use when not told otherwise. */
    this.conn = null;
  }

  /** Run Lua in Neovim with `...` bound to `args` and the helpers bound to `it`. */
  lua(code, args = []) {
    return this.nvim.lua(`local it = require('integration')\n${code}`, args);
  }

  /** Call `it.<name>(...)`. */
  call(name, ...args) {
    // Trailing nils would be dropped by msgpack, and Lua sees them as missing anyway.
    while (args.length && args[args.length - 1] === undefined) args.pop();
    return this.lua(`return it.${name}(...)`, args.map((arg) => (arg === undefined ? null : arg)));
  }

  /** Open a connection and make it the default for later calls. */
  async connect(url, opts = {}) {
    const connection = await this.call('connect', url, { timeout: TIMEOUT, ...opts });
    if (connection.state === 'connected' && opts.keep !== false) this.conn = connection.id;
    return connection;
  }

  /** Open a connection that must succeed. */
  async open(url, opts = {}) {
    const connection = await this.connect(url, opts);
    if (connection.state !== 'connected') {
      throw new Error(`could not connect to ${url}: ${connection.error ?? connection.state}`);
    }
    return connection;
  }

  disconnect(id) {
    return this.call('disconnect', id ?? null);
  }

  /** Submit SQL without waiting: `{ call_id }` or `{ error }`. */
  execute(sql, opts = {}) {
    return this.call('execute', sql, { conn_id: this.conn, ...defined(opts) });
  }

  /** Wait for a submitted call: its summary with `rows` (values) and `cells` (typed). */
  wait(callId, timeout = TIMEOUT) {
    return this.call('wait_call', callId, timeout);
  }

  /** Run SQL and answer the finished call, whatever its state. */
  query(sql, opts = {}) {
    return this.call('run', sql, { conn_id: this.conn, timeout: TIMEOUT, ...defined(opts) });
  }

  /** Run SQL that must succeed. */
  async run(sql, opts = {}) {
    const result = await this.query(sql, opts);
    if (result.state !== 'done') {
      throw new Error(`${sql} should run, but it ended ${result.state}: ${result.error}`);
    }
    return result;
  }

  /** Run SQL that must fail, answering the error text. */
  async fail(sql, opts = {}) {
    const result = await this.query(sql, opts);
    if (result.state === 'done') throw new Error(`${sql} should fail, but it ran`);
    return result.error ?? '';
  }

  request(method, args = {}) {
    return this.call('request', method, args);
  }

  configure(options) {
    return this.call('configure', options);
  }

  cancel(callId) {
    return this.call('cancel', callId);
  }

  sleep(ms) {
    return this.call('sleep', ms);
  }

  plan(callId, changes) {
    return this.call('plan', callId, changes);
  }

  /** Apply statements in one transaction, answering the `apply:done` payload. */
  apply(statements, callId, opts = {}) {
    return this.call('apply', opts.conn ?? this.conn, callId ?? 0, statements, opts.timeout ?? TIMEOUT);
  }

  applyStart(statements, callId, opts = {}) {
    return this.call('apply_start', opts.conn ?? this.conn, callId ?? 0, statements);
  }

  applyWait(handle, timeout = TIMEOUT) {
    return this.call('apply_wait', handle, timeout);
  }

  /** Plan staged changes to a held result and apply them: `{ stage, statements, error }`. */
  edit(callId, changes, opts = {}) {
    return this.call('edit', opts.conn ?? this.conn, callId, changes, opts.timeout ?? TIMEOUT);
  }

  introspect(path = [], conn) {
    return this.call('introspect', conn ?? this.conn, path, TIMEOUT);
  }

  structure(schema, relation, conn) {
    return this.call('structure', conn ?? this.conn, schema, relation, TIMEOUT);
  }

  relationships(schema, relation, conn) {
    return this.call('relationships', conn ?? this.conn, schema, relation, TIMEOUT);
  }

  routineSource(schema, name, kind, conn) {
    return this.call('routine_source', conn ?? this.conn, schema, name, kind, TIMEOUT);
  }

  defaultSchema(conn) {
    return this.call('default_schema', conn ?? this.conn, TIMEOUT);
  }

  /** Stop the engine and Neovim, and remove the data directory. */
  async stop() {
    try {
      await this.lua("require('sqmeow.rpc.client').stop()");
    } catch {
      // Neovim may already be gone; the process is killed below either way.
    }
    try {
      this.nvim.quit();
    } catch {
      // Already closed.
    }
    await new Promise((done) => {
      const timer = setTimeout(() => {
        this.proc.kill('SIGKILL');
        done();
      }, 3000);
      this.proc.once('exit', () => {
        clearTimeout(timer);
        done();
      });
      if (this.proc.exitCode !== null) {
        clearTimeout(timer);
        done();
      }
    });
    rmSync(this.data, { recursive: true, force: true });
  }
}

/** `opts` without the keys set to undefined, so they do not override defaults. */
function defined(opts) {
  return Object.fromEntries(Object.entries(opts).filter(([, value]) => value !== undefined));
}

/** The text and type of one cell: `{ type, value }`, `value` null for NULL. */
export function cell(result, row, column) {
  return result.cells?.[row]?.[column] ?? null;
}

/** The column names of a result. */
export function names(result) {
  return (result.columns ?? []).map((column) => column.name);
}

/** The index of a named column. */
export function column(result, name) {
  const index = names(result).indexOf(name);
  if (index < 0) throw new Error(`no column ${name} in ${names(result).join(', ')}`);
  return index;
}
