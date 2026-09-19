# Everything CI runs, runnable locally with the same command.

# Extra cargo flags, e.g. `--features bundled-duckdb` on a machine without libduckdb.
cargo_flags := env_var_or_default("SQMEOW_CARGO_FLAGS", "")

default: lint test docs-check

# Compile the engine in release mode, which is what the plugin prefers to load.
build:
    cargo build --release {{cargo_flags}}

# Compile the engine in debug mode, which is faster to iterate on.
build-debug:
    cargo build {{cargo_flags}}

lint: lint-rust lint-lua

lint-rust:
    cargo fmt --all --check
    cargo clippy --all-targets {{cargo_flags}} -- -D warnings

lint-lua:
    stylua --check .
    selene lua plugin tests
    lua-language-server --check=. --checklevel=Warning

fmt:
    cargo fmt --all
    stylua .

test: test-rust test-lua

# Rust tests. The PostgreSQL, MySQL, Redis, Dragonfly, MongoDB, ScyllaDB and Cassandra tests report themselves skipped unless `just db-up` has
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
    if [ -n "$(docker compose ps --status running --quiet redis-cluster 2>/dev/null)" ]; then
        export SQMEOW_TEST_REDIS_CLUSTER_URL="redis+cluster://127.0.0.1:47000"
    fi
    if [ -n "$(docker compose ps --status running --quiet redis-sentinel 2>/dev/null)" ]; then
        export SQMEOW_TEST_REDIS_SENTINEL_URL="redis+sentinel://127.0.0.1:56391/sqmeow/0"
    fi
    if [ -n "$(docker compose ps --status running --quiet mongodb 2>/dev/null)" ]; then
        export SQMEOW_TEST_MONGODB_URL="mongodb://127.0.0.1:57017/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet scylla 2>/dev/null)" ]; then
        export SQMEOW_TEST_SCYLLA_URL="scylla://127.0.0.1:59042/"
    fi
    if [ -n "$(docker compose ps --status running --quiet cassandra 2>/dev/null)" ]; then
        export SQMEOW_TEST_CASSANDRA_URL="cassandra://127.0.0.1:59043/"
    fi
    cargo test {{cargo_flags}}

# Start the PostgreSQL, MySQL, Redis, Dragonfly, MongoDB, ScyllaDB and Cassandra servers the integration tests use.
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
    if [ -n "$(docker compose ps --status running --quiet redis-cluster 2>/dev/null)" ]; then
        export SQMEOW_TEST_REDIS_CLUSTER_URL="redis+cluster://127.0.0.1:47000"
    fi
    if [ -n "$(docker compose ps --status running --quiet redis-sentinel 2>/dev/null)" ]; then
        export SQMEOW_TEST_REDIS_SENTINEL_URL="redis+sentinel://127.0.0.1:56391/sqmeow/0"
    fi
    if [ -n "$(docker compose ps --status running --quiet mongodb 2>/dev/null)" ]; then
        export SQMEOW_TEST_MONGODB_URL="mongodb://127.0.0.1:57017/sqmeow"
    fi
    if [ -n "$(docker compose ps --status running --quiet scylla 2>/dev/null)" ]; then
        export SQMEOW_TEST_SCYLLA_URL="scylla://127.0.0.1:59042/"
    fi
    if [ -n "$(docker compose ps --status running --quiet cassandra 2>/dev/null)" ]; then
        export SQMEOW_TEST_CASSANDRA_URL="cassandra://127.0.0.1:59043/"
    fi
    nvim -l tests/minit.lua

# Regenerate doc/sqmeow.txt from the annotated sources.
docs:
    nvim -l tests/minit.lua --docs

# Fail if the committed help file is behind the sources, the way CI does.
docs-check: docs
    git diff --exit-code doc/
