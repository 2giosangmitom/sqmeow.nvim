# Contributing to sqmeow.nvim

Thanks for helping make sqmeow.nvim better! 🐈

Keep changes focused, test them locally, and tell us what you checked.

## Before you begin

1. Search existing issues and pull requests to avoid duplicate work.
2. For a larger change, open an issue to discuss the approach first.
3. Note which database adapters or Neovim workflows your change affects.

For an overview of the plugin, see the [sqmeow.nvim architecture on DeepWiki](https://deepwiki.com/2giosangmitom/sqmeow.nvim).

## Set up your environment

Use the [Nix](https://nixos.org/download/) development shell for CI's locked toolchain on Linux (x86_64 and ARM64) and Apple Silicon Macs. Enable Nix's `nix-command` and `flakes` experimental features first.

```sh
nix develop
```

The shell includes Rust, rustfmt, Clippy, [just](https://just.systems), StyLua, Selene, lua-language-server, Neovim, SQLite, and the DuckDB CLI and library. For server-backed integration tests, install Docker with Compose separately.

Without Nix, run `mise install` to install the tools in `mise.toml`, then install Neovim and the DuckDB library separately. Releases build with plain cargo (`cross` for Linux); Nix is only the development environment.

## Run the checks

From the development shell, run the checks relevant to your change:

| Command      | What it does                                                           |
| ------------ | ---------------------------------------------------------------------- |
| `just`       | Run lint, Rust and Lua tests, and the help-file check (the CI checks). |
| `just lint`  | Check Rust and Lua formatting and lint rules.                          |
| `just test`  | Run Rust and Lua tests.                                                |
| `just db-up` | Start Docker databases for server-backed integration tests.            |
| `just docs`  | Regenerate `doc/sqmeow.txt` from annotated sources.                    |

You can run a single task without entering the shell, for example `nix develop --command just lint`. See [`Justfile`](Justfile) for more targeted recipes.

> [!NOTE]
> Server-backed tests skip their cases when the corresponding Docker services are not running. Run `just db-up` before testing database-specific changes. If you edit annotated help sources, run `just docs` before `just` and include the regenerated help file.

MariaDB compatibility checks are optional so the default database stack does not consume extra
memory. Start it with `docker compose --profile mariadb up -d --wait mariadb`; `just test-rust`
then includes the MariaDB tests. For a focused run, set
`SQMEOW_TEST_MARIADB_URL=mysql://root:sqmeow@127.0.0.1:53307/sqmeow` and run
`cargo test -p sqmeow-adapters --test mariadb -- --test-threads=1`.

`flake.lock` pins Rust and system dependencies. After `nix flake update`, run `nix flake check --all-systems --no-build` and `nix develop --command just`. Keep Rust compatible with `Cargo.toml`'s `rust-version` and `mise.toml`.

## Using AI coding tools

You are responsible for code submitted with AI tools. Read the changes, check for unintended edits, and run the checks locally before opening a pull request.

## Open a pull request

- [ ] Keep the change focused and add or update tests and documentation when behavior changes.
- [ ] Run `just` locally and check the affected database or UI workflow when possible. Explain any checks you could not run.
- [ ] Review and test any AI-assisted code locally before submitting it.
- [ ] Describe what changed, link the relevant issue, and include your test results in the pull request template.

Use [Conventional Commits](https://www.conventionalcommits.org) for commit messages. Thank you for contributing! 💛
