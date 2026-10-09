# Contributing to sqmeow.nvim

Thanks for your interest in sqmeow.nvim. You don't need to be a Rust expert or a Neovim wizard to help. Bug reports, typo fixes, testing a snapshot, answering an issue, all of it moves the project forward.

## Ways to contribute

Pick whatever fits your time and mood:

| If you want to... | Start here |
| --- | --- |
| Fix a typo or clarify docs | Edit the file, open a PR. No setup needed |
| Report a bug | [Open an issue](#bug-reports) with steps to reproduce |
| Try things out | Test-drive a PR or the default branch and comment what you found |
| Write code | Follow the [5-minute setup](#5-minute-setup) below |

New to the codebase? Look for issues labeled `good first issue`, or ask in an issue and we'll help you find a small starting point.

## 5-minute setup

We use [Nix](https://nixos.org/download/) so everyone gets the same Rust, Neovim, formatters, and local databases without version juggling.

```sh
# 1. Install Nix with `nix-command` and `flakes` enabled
#    (see https://nixos.org/download/ — ask if you get stuck)

# 2. Enter the dev environment (takes ~5 min the first time)
nix develop

# 3. Build once to confirm everything works
cargo build -j 1
```

> On a weaker machine, pass `-j 1` to cargo commands and run checks one at a time. It takes longer but stays responsive.

**A note on SQLite/DuckDB:** dev builds link the system libraries that Nix provides. Release archives bundle them from source instead (`just dist-build <target>`, which builds `-p sqmeow-core --features bundled`). You only need to care about this when cutting a release.

## Making a change

A typical flow:

```sh
# 1. Create a branch
git checkout -b fix/short-description

# 2. Make your change, then get fast feedback
just lint          # Rust + Lua linters
just test-rust     # Rust tests
just test-lua      # Lua tests (builds the engine first)
```

`just` with no arguments runs everything CI runs (`lint`, `test`, `docs-check`). That takes 10+ minutes, so while developing, run the single command you need. See the [Justfile](Justfile) for the full list.

When you're happy, push and open a PR.

## Testing with databases

- **SQLite and DuckDB** run locally, no setup needed.
- **Server databases** (Postgres, MySQL, Redis, …) need Docker:

```sh
just db-up     # start test databases
# ... run tests ...
just db-down   # stop them and throw away test data
```

If the servers aren't running, those Rust tests skip themselves (they show as passed; run with `cargo test -- --nocapture` to see the skip messages). The Lua suite behaves the same way. A green run without `just db-up` means local tests passed and server tests were skipped.

Running a single integration case keeps things fast on slow machines:

```sh
nix develop --command cargo test -j 1 -p sqmeow-adapters --test sqlite commands_create_read_update_and_delete_rows -- --exact --test-threads=1 --nocapture
```

For another database, set its `SQMEOW_TEST_*_URL` (see `just test-rust` for the list) and swap `sqlite` for that target.

**Test style:** prefer unit tests. Save DB-backed tests for connectivity, one CRUD round trip, and focused regressions. When one assertion needs many inputs, use `rstest` named cases instead of copy-pasting tests. Keep full scenario tests for things that really need them: transactions, cancellation, editor state.

## Pull requests

No strict template. Include enough for a reviewer to follow along:

- [ ] Keep it small and focused (one fix or feature per PR)
- [ ] For features or anything large, open an issue first so we agree on direction
- [ ] Describe what changed and why, link the issue
- [ ] Tell us what you tested and which checks you skipped
- [ ] Update tests and docs when behavior changes
- [ ] Use [Conventional Commits](https://www.conventionalcommits.org) for titles, e.g. `fix: ...`, `feat: ...`, `docs: ...`

Don't worry about getting everything perfect. We'll review kindly and iterate with you.

## Bug reports

Copy this into your issue and fill it in:

```md
**What happened:**

**Steps to reproduce:**
1.
2.
3.

**Expected:**

**Neovim version** (`:version`):
**Database type** (postgres / sqlite / redis / …):
**Anything else:**
```

Include a minimal query or table definition when you can.

## AI-assisted contributions

AI help is welcome. It goes through the same review as any other change:

1. Review every line as if you wrote it.
2. Make `just` pass (or say which checks you skipped and why).
3. Be ready to explain each change in review.

## Stuck? Just ask

If setup fails, a test confuses you, or you're unsure where code should go, open an issue or comment on a PR. Telling us where you got stuck also shows us what to document better.
