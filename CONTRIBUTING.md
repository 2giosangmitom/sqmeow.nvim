# Contributing to sqmeow.nvim

Thanks for your interest in contributing to sqmeow.nvim!

## Ways to contribute

| Interested in...        | Where to start                                                                  |
| ----------------------- | ------------------------------------------------------------------------------- |
| Improving documentation | Fix typos, clarify instructions, or open a PR                                   |
| Reporting bugs          | [Open an issue](https://github.com/2giosangmitom/sqmeow.nvim/issues/new/choose) |
| Testing features        | Try a PR or the latest development branch and share feedback                    |
| Writing code            | Follow the [development setup](#development-setup) below                        |

Look for issues labeled `good first issue`, or ask for help finding something to work on.

## Development setup

You need:

- Rust 1.98 or newer with `rustfmt` and `clippy` (`rustup component add rustfmt clippy`)
- [`just`](https://github.com/casey/just)
- Neovim 0.10 or newer
- SQLite 3 development headers and a DuckDB 1.2 C library with headers
- `stylua`, `selene`, and `lua-language-server` for `just lint-lua`

Clone the repository, enter its directory, and build the engine:

```sh
just build-debug
```

The initial build can take a while because Cargo compiles every database adapter.

On machines with limited memory, run `SQMEOW_CARGO_FLAGS='-j 1' just build-debug`. Running checks one at a time also reduces memory use.

On a fresh checkout, run `just docs-check` once before linting. It downloads the Lua plugins that LuaLS needs into `.tests/`.

### SQLite and DuckDB

Development builds link dynamically against the SQLite and DuckDB libraries installed on your system. If they are not in a standard location, point Cargo at them:

```sh
export SQLITE3_LIB_DIR=/usr/lib
export SQLITE3_INCLUDE_DIR=/usr/include
export DUCKDB_LIB_DIR=/usr/local/lib
export DUCKDB_INCLUDE_DIR=/usr/local/include
```

A dynamically linked engine also needs the DuckDB library at runtime, so add its directory to `LD_LIBRARY_PATH` on Linux or `DYLD_LIBRARY_PATH` on macOS.

To skip system DuckDB entirely, build the engine with DuckDB and SQLite compiled from source:

```sh
cargo build -p sqmeow-core --features bundled
```

Distribution builds do the same for supported triples with `just dist-build <target>`.

CI runs the same recipes inside the [Nix](https://nixos.org/download/) dev shell (`nix develop`). Using it locally is optional and gives you the exact toolchain versions.

## Making changes

Typical workflow:

```sh
# Create a branch
git checkout -b fix/short-description

# Make your changes, then run the relevant checks
just lint
just test-rust
just test-lua
```

| Command           | Purpose                            |
| ----------------- | ---------------------------------- |
| `just lint`       | Run Rust and Lua linters           |
| `just fmt`        | Format Rust and Lua code           |
| `just test-rust`  | Run Rust tests                     |
| `just test-lua`   | Build the engine and run Lua tests |
| `just docs-check` | Check documentation                |
| `just`            | Run lint, tests, and docs-check    |

`just` runs the same checks as CI, without the database setup. It can take 10+ minutes. While developing, run only the checks relevant to your changes.

See the [Justfile](Justfile) for all available commands.

User help is generated from the EmmyLua annotations in `lua/sqmeow/init.lua`, `config.lua`, `keymap.lua`, and `api/*.lua`. Edit those files, run `just docs`, and commit `doc/sqmeow.txt`. `just docs-check` fails when the committed help is stale.

Once you're happy with your changes, push your branch and open a pull request.

## Testing

### Database tests

SQLite and DuckDB tests need no Docker services.

Integration tests for server-based databases (PostgreSQL, MySQL, Redis, etc.) require Docker.

```sh
# Start test databases
just db-up

# Run your tests
just test-rust
just test-lua

# Stop databases and remove test data
just db-down
```

The harness skips tests whose `SQMEOW_TEST_*_URL` is not set. Those tests can still appear as passed in the summary.

Without `just db-up`, some integration tests will not run even when the suite passes.

To see skip messages, run:

```sh
cargo test -- --nocapture
```

### Running individual tests

To run a single SQLite integration test:

```sh
cargo test -j 1 \
  -p sqmeow-adapters \
  --test sqlite \
  relationships_preserve_catalog_endpoints \
  -- --exact --test-threads=1 --nocapture
```

For other databases, set the corresponding `SQMEOW_TEST_*_URL` environment variable and replace `sqlite` with the appropriate test target.

Check `just test-rust` in the [Justfile](Justfile) for supported environment variables.

## Pull requests

- Discuss major features or architectural changes in an issue first.
- Update tests and documentation when behavior changes.
- Run the relevant checks and mention anything you couldn't test.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles, such as `fix: ...`, `feat: ...`, or `docs: ...`.
- Keep PR title and description clear.

When you're ready, [open a pull request](https://github.com/2giosangmitom/sqmeow.nvim/pulls) and follow the provided template.

## Bug reports

[Open an issue](https://github.com/2giosangmitom/sqmeow.nvim/issues/new/choose) and follow the provided template.

Include the database type, relevant queries, and reproduction steps.

Remove credentials and other sensitive information from logs or configuration before sharing them.

## AI-assisted contributions

AI-assisted contributions are welcome. You are responsible for the changes you submit:

1. Read and understand the code.
2. Run the relevant checks, or explain which ones you skipped and why.
3. Be ready to explain how your changes work and why they're needed.

## Need help?

For setup, test, or codebase questions, read the [DeepWiki documentation](https://deepwiki.com/2giosangmitom/sqmeow.nvim) or ask in an issue or pull request.

Thanks for helping make sqmeow.nvim better! 💛
