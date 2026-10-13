# Repository guidance

## Setup and checks

- Use `nix develop` (or `nix develop --command <command>`). The shell supplies SQLite/DuckDB headers, shared libraries, and runtime library paths; ordinary builds, including `just build`, dynamically link them. Only distribution builds use `bundled`: `just dist-build <target>`.
- On a fresh checkout, run `just docs-check` before `just lint`: it bootstraps the plugins under `.tests/` that LuaLS references in `.luarc.json`. The bootstrap downloads lazy.nvim/plugins; Lua tests also install the SQL Tree-sitter parser.
- CI order is `just docs-check`, `just lint`, `just db-up`, `just test`. Bare `just` runs lint/tests/docs-check but does not start databases or bootstrap dependencies before lint.
- Focused checks: `just lint-lua`, `just lint-rust`, `just test-lua`, or `cargo test -p <crate> <test-filter>`. For memory-constrained builds use `SQMEOW_CARGO_FLAGS='-j 1' just <recipe>`.
- Single SQLite integration case: `cargo test -j 1 -p sqmeow-adapters --test sqlite relationships_preserve_catalog_endpoints -- --exact --test-threads=1 --nocapture`.
- Server-backed tests skip unavailable databases and may still appear passed. `just db-up` starts Docker services; the test recipes export each available service's `SQMEOW_TEST_*_URL`. Direct `cargo test` requires those variables explicitly (see `Justfile`); `-- --nocapture` exposes Rust skip messages. `just db-down` deletes service data.
- `just test-lua` builds debug and refreshes an existing release binary. Engine resolution is managed `core.path/bin` first, then `target/release`, then `target/debug`; a debug rebuild alone can leave manual testing on an old engine. Use `:Sqmeow restart` after rebuilding. The Lua harness isolates data under `.tests/` and clears the plugin data root before running.

## Cross-language boundaries

- Lua owns editor/UI state; `core/sqmeow-core/src/main.rs` starts the separate database engine. `sqmeow-db` owns the adapter contract, result/value types, and edit/export/view logic; `sqmeow-adapters` implements dialects and selects them through `Backend`; `sqmeow-rpc` owns MessagePack transport.
- RPC changes span `core/sqmeow-core/src/server/mod.rs` (routing), its handler modules, and `lua/sqmeow/rpc/{client,events}.lua` plus Lua API callers. Long operations return an accepted id before emitting completion events; acceptance is not success. Preserve reply-before-event ordering.
- Engine stdout is exclusively RPC frames; send diagnostics to stderr via tracing (`SQMEOW_LOG`).
- Result filtering/sorting/aggregation operates on retained snapshots, not fresh database queries. Preserve original row identities for staged edits; only explicit refresh reruns a query.

## Generated help

- Edit help prose and API annotations in the Lua inputs listed in `scripts/minidoc.lua`, then run `just docs` and commit `doc/sqmeow.txt`. `just docs-check` regenerates the file and fails on a diff; hand-editing the generated help is not durable.
