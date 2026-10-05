# Local adapter smoke tests

These disposable fixtures cover every connection in `.sqmeow/connections.toml`:
PostgreSQL, CockroachDB, MySQL, MSSQL, ClickHouse, Redis, Dragonfly,
MongoDB, ScyllaDB, Cassandra, SurrealDB, Oracle, SQLite, and DuckDB.

## Run a test

1. Start network databases with `just db-up`. SQLite and DuckDB need no Docker.
2. Open `:Sqmeow`, connect to the matching connection, and press `u` to select it.
3. Expand **scratchpads**, then **local scratchpads**, then the folder with the same
   connection name.
4. Run files in order: `01_setup`, `02_create`, `03_read`, `04_update`, `05_delete`.
   Use the editor's execute-buffer mapping (`<leader>E` by default) for each file;
   several files contain multiple statements. `<CR>` executes one statement.
5. Re-run `03_read` between operations to inspect results. Run `06_cleanup` when
   finished, then start again at `01_setup` for a fresh test.

Folders do **not** bind queries to connections. Check the editor winbar before
executing, or explicitly bind the buffer with `:Sqmeow bind <connection>`.
Do not run these fixtures against production databases. Cleanup drops only the
fixture table/collection or the three explicitly named Redis keys, never a
database or a whole Redis instance. Confirm destructive-operation prompts.

## Expected results and feature checks

- Create: three records, Alice/Bob/Carol, with scores 10/20/30.
- Read: inspect columns, sort/filter, paging, row detail, export, and query history.
  Bob starts with a null note (an absent hash field in Redis/Dragonfly).
- Update: Bob's score becomes 25 and his note becomes `updated`.
- Delete: Carol is removed; Alice and Bob remain. In Redis/Dragonfly, `EXISTS`
  returns 0 for Carol's key. Re-run `03_read` to verify MongoDB writes.
- On adapters with editable results, edit the unfiltered `SELECT *` result from
  `03_read` to try staged updates, inserts, deletes, review, apply, and discard.
  Keep primary keys unchanged; read/execute support does not imply grid editing
  is supported for every adapter.

## Adapter differences

- Run cleanup before repeating a completed or partially completed cycle. Inserts
  are intentionally not upserts: repeating them may fail or duplicate records.
  Oracle and MongoDB setup expect their fixture not to exist.
- SQLite and DuckDB are in-memory: reconnecting loses the fixture.
- ClickHouse uses a MergeTree table and synchronous mutations for updates/deletes;
  its sorting key is not a uniqueness constraint.
- ScyllaDB/Cassandra use `sqmeow_quicktest.sqmeow_crud` with fully qualified CQL.
  The read example uses primary-key lookup instead of SQL-style filtering or
  arbitrary ordering. Cleanup leaves the empty dedicated keyspace for reuse.
- Redis/Dragonfly use three hashes under `sqmeow:crud:*`; values are strings.
- MongoDB files are native JSON database commands, not JavaScript/mongosh scripts.
- SurrealDB files use record IDs `sqmeow_crud:1`, `:2`, and `:3` in the configured
  namespace/database.
