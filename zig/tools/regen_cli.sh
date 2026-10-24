#!/usr/bin/env bash
# Copyright 2018-2026 the Deno authors. MIT license.
# Regenerates the Zig CLI tables and golden help files from the Rust
# `libs/cli_parser` sources.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build -q --manifest-path tools/cli_reference/Cargo.toml
gen=tools/cli_reference/target/debug/zig_cli_reference
"$gen" zig-defs > src/cli/defs.zig
"$gen" zig-env-vars > src/cli/env_vars.zig
rm -rf src/cli/golden
mkdir -p src/cli/golden
"$gen" goldens src/cli/golden
mkdir -p src/cli/testdata
"$gen" extract-argv ../libs/cli_parser/src/tests.rs ../libs/cli_parser/src/tests_full.rs \
  > src/cli/testdata/parse_corpus.jsonl
"$gen" parse-corpus src/cli/testdata/parse_corpus.jsonl > src/cli/testdata/parse_corpus.golden
zig fmt src/cli/defs.zig src/cli/env_vars.zig > /dev/null
