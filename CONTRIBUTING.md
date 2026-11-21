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

Install [mise](https://mise.jdx.dev/getting-started.html) and the SQLite 3 development package (`libsqlite3-dev` on Debian/Ubuntu, `sqlite` on Arch and Homebrew). Everything else comes from [`mise.toml`](mise.toml): Rust with `rustfmt` and `clippy`, Node.js, Neovim, `stylua`, `selene`, `lua-language-server`, and the DuckDB C library and headers.

Clone the repository, enter its directory, and run:

```sh
mise install
mise run build:debug
```

The initial build can take a while because Cargo compiles every database adapter.

On machines with limited memory, run `SQMEOW_CARGO_FLAGS='-j 1' mise run build:debug`. Every task that runs Cargo honors `SQMEOW_CARGO_FLAGS`. Running checks one at a time also reduces memory use.

On a fresh checkout, run `mise run docs:check` once before linting. It downloads the Lua plugins that LuaLS needs into `.tests/`.

### SQLite and DuckDB

Development builds link dynamically against SQLite and DuckDB. SQLite comes from your system. mise installs the DuckDB release that the `duckdb` crate targets and points `DUCKDB_LIB_DIR`, `DUCKDB_INCLUDE_DIR`, and `LD_LIBRARY_PATH` (`DYLD_LIBRARY_PATH` on macOS) at it, so `mise run` tasks and an activated mise shell need no extra setup. A Neovim started outside the mise environment loads the engine with the system loader path and needs a compatible `libduckdb` there.

To skip external libraries entirely, build the engine with DuckDB and SQLite compiled from source:

```sh
cargo build -p sqmeow-core --features bundled
```

Distribution builds do the same for supported triples with `mise run dist-build <target>`.

## Making changes

Typical workflow:

```sh
# Create a branch
git checkout -b fix/short-description

# Make your changes, then run the relevant checks
mise run lint
mise run test:rust
mise run test:ui
```

| Command                     | Purpose                                                  |
| --------------------------- | -------------------------------------------------------- |
| `mise run build`            | Build the release engine, which the plugin prefers       |
| `mise run build:debug`      | Build the debug engine, faster to iterate on             |
| `mise run fmt`              | Format Rust and Lua code                                 |
| `mise run lint`             | Run Rust and Lua linters (`lint:rust`, `lint:lua`)       |
| `mise run test:rust`        | Run Rust unit tests                                      |
| `mise run test:ui`          | Build the engine and run the Lua UI tests in `tests/ui/` |
| `mise run test:integration` | Build the engine and run the Node integration suite      |
| `mise run test`             | Run all three test suites                                |
| `mise run docs`             | Regenerate `doc/sqmeow.txt`                              |
| `mise run docs:check`       | Check documentation                                      |
| `mise run db:up`            | Start the test databases in Docker                       |
| `mise run db:down`          | Stop the test databases and delete their data            |
| `mise run ci`               | Run docs-check, lint, and tests, as CI does              |

`mise run ci` runs the same checks as CI. It can take 10+ minutes. While developing, run only the checks relevant to your changes. `mise tasks` lists every task; they are defined in [`mise.toml`](mise.toml).

User help is generated from the EmmyLua annotations in `lua/sqmeow/init.lua`, `config.lua`, `keymap.lua`, and `api/*.lua`. Edit those files, run `mise run docs`, and commit `doc/sqmeow.txt`. `mise run docs:check` fails when the committed help is stale.

Once you're happy with your changes, push your branch and open a pull request.

## Testing

The suites are split by what they need:

- Rust (`cargo test`): unit tests only, no databases.
- `tests/ui/`: Lua [`mini.test`](https://github.com/echasnovski/mini.test) suite for the UI and pure Lua logic, run in headless Neovim.
- `tests/integration/`: Node [`node:test`](https://nodejs.org/api/test.html) suite that drives headless Neovim through the `neovim` npm client against real databases.

### Database tests

SQLite and DuckDB integration tests need no Docker services. The server-based databases (PostgreSQL, MySQL, Redis, etc.) require Docker:

```sh
# Start test databases
mise run db:up

# Run the integration suite
mise run test:integration

# Stop databases and remove test data
mise run db:down
```

The suite checks which compose services are running and skips the cases for the rest, so it can pass without exercising every database.

### Running individual tests

Run one integration test file, or only the tests whose name matches a pattern:

```sh
node --test tests/integration/postgres.test.mjs
node --test --test-name-pattern=<pattern> tests/integration/postgres.test.mjs
```

Run `mise run build:debug` first so the suite tests a current engine, and `npm ci` once to install the Node dependencies.

A single Rust unit test:

```sh
cargo test -p <crate> <filter>
```

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
