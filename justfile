# Everything CI runs, runnable locally with the same command.

default: lint test docs-check

# Clone the plugins the tests and the documentation need.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    clone() {
        if [ -d ".deps/$2" ]; then
            git -C ".deps/$2" pull --quiet
        else
            git clone --filter=blob:none --depth 1 "$1" ".deps/$2"
        fi
    }
    # mini.nvim supplies the test harness and the documentation generator.
    clone https://github.com/nvim-mini/mini.nvim mini.nvim
    # nui.nvim is what the connection dialog is built on.
    clone https://github.com/MunifTanjim/nui.nvim nui.nvim

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
    selene lua plugin telescope tests

fmt:
    cargo fmt --all
    stylua .

test: test-rust test-lua

# Rust tests. The PostgreSQL and MySQL tests report themselves skipped unless `just db-up` has
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
    cargo test --all-features

# Start the PostgreSQL and MySQL servers the integration tests use.
db-up:
    docker compose up -d --wait

# Stop them and throw away their data.
db-down:
    docker compose down -v

# Needs a built engine, so build first. The server-backed cases skip unless `just db-up` has run.
test-lua: build-debug
    #!/usr/bin/env bash
    set -euo pipefail
    # Scratchpads live under `stdpath('data')`, so the suite gets a data directory of its own
    # rather than writing into the one the person running it uses every day.
    XDG_DATA_HOME="$(mktemp -d)"
    export XDG_DATA_HOME
    trap 'rm -rf "$XDG_DATA_HOME"' EXIT
    # Each server is checked on its own: one of them being down should skip its own cases, not
    # point the other dialect's tests at a port with nothing behind it.
    if [ -n "$(docker compose ps --status running --quiet postgres 2>/dev/null)" ]; then
        export SQMEOW_TEST_POSTGRES_URL="postgres://sqmeow:sqmeow@127.0.0.1:55432/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet mysql 2>/dev/null)" ]; then
        export SQMEOW_TEST_MYSQL_URL="mysql://root:sqmeow@127.0.0.1:53306/sqmeow"
    fi
    nvim --headless -u tests/minimal_init.lua -c "lua require('mini.test').setup(); MiniTest.run()"

# Regenerate doc/sqmeow.txt from the annotated sources.
docs:
    nvim --headless -u scripts/minidoc_init.lua -c "lua require('mini.doc').generate()" -c "qa!"

# Fail if the committed help file is behind the sources, the way CI does.
docs-check: docs
    git diff --exit-code doc/
