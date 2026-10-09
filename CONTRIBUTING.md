# Contributing to sqmeow.nvim

Thanks for your interest in contributing to sqmeow.nvim!

You don't need to be a Rust expert or a Neovim wizard to help out. Whether you're fixing a typo, reporting a bug, testing a feature, or writing code, every contribution makes the project better.

## Ways to contribute

There's more than one way to help:

| Interested in...        | Where to start                                                                  |
| ----------------------- | ------------------------------------------------------------------------------- |
| Improving documentation | Fix typos, clarify instructions, or open a PR                                   |
| Reporting bugs          | [Open an issue](https://github.com/2giosangmitom/sqmeow.nvim/issues/new/choose) |
| Testing features        | Try a PR or the latest development branch and share feedback                    |
| Writing code            | Follow the [development setup](#development-setup) below                        |

New to the project? Look for issues labeled `good first issue`, or ask for help finding something to work on.

## Getting familiar with the codebase

Check out the [DeepWiki documentation](https://deepwiki.com/2giosangmitom/sqmeow.nvim) to explore the architecture, key components, and how everything fits together.

You don't need to understand the entire codebase before contributing. Start with whatever interests you and explore from there.

## Development setup

We use [Nix](https://nixos.org/download/) to provide a consistent development environment with Rust, Neovim, formatters, and local database dependencies.

1. Install Nix with `nix-command` and `flakes` enabled.
2. Clone the repository and enter its directory.
3. Run the following commands:

```sh
nix develop
cargo build -j 1
```

That's it! You're ready to start developing.

The initial setup may take a while as Nix downloads and builds dependencies.

**Working on a slower machine?** Use `-j 1` with Cargo and run checks individually to reduce memory usage.

### SQLite and DuckDB

Development builds dynamically link against the system SQLite and DuckDB libraries provided by Nix.

Release builds bundle SQLite and DuckDB from source using `just dist-build <target>`, which enables `-p sqmeow-core --features bundled`.

You generally don't need to worry about this unless you're preparing a release.

## Making changes

A typical development workflow looks like this:

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

The full suite can take 10+ minutes. While developing, feel free to run only the checks relevant to your changes.

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

**Important:** Tests that require unavailable database servers are skipped automatically. They may still appear as passed in the test summary.

A successful run without `just db-up` doesn't necessarily mean all integration tests were executed.

To see skip messages, run:

```sh
cargo test -- --nocapture
```

### Running individual tests

You don't need to run the entire suite for every small change.

For example, to run a single SQLite integration test:

```sh
nix develop --command cargo test -j 1 \
  -p sqmeow-adapters \
  --test sqlite \
  commands_create_read_update_and_delete_rows \
  -- --exact --test-threads=1 --nocapture
```

For other databases, set the corresponding `SQMEOW_TEST_*_URL` environment variable and replace `sqlite` with the appropriate test target.

Check `just test-rust` in the [Justfile](Justfile) for supported environment variables.

### Writing tests

Keep tests focused and easy to maintain.

- **Prefer unit tests** for logic that doesn't need a real database.
- **Use integration tests** for connectivity, basic CRUD operations, and database-specific regressions.
- **Use `rstest` named cases** when testing the same behavior with multiple inputs.
- **Reserve larger scenario tests** for workflows that need them, such as transactions, cancellation, and editor state.

Avoid duplicating entire test scenarios when a smaller, more targeted test would do the job.

## Pull requests

Keep your changes focused and easy to review.

- Discuss major features or architectural changes in an issue first.
- Update tests and documentation when behavior changes.
- Run the relevant checks and mention anything you couldn't test.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles, such as `fix: ...`, `feat: ...`, or `docs: ...`.

When you're ready, [open a pull request](https://github.com/2giosangmitom/sqmeow.nvim/pulls) and follow the provided template.

Don't worry about getting everything perfect. We'll work through feedback together.

## Bug reports

Found something broken? [Open an issue](https://github.com/2giosangmitom/sqmeow.nvim/issues/new/choose) and follow the provided template.

A minimal reproduction is especially helpful. Include the database type, relevant queries, and steps to reproduce when possible.

Please remove credentials and other sensitive information from logs or configuration before sharing them.

## AI-assisted contributions

AI-assisted contributions are welcome! Just make sure you understand and take responsibility for the changes you submit.

A few simple expectations:

1. **Review the code.** Don't submit changes you haven't read or understood.
2. **Test your changes.** Run `just` when possible, or explain which checks you skipped and why.
3. **Be ready to explain.** You should be able to discuss how your changes work and why they're needed.

AI-generated code is held to the same standards as any other contribution.

## Need help?

Stuck on setup, confused by a test, or unsure where something belongs?

Take a look at the [DeepWiki documentation](https://deepwiki.com/2giosangmitom/sqmeow.nvim), or feel free to ask in an issue or pull request.

Questions are always welcome, and knowing where people get stuck helps us improve the project.

Thanks for helping make sqmeow.nvim better! 💛
