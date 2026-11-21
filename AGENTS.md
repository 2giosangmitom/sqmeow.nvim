# AGENTS.md

## What this is

sqmeow.nvim is a Neovim database client split across two processes. The Lua plugin (`lua/sqmeow/`) owns editor state: windows, buffers, keymaps, configuration, connection selection, and rendering, and never speaks to a database driver. The Rust engine (`crates/sqmeow-core/`) owns live connections, query execution, cancellation, retained results, and archives, and never touches buffers. They speak MessagePack-RPC over stdio: Lua calls, the engine replies and emits completion events. Closing the channel or calling `shutdown` stops the engine.

## Repository map

| Path                      | Responsibility                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------------- |
| `lua/sqmeow/api/`         | Public Lua API: connections, queries, views, exports                                              |
| `lua/sqmeow/rpc/`         | Process lifecycle (`client.lua`) and event dispatch (`events.lua`)                                |
| `lua/sqmeow/ui/`          | Drawer, result grid, detail, filter/sort, edit and connection forms                               |
| `lua/sqmeow/server/`      | Engine install, binary lookup, session persistence, history                                       |
| `crates/sqmeow-db/`       | Adapter trait, result/value types, retained views, edits, export, SQL parsing                     |
| `crates/sqmeow-adapters/` | One module per dialect; `Backend` erases the concrete adapter                                     |
| `crates/sqmeow-core/`     | Engine binary, RPC transport and framing (`src/rpc/`), handlers (`src/server/`)                   |
| `tests/ui/`               | Lua `mini.test` suite for UI and pure Lua logic; `minit.lua` also drives doc generation           |
| `tests/integration/`      | Node `node:test` suite driving headless Neovim via the `neovim` npm client against real databases |
| `doc/sqmeow.txt`          | Generated Vim help; never edit by hand                                                            |

Architecture background: [DeepWiki](https://deepwiki.com/2giosangmitom/sqmeow.nvim).

## Workflow

[mise](https://mise.jdx.dev) supplies the toolchain from `mise.toml`: Rust, Node.js, Neovim, the Lua linters, and the DuckDB C library with headers (it also sets `DUCKDB_LIB_DIR`, `DUCKDB_INCLUDE_DIR`, and the loader path). SQLite links against the system `libsqlite3`. Run `mise install` once, then everything through `mise run <task>`; `mise tasks` lists them.

```sh
mise run docs:check  # bootstrap .tests/ plugins for LuaLS, then check generated help
mise run build       # release engine, preferred at runtime
mise run build:debug # faster iteration
mise run fmt
mise run lint
mise run test        # test:rust + test:ui + test:integration
mise run ci          # docs:check, lint, test, as CI runs them
```

Run `mise run docs:check` once on a fresh checkout; LuaLS needs the plugins it downloads into `.tests/`. `mise run test:ui` also installs the SQL Tree-sitter parser.

- Narrow checks while iterating: `mise run lint:rust`, `mise run lint:lua`, `mise run test:rust`, `mise run test:ui`, `mise run test:integration`, or `cargo test -p <crate> <filter>`. Finish with `mise run lint` plus the suites covering your change.
- On low-memory machines, add `SQMEOW_CARGO_FLAGS='-j 1'` to any task that runs Cargo.
- Never enable the `bundled` Cargo feature for dev, test, or lint; only `dist-build` uses it.

### Database tests

`mise run db:up` starts the Docker services; `mise run db:down` stops them and deletes their data. The integration suite discovers running compose services itself (`tests/integration/servers.mjs`), so missing servers skip their cases and still report green. `mise run db:up && mise run test` is a complete run. One file or test: `node --test --test-name-pattern=<x> tests/integration/postgres.test.mjs` after `mise run build:debug`. The Lua harness wipes its plugin data root under `.tests/` before each run.

### Writing tests

Rust keeps unit tests only, for logic that needs no database; `rstest` named cases suit the same behavior over multiple inputs. Connectivity, CRUD, and dialect regressions go in `tests/integration/`. Reserve larger scenarios for transactions, cancellation, and editor state, and do not re-create a whole scenario when a targeted test will do.

A new dialect needs connectivity and CRUD coverage in `tests/integration/<dialect>.test.mjs`; UI and pure Lua behavior goes in the `mini.test` suite under `tests/ui/`.

### Which engine binary loads

Lookup order is `core.path/bin`, then `target/release`, then `target/debug`. `mise run test:ui` and `mise run test:integration` build debug, and `test:ui` refreshes an existing release binary. After a manual rebuild, check which binary is in use and run `:Sqmeow restart`.

## Invariants

- Lua owns editor/UI state; Rust owns connections, cancellation, and retained results. No database driver in Lua, no buffer mutation in Rust.
- RPC changes need dispatch in `crates/sqmeow-core/src/server/mod.rs`, the handler module, `lua/sqmeow/rpc/{client,events}.lua`, and API callers. Long-running methods must queue the acceptance reply before starting work so Lua records the id before completion events arrive; failures after acceptance are events, not RPC errors.
- stdout carries RPC frames only. Send diagnostics to stderr through `tracing`; `SQMEOW_LOG` sets verbosity and `:Sqmeow messages` shows collected lines.
- Filtering, sorting, and aggregation run on retained snapshots and must not re-run the query; only an explicit refresh does. Preserve original row indices and key columns for staged edits so edits target real rows, not display positions.
- Help is generated. Edit the EmmyLua prose and annotations in the inputs that `scripts/minidoc.lua` lists (`lua/sqmeow/init.lua`, `config.lua`, `keymap.lua`, `api/*.lua`), run `mise run docs`, and commit `doc/sqmeow.txt`. `mise run docs:check` fails on any diff.
- A new dialect gets a module under `crates/sqmeow-adapters/src/`, wiring in `Backend` and `supported()`, a `Dialect::from_url` scheme, an integration test at `tests/integration/<dialect>.test.mjs`, a `compose.yaml` service, and an entry in `tests/integration/servers.mjs`.
