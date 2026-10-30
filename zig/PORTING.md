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

Requires Zig 0.17.0. The first build downloads the prebuilt rusty_v8 archive
(about 40 MB) and checks its SHA-256. Pass `-Dv8-archive=path/to/librusty_v8.a`
to use a local copy instead. V8 is linked on Linux (glibc) and macOS, on x86_64
and aarch64. rusty_v8's Windows archive is built for MSVC, so Windows builds
have no V8 for now.

## Strategy

- **Keep V8.** rusty_v8 publishes a prebuilt static `librusty_v8.a` for each
  release. It contains V8 plus rusty_v8's `binding.cc`, which exposes V8 through
  a plain C ABI (`v8__Isolate__New`, `v8__Script__Compile`, ...). Zig can link
  the archive and call that ABI directly, so the port keeps the same engine and
  version as the Rust build (V8 15.0.245.2 from rusty_v8 150.4.0). The archive
  is C++, but it expects a few symbols from the Rust side of rusty_v8: virtual
  method trampolines for embedder classes (custom platform, inspector, value
  serializer) and the C API of `temporal_rs`, the Rust crate behind V8's
  `Temporal`. `src/v8/rust_symbols.zig` stubs all of them
  (`tools/gen_v8_stubs.sh` regenerates the list). The trampolines get real
  implementations as the port needs those classes. Temporal is disabled
  (`--no-harmony-temporal`) until `temporal_rs` is replaced, either by a Zig
  port of its C API or by a V8 build without `temporal_rs`.
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
  `libs/cli_parser`. CI fails if the generated files are stale. The argv parser
  is checked against every argv list in the Rust parser's tests (740 cases): the
  Rust parser's result for each is recorded in `src/cli/testdata`, and the Zig
  parser must produce the same values, trailing args and error messages.
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
| `src/v8/`              | the `v8` crate (rusty_v8)                     |
| `src/core/runtime.zig` | `libs/core/runtime/jsruntime.rs`              |
| `src/core/modules.zig` | `libs/core/modules` (`ModuleMap`)             |
| `src/core/url.zig`     | `resolve_import` (interim URL handling)       |
| `src/tools/run.zig`    | `cli/tools/run/mod.rs` (`run_script`)         |
| `src/tools/eval.zig`   | `cli/tools/run/mod.rs` (`eval_command`)       |
| `src/cli/golden/`      | help output of the Rust parser (generated)    |

## Roadmap

| Phase | Scope                                                                                                                                                                                             | Status |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 0     | Build setup, CI, top-level argument routing, `--version`, root `--help`                                                                                                                           | done   |
| 1     | Flag parsing: every subcommand's argument table, the argv parser, per-command help, errors and suggestions. Each subcommand's typed flags (`convert.rs`) are ported together with the subcommand. | done   |
| 2     | V8: download and link `librusty_v8.a`, Zig bindings for the C ABI, `deno eval 'console.log(1)'`                                                                                                   |        |
| 3     | Core (`libs/core`): ops, resources, event loop, ES module loading, error formatting, snapshots                                                                                                    |        |
| 4     | Extensions (`ext/`): webidl, console, url, web, timers, fs, net, fetch, http, crypto, ...                                                                                                         |        |
| 5     | Runtime (`runtime/`): permissions, main worker, web workers, `Deno` namespace                                                                                                                     |        |
| 6     | `deno run` / `deno eval` / `deno repl` for JS, then TS via transpilation                                                                                                                          |        |
| 7     | Resolution and package management: deno.json, import maps, JSR, npm, lockfile, cache                                                                                                              |        |
| 8     | Node compatibility (`ext/node`)                                                                                                                                                                   |        |
| 9     | Tooling: test, bench, fmt, lint, check, doc, compile, task, install, ...                                                                                                                          |        |
| 10    | Remove the Rust implementation                                                                                                                                                                    |        |

## Current state

- **CLI:** arguments parse exactly like the Rust parser: global flags,
  subcommands and aliases, every command's flags, and the same errors and "did
  you mean" tips. `--help` for the root and every subcommand matches the Rust
  output byte-for-byte. `--version`/`-V` work.
- **V8** is linked with Deno's V8 flags (except Temporal, see above).
- **Core:** the runtime sets up `Deno.core` and runs `libs/core`'s JavaScript
  (`00_primordials.js`, `00_infra.js`, `02_timers.js`, `01_core.js`) unmodified.
  Ops are plain Zig functions; `ops.op` generates their V8 bindings from the
  function signature, like `#[op2]`. Only the built-in ops needed so far are
  ported. V8 value predicates (`isMap`, `isTypedArray`, etc.) and
  `op_str_byte_length` now match `ops_builtin_types.rs`.
- **ES modules:** static imports from disk, `ext:core/mod.js`, the synthetic
  `ext:core/ops`, `import.meta.url`/`main`, and top-level await. Graphs are
  loaded synchronously. Dynamic `import()`, remote modules and TypeScript come
  later. Specifiers resolve with a small interim URL module until `ext/url`'s
  WHATWG parser is ported.
- **`deno run <script.js>`** (and bare `deno script.js`) runs JavaScript
  modules. **`deno eval`** runs code as the module `./$deno$eval.mts` and
  supports `--print`. Uncaught exceptions print with their stack trace and exit
  with code 1. `console` is still a temporary native one that formats values
  with `String()`, and there is no `Deno` namespace beyond `Deno.core`.
- Every other subcommand exits with "has not been ported to Zig yet".

- **Core timers:** `Deno.core.createTimer`, cancellation, repeats and ref/unref
  run through the unmodified `02_timers.js` queue with a native monotonic
  wakeup. Module evaluation drives timers and explicit microtask checkpoints;
  top-level await can settle via a timer. Callback errors reach the CLI.
  Public `setTimeout`/`setInterval` await the web extension. Async I/O,
  immediate queues and V8 platform tasks are not wired yet.
- **Ticks and rejections:** core nextTicks drain before promise continuations
  and between timer callbacks. V8 rejection notifications are tracked until
  handlers are attached or core reports them; handlers see the rejection's
  async context, and late-handler notifications are delivered. Main-module
  promises are observed by the embedder without duplicate rejection events.
  The CLI distinguishes fatal promise rejections with `(in promise)`.

Next in phase 3: immediate queues, async ops and platform tasks, then the
remaining built-in ops.
