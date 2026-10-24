# Porting Deno to Zig

This directory holds a port of the Deno CLI from Rust to Zig. The port is
incremental: the Rust implementation stays in the tree as the reference until
each piece is replaced, and every step lands as its own small PR against `main`.

```sh
cd zig
zig build              # builds zig-out/bin/deno
zig build test         # unit tests
zig build run -- --help
```

Requires Zig 0.17.0.

## Strategy

- **Keep V8.** rusty_v8 publishes a prebuilt static `librusty_v8.a` for each
  release. It contains V8 plus rusty_v8's `binding.cc`, which exposes V8 through
  a plain C ABI (`v8__Isolate__New`, `v8__Script__Compile`, ...). Zig can link
  the archive and call that ABI directly, so the port keeps the same engine and
  version as the Rust build (V8 15.0.245.2 from rusty_v8 150.4.0). That archive
  is C++, not Rust.
- **Reuse the JavaScript.** Much of Deno's runtime is already JavaScript or
  TypeScript (`ext/*/*.js`, `runtime/js`, `cli/js`, `cli/tsc`). Those files are
  used as-is. Only the Rust parts (ops, the event loop, module loading, tooling)
  get rewritten.
- **Port the behavior, check it against Rust.** Each ported component gets tests
  that compare against the Rust implementation. For example, the root `--help`
  output is checked byte-for-byte against a golden file rendered by
  `libs/cli_parser`. `tools/cli_reference` compiles the dependency-free parts of
  the Rust parser (without building the rest of Deno) to generate the Zig
  command tables and golden help files; run `tools/regen_cli.sh` after changing
  `libs/cli_parser`. CI fails if the generated files are stale.
- **Third-party Rust crates** (swc, dprint, deno_lint, deno_graph, tokio, hyper,
  rustls, ...) are the hardest part. Each one gets a plan when its phase comes
  up: Zig's std library where it covers the need (networking, TLS, compression,
  hashing), C libraries where one fits, the bundled TypeScript compiler in JS
  for transpiling until a native type-stripper exists, or a direct port.

## Layout

| Zig                    | Ported from                                   |
| ---------------------- | --------------------------------------------- |
| `src/main.zig`         | `cli/main.rs`, `cli/lib.rs`                   |
| `src/version.zig`      | `cli/lib/version.rs`                          |
| `src/cli/types.zig`    | `libs/cli_parser/src/types.rs`                |
| `src/cli/defs.zig`     | `libs/cli_parser/src/defs.rs` (generated)     |
| `src/cli/env_vars.zig` | `libs/cli_parser/src/env_vars.rs` (generated) |
| `src/cli/flags.zig`    | `libs/cli_parser/src/{parse,convert}.rs`      |
| `src/cli/help.zig`     | `libs/cli_parser/src/help.rs`                 |
| `src/cli/golden/`      | help output of the Rust parser (generated)    |

## Roadmap

| Phase | Scope                                                                                                              | Status      |
| ----- | ------------------------------------------------------------------------------------------------------------------ | ----------- |
| 0     | Build setup, CI, top-level argument routing, `--version`, root `--help`                                            | done        |
| 1     | Full flag parsing: every subcommand's argument table, `Flags` conversion, per-command help, errors and suggestions | in progress |
| 2     | V8: download and link `librusty_v8.a`, Zig bindings for the C ABI, `deno eval 'console.log(1)'`                    |             |
| 3     | Core (`libs/core`): ops, resources, event loop, ES module loading, error formatting, snapshots                     |             |
| 4     | Extensions (`ext/`): webidl, console, url, web, timers, fs, net, fetch, http, crypto, ...                          |             |
| 5     | Runtime (`runtime/`): permissions, main worker, web workers, `Deno` namespace                                      |             |
| 6     | `deno run` / `deno eval` / `deno repl` for JS, then TS via transpilation                                           |             |
| 7     | Resolution and package management: deno.json, import maps, JSR, npm, lockfile, cache                               |             |
| 8     | Node compatibility (`ext/node`)                                                                                    |             |
| 9     | Tooling: test, bench, fmt, lint, check, doc, compile, task, install, ...                                           |             |
| 10    | Remove the Rust implementation                                                                                     |             |

## Current state

Command-line routing works: global flags, subcommands and aliases,
`deno <script>` defaulting to `run`, bare `deno` meaning the REPL,
`--help`/`help <command>`, and `--version`/`-V`. Every command's argument table
is ported, and `--help` for the root and all subcommands matches the Rust output
byte-for-byte. Every subcommand exits with "has not been ported to Zig yet".

Phase 1 next steps: port the generic argv parser (`parse.rs`), then the
conversion into typed `Flags` (`convert.rs`) along with its tests.
