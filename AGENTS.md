# AGENTS.md

## What this is

sqmeow.nvim is a Neovim database client split across two processes. The Lua plugin (`lua/sqmeow/`) owns editor state: windows, buffers, keymaps, configuration, connection selection, and rendering, and never speaks to a database driver. The Rust engine (`core/sqmeow-core/`) owns live connections, query execution, cancellation, retained results, and archives, and never touches buffers. They speak MessagePack-RPC over stdio: Lua calls, the engine replies and emits completion events. Closing the channel or calling `shutdown` stops the engine.

## Repository map

| Path                    | Responsibility                                                                |
| ----------------------- | ----------------------------------------------------------------------------- |
| `lua/sqmeow/api/`       | Public Lua API: connections, queries, views, exports                          |
| `lua/sqmeow/rpc/`       | Process lifecycle (`client.lua`) and event dispatch (`events.lua`)            |
| `lua/sqmeow/ui/`        | Drawer, result grid, detail, filter/sort, edit and connection forms           |
| `lua/sqmeow/server/`    | Engine install, binary lookup, session persistence, history                   |
| `core/sqmeow-rpc/`      | Transport, framing, request/reply contract                                    |
| `core/sqmeow-db/`       | Adapter trait, result/value types, retained views, edits, export, SQL parsing |
| `core/sqmeow-adapters/` | One module per dialect; `Backend` erases the concrete adapter                 |
| `core/sqmeow-core/`     | Engine binary and RPC handlers (`src/server/`)                                |
| `tests/`                | Lua `mini.test` suite; `tests/minit.lua` also drives doc generation           |
| `doc/sqmeow.txt`        | Generated Vim help; never edit by hand                                        |

Architecture background: [DeepWiki](https://deepwiki.com/2giosangmitom/sqmeow.nvim).

## Workflow

The Nix dev shell (`nix develop`, or `nix develop --command <cmd>`) supplies the toolchain, Neovim, `just`, linters, and the SQLite/DuckDB headers. Outside it, install what [CONTRIBUTING.md](CONTRIBUTING.md) lists and link against system SQLite and DuckDB.

```sh
just docs-check   # bootstrap .tests/ plugins for LuaLS, then check generated help
just build        # release engine, preferred at runtime
just build-debug  # faster iteration
just fmt
just lint
just test
just              # lint + test + docs-check, as CI runs them without databases
```

Run `just docs-check` once on a fresh checkout; LuaLS needs the plugins it downloads into `.tests/`. `just test-lua` also installs the SQL Tree-sitter parser.

- Narrow checks while iterating: `just lint-rust`, `just lint-lua`, `just test-rust`, `just test-lua`, or `cargo test -p <crate> <filter>`. Finish with `just lint` plus the suites covering your change.
- On low-memory machines, add `SQMEOW_CARGO_FLAGS='-j 1'` to any recipe that runs Cargo.

### Database tests

`just db-up` starts the Docker services; `just db-down` stops them and deletes their data. Test recipes export `SQMEOW_TEST_*_URL` only for running services, so missing servers skip their cases and still report green. `just db-up && just test` is a complete run; for a direct `cargo` run, set the same variables and pass `-- --nocapture` to see skip messages. The Lua harness wipes its plugin data root under `.tests/` before each run.

### Writing tests

Prefer unit tests for logic that needs no database. Integration tests cover connectivity, CRUD, and dialect regressions, and `rstest` named cases suit the same behavior over multiple inputs. Reserve larger scenarios for transactions, cancellation, and editor state, and do not re-create a whole scenario when a targeted test will do.

A new dialect needs connectivity and CRUD coverage in `core/sqmeow-adapters/tests/<dialect>.rs`; Lua behavior goes in the `mini.test` suite under `tests/`.

### Which engine binary loads

Lookup order is `core.path/bin`, then `target/release`, then `target/debug`. `just test-lua` builds debug and refreshes an existing release binary. After a manual rebuild, check which binary is in use and run `:Sqmeow restart`.

## Invariants

- Lua owns editor/UI state; Rust owns connections, cancellation, and retained results. No database driver in Lua, no buffer mutation in Rust.
- RPC changes need dispatch in `core/sqmeow-core/src/server/mod.rs`, the handler module, `lua/sqmeow/rpc/{client,events}.lua`, and API callers. Long-running methods must queue the acceptance reply before starting work so Lua records the id before completion events arrive; failures after acceptance are events, not RPC errors.
- stdout carries RPC frames only. Send diagnostics to stderr through `tracing`; `SQMEOW_LOG` sets verbosity and `:Sqmeow messages` shows collected lines.
- Filtering, sorting, and aggregation run on retained snapshots and must not re-run the query; only an explicit refresh does. Preserve original row indices and key columns for staged edits so edits target real rows, not display positions.
- Help is generated. Edit the EmmyLua prose and annotations in the inputs that `scripts/minidoc.lua` lists (`lua/sqmeow/init.lua`, `config.lua`, `keymap.lua`, `api/*.lua`), run `just docs`, and commit `doc/sqmeow.txt`. `just docs-check` fails on any diff.
- A new dialect gets a module under `core/sqmeow-adapters/src/`, wiring in `Backend` and `supported()`, a `Dialect::from_url` scheme, an integration test at `core/sqmeow-adapters/tests/<dialect>.rs`, a `compose.yaml` service, and a `SQMEOW_TEST_*_URL` export in the `Justfile` test recipes.
