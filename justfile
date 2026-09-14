# Everything CI runs, runnable locally with the same command.

default: lint test docs-check

# Compile the engine in release mode, which is what the plugin prefers to load.
build:
    cargo build --release

# Compile the engine in debug mode, which is faster to iterate on.
build-debug:
    cargo build

lint: lint-rust lint-lua

lint-rust:
    cargo fmt --all --check
    cargo clippy --all-targets --all-features -- -D warnings

lint-lua:
    stylua --check .
    selene lua plugin tests
    lua-language-server --check=. --checklevel=Warning

fmt:
    cargo fmt --all
    stylua .

test: test-rust test-lua

# Rust tests. The PostgreSQL, MySQL, Redis, Dragonfly and MongoDB tests report themselves skipped unless `just db-up` has
# started the servers they need.
test-rust:
    #!/usr/bin/env bash
    set -euo pipefail
    # Each server is checked on its own: one of them being down should skip its own cases, not
    # point the other dialect's tests at a port with nothing behind it.
    if [ -n "$(docker compose ps --status running --quiet postgres 2>/dev/null)" ]; then
        export SQMEOW_TEST_POSTGRES_URL="postgres://sqmeow:sqmeow@127.0.0.1:55432/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet mysql 2>/dev/null)" ]; then
        export SQMEOW_TEST_MYSQL_URL="mysql://root:sqmeow@127.0.0.1:53306/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet redis 2>/dev/null)" ]; then
        export SQMEOW_TEST_REDIS_URL="redis://127.0.0.1:56379/0"
    fi
    if [ -n "$(docker compose ps --status running --quiet dragonfly 2>/dev/null)" ]; then
        export SQMEOW_TEST_DRAGONFLY_URL="redis://127.0.0.1:56380/0"
    fi
    if [ -n "$(docker compose ps --status running --quiet mongodb 2>/dev/null)" ]; then
        export SQMEOW_TEST_MONGODB_URL="mongodb://127.0.0.1:57017/sqmeow"
    fi
    cargo test --all-features

# Start the PostgreSQL, MySQL, Redis, Dragonfly and MongoDB servers the integration tests use.
db-up:
    docker compose up -d --wait

# Stop them and throw away their data.
db-down:
    docker compose down -v

# Needs a built engine, so build first. The server-backed cases skip unless `just db-up` has run.
# tests/minit.lua installs the plugins the suite needs under `.tests` and gives it a data directory
# of its own.
test-lua: build-debug
    #!/usr/bin/env bash
    set -euo pipefail
    # The plugin loads a release build before a debug one, so one left over from `just build` is
    # what the suite would test. Keep it current rather than testing an old engine.
    if [ -x target/release/sqmeow-core ]; then
        cargo build --release
    fi
    # Each server is checked on its own: one of them being down should skip its own cases, not
    # point the other dialect's tests at a port with nothing behind it.
    if [ -n "$(docker compose ps --status running --quiet postgres 2>/dev/null)" ]; then
        export SQMEOW_TEST_POSTGRES_URL="postgres://sqmeow:sqmeow@127.0.0.1:55432/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet mysql 2>/dev/null)" ]; then
        export SQMEOW_TEST_MYSQL_URL="mysql://root:sqmeow@127.0.0.1:53306/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet redis 2>/dev/null)" ]; then
        export SQMEOW_TEST_REDIS_URL="redis://127.0.0.1:56379/0"
    fi
    if [ -n "$(docker compose ps --status running --quiet dragonfly 2>/dev/null)" ]; then
        export SQMEOW_TEST_DRAGONFLY_URL="redis://127.0.0.1:56380/0"
    fi
    if [ -n "$(docker compose ps --status running --quiet mongodb 2>/dev/null)" ]; then
        export SQMEOW_TEST_MONGODB_URL="mongodb://127.0.0.1:57017/sqmeow"
    fi
    nvim -l tests/minit.lua

# Regenerate doc/sqmeow.txt from the annotated sources.
docs:
    nvim -l tests/minit.lua --docs

# Fail if the committed help file is behind the sources, the way CI does.
docs-check: docs
    git diff --exit-code doc/
