# AGENTS.md

## Project overview

- Neovim database client: Lua owns editor/UI state; `core/sqmeow-core/src/main.rs` starts a separate Rust engine over MessagePack RPC.
- `sqmeow-db` owns the adapter contract, result/value types, and edit/export/view logic. `sqmeow-adapters` implements dialects through `Backend`; `sqmeow-rpc` owns transport.

## Setup

- Run commands in `nix develop` (or `nix develop --command <command>`) for SQLite/DuckDB headers, shared libraries, and runtime paths. Development builds link dynamically; distribution builds use `just dist-build <target>` to bundle them.
- On a fresh checkout, run `just docs-check` before linting. It downloads plugins into `.tests/` that LuaLS needs; Lua tests also install the SQL Tree-sitter parser.

## Build and test

- Build: `just build` (release) or `just build-debug`. For limited memory, use `SQMEOW_CARGO_FLAGS='-j 1' just <recipe>`.
- CI order: `just docs-check`, `just lint`, `just db-up`, `just test`. Bare `just` runs lint/tests/docs-check without starting databases or bootstrapping before lint.
- Focused checks: `just lint-lua`, `just lint-rust`, `just test-lua`, `just test-rust`, or `cargo test -p <crate> <test-filter>`. For a single database case, see `CONTRIBUTING.md` under “Running individual tests.”
- Server-backed tests can appear passed when skipped. `just db-up` starts Docker services; test recipes export `SQMEOW_TEST_*_URL` for available services. Direct Cargo runs need those variables from `Justfile`; add `-- --nocapture` to see skip messages. `just db-down` deletes service data.
- Engine lookup prefers `core.path/bin`, then `target/release`, then `target/debug`. `just test-lua` builds debug and refreshes an existing release binary; its harness clears the isolated plugin data root under `.tests/`. After manual rebuilds, check which binary will load and run `:Sqmeow restart`.

## Boundaries

- For RPC changes, update `core/sqmeow-core/src/server/mod.rs`, its handlers, and `lua/sqmeow/rpc/{client,events}.lua` plus API callers. Queue acceptance replies before completion events; failures after acceptance arrive through events.
- Reserve engine stdout for RPC frames; send diagnostics to stderr via tracing (`SQMEOW_LOG`).
- Filter, sort, and aggregate retained snapshots. Preserve original row identities for staged edits; only explicit refresh reruns the query.
- Generate `doc/sqmeow.txt` from the Lua inputs in `scripts/minidoc.lua`: edit their prose/API annotations, run `just docs`, and commit the generated help. `just docs-check` regenerates it and fails on a diff.
