# Everything CI runs, runnable locally with the same command.

default: lint test

# Clone the test and documentation dependency.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -d .deps/mini.nvim ]; then
        git -C .deps/mini.nvim pull --quiet
    else
        git clone --filter=blob:none --depth 1 https://github.com/nvim-mini/mini.nvim .deps/mini.nvim
    fi

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

fmt:
    cargo fmt --all
    stylua .

test: test-rust test-lua

test-rust:
    cargo test --all-features

# Needs a built engine, so build first.
test-lua: build-debug
    nvim --headless -u tests/minimal_init.lua -c "lua require('mini.test').setup(); MiniTest.run()"

# Regenerate doc/sqmeow.txt from the annotated sources.
docs:
    nvim --headless -u scripts/minidoc_init.lua -c "lua require('mini.doc').generate()" -c "qa!"
