# Contributing to sqmeow.nvim

Thanks for your interest in contributing to sqmeow.nvim!

You don't need to be a Rust expert or a Neovim wizard to help out.

## Ways to contribute

| Interested in...        | Where to start                                                                  |
| ----------------------- | ------------------------------------------------------------------------------- |
| Improving documentation | Fix typos, clarify instructions, or open a PR                                   |
| Reporting bugs          | [Open an issue](https://github.com/2giosangmitom/sqmeow.nvim/issues/new/choose) |
| Testing features        | Try a PR or the latest development branch and share feedback                    |
| Writing code            | Follow the [development setup](#development-setup) below                        |

Look for issues labeled `good first issue`, or ask for help finding something to work on.

## Getting familiar with the codebase

Read the [DeepWiki documentation](https://deepwiki.com/2giosangmitom/sqmeow.nvim) for the architecture and key components.

## Development setup

[Nix](https://nixos.org/download/) supplies Rust, Neovim, formatters, and local database dependencies.

1. Install Nix with `nix-command` and `flakes` enabled.
2. Clone the repository and enter its directory.
3. Run the following commands:

```sh
nix develop
cargo build -j 1
```

The initial setup may take a while as Nix downloads and builds dependencies.

On slower machines, use `-j 1` with Cargo and run checks individually to reduce memory usage.

### SQLite and DuckDB

Development builds dynamically link against the system SQLite and DuckDB libraries provided by Nix.

Distribution builds bundle SQLite and DuckDB from source using `just dist-build <target>`, which enables `-p sqmeow-core --features bundled`.

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
| `just test-rust`  | Run Rust tests                     |
| `just test-lua`   | Build the engine and run Lua tests |
| `just docs-check` | Check documentation                |
| `just`            | Run the full CI check suite        |

The full suite can take 10+ minutes. While developing, run only the checks relevant to your changes.

See the [Justfile](Justfile) for all available commands.

Once you're happy with your changes, push your branch and open a pull request.

## Testing

### Database tests

SQLite and DuckDB work locally without additional setup.

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

Tests that require unavailable database servers are skipped automatically. They may still appear as passed in the test summary.

A successful run without `just db-up` doesn't necessarily mean all integration tests were executed.

To see skip messages, run:

```sh
cargo test -- --nocapture
```

### Running individual tests

To run a single SQLite integration test:

```sh
nix develop --command cargo test -j 1 \
  -p sqmeow-adapters \
  --test sqlite \
  relationships_preserve_catalog_endpoints \
  -- --exact --test-threads=1 --nocapture
```

For other databases, set the corresponding `SQMEOW_TEST_*_URL` environment variable and replace `sqlite` with the appropriate test target.

Check `just test-rust` in the [Justfile](Justfile) for supported environment variables.

### Writing tests

- Prefer unit tests for logic that doesn't need a real database.
- Use integration tests for connectivity, basic CRUD operations, and database-specific regressions.
- Use `rstest` named cases when testing the same behavior with multiple inputs.
- Reserve larger scenario tests for transactions, cancellation, and editor state.

Avoid duplicating entire test scenarios when a smaller, more targeted test would do the job.

## Pull requests

- Discuss major features or architectural changes in an issue first.
- Update tests and documentation when behavior changes.
- Run the relevant checks and mention anything you couldn't test.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles, such as `fix: ...`, `feat: ...`, or `docs: ...`.

When you're ready, [open a pull request](https://github.com/2giosangmitom/sqmeow.nvim/pulls) and follow the provided template.

Don't worry about getting everything perfect. We'll work through feedback together.

## Bug reports

[Open an issue](https://github.com/2giosangmitom/sqmeow.nvim/issues/new/choose) and follow the provided template.

Include the database type, relevant queries, and steps to reproduce when possible.

Please remove credentials and other sensitive information from logs or configuration before sharing them.

## AI-assisted contributions

AI-assisted contributions are welcome. You are responsible for the changes you submit:

1. Read and understand the code.
2. Run `just` when possible, or explain which checks you skipped and why.
3. Be ready to explain how your changes work and why they're needed.

## Need help?

For setup, test, or codebase questions, read the [DeepWiki documentation](https://deepwiki.com/2giosangmitom/sqmeow.nvim) or ask in an issue or pull request.

Thanks for helping make sqmeow.nvim better! 💛
