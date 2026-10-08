# Contributing to sqmeow.nvim

Thanks for helping with sqmeow.nvim! Bug reports, documentation fixes, testing, and code contributions are all welcome.

## Development tools

Use [Nix](https://nixos.org/download/) with `nix-command` and `flakes` enabled to get the development tools: Rust, Neovim, Lua formatters and linters, and database libraries. The shell links SQLite/DuckDB dynamically; plain `cargo build` uses the same system libraries.

```sh
nix develop
```

Build with `cargo build -j 1`. On resource-limited machines, run individual checks rather than `just`, which runs the full suite. See [Justfile](Justfile) for individual commands.

Select one integration case at a time, limiting both compilation and test concurrency:

```sh
nix develop --command cargo test -j 1 -p sqmeow-adapters --test sqlite commands_create_read_update_and_delete_rows -- --exact --test-threads=1 --nocapture
```

For a server-backed target, set its `SQMEOW_TEST_*_URL` and replace `sqlite` with that target. Keep connectivity, a basic CRUD round trip, and focused regression coverage; avoid exhaustive database-backed matrices when unit tests cover the same logic. The full `just` workflow remains available for CI.

`just db-up` starts the databases for integration tests. Without them, server-backed Rust tests return early and Cargo counts them as passed; their skip messages appear with `cargo test -- --nocapture`. SQLite and DuckDB tests run locally. The Lua suite needs a built engine; `just test-lua` builds it first.

Use `rstest` named cases for Rust tests that repeat the same assertion with different inputs. Keep scenario tests for transactions, cancellation, and editor state. Remove duplicate setup or assertions only when the remaining cases cover the same behavior.

Release archives compile SQLite/DuckDB from bundled sources (`just dist-build <target>`, i.e. `-p sqmeow-core --features bundled`), so they run without system database libraries. Linux musl targets build with `cross`; macOS releases require Apple Silicon.

## Pull requests and issues

Small, focused PRs are welcome and easier to review. For features or large changes, please open an issue to discuss the approach with maintainers before starting. Check existing issues and PRs to avoid duplicate work.

In your PR, explain what changed and why, link any related issue, and tell us what you tested. Update tests and documentation when behavior changes, and mention any checks you couldn't run. Use [Conventional Commits](https://www.conventionalcommits.org) for commit messages.

For bug reports, include steps to reproduce the problem, your Neovim version, and the database you're using.

## AI-assisted contributions

AI-assisted contributions are accepted. The same quality standards apply regardless of how the code was written. You are responsible for the code you submit: review AI output carefully, ensure `just` passes, and be prepared to explain your changes.
