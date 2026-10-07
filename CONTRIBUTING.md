# Contributing to sqmeow.nvim

Thanks for helping with sqmeow.nvim! Bug reports, documentation fixes, testing, and code contributions are all welcome.

## Development tools

Use [Nix](https://nixos.org/download/) with `nix-command` and `flakes` enabled to get the development tools: Rust, Neovim, Lua formatters and linters, and database libraries. The shell links SQLite/DuckDB dynamically; plain `cargo build` uses the same system libraries.

```sh
nix develop
```

Build with `cargo build` and run `just` for the checks before submitting. See [Justfile](Justfile) for individual commands.

Release archives compile SQLite/DuckDB from bundled sources (`just dist-build <target>`, i.e. `-p sqmeow-core --features bundled`), so they run without system database libraries. Linux musl targets build with `cross`; macOS releases require Apple Silicon.

## Pull requests and issues

Small, focused PRs are welcome and easier to review. For features or large changes, please open an issue to discuss the approach with maintainers before starting. Check existing issues and PRs to avoid duplicate work.

In your PR, explain what changed and why, link any related issue, and tell us what you tested. Update tests and documentation when behavior changes, and mention any checks you couldn't run. Use [Conventional Commits](https://www.conventionalcommits.org) for commit messages.

For bug reports, include steps to reproduce the problem, your Neovim version, and the database you're using.

## AI-assisted contributions

AI-assisted contributions are accepted. The same quality standards apply regardless of how the code was written. You are responsible for the code you submit: review AI output carefully, ensure `just` passes, and be prepared to explain your changes.
