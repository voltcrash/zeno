// Copyright 2018-2026 the Deno authors. MIT license.
//! Top-level flag handling, ported from `flags_from_vec` and the dispatch in
//! `libs/cli_parser/src/convert.rs`.
//!
//! This parses argv with `parse.zig` and decides what to do: print the
//! version or help, run a subcommand, or fall back to `run`/the REPL when no
//! subcommand was given. Conversion of each subcommand's values into typed
//! flags is not ported yet.

const std = @import("std");
const Allocator = std.mem.Allocator;

const defs = @import("defs.zig");
const parse_mod = @import("parse.zig");
const types = @import("types.zig");
const CommandDef = types.CommandDef;
const Tag = types.Tag;
pub const CliError = parse_mod.CliError;
pub const ParseResult = parse_mod.ParseResult;
pub const Error = parse_mod.Error;

pub const LogLevel = enum { trace, debug, info, warn, @"error" };

pub const Action = union(enum) {
    /// `-V`: print `deno <version>`.
    version_short,
    /// `--version`: print the multi-line version info.
    version_long,
    /// `--help` or `deno help [command]`.
    help: *const CommandDef,
    /// An explicit subcommand, e.g. `deno fmt`.
    subcommand: *const CommandDef,
    /// No subcommand, but a script: `deno main.ts` is a bare `deno run`.
    default_run: []const u8,
    /// Bare `deno`: start the REPL.
    default_repl,
};

pub const Flags = struct {
    action: Action,
    log_level: ?LogLevel = null,
    /// The raw parse result, for the subcommand to convert.
    result: ParseResult,
};

/// Parse `argv` (including the binary name). On `error.InvalidArgs`, `diag`
/// describes the problem.
pub fn parse(arena: Allocator, argv: []const []const u8, diag: *CliError) Error!Flags {
    // Strip a trailing `\r` from each argument, so a shebang in a script with
    // CRLF line endings (`#!/usr/bin/env -S deno run -A\r`) works.
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, args) |a, *out| out.* = std.mem.trimEnd(u8, a, "\r");

    const result = try parse_mod.parse(arena, &defs.root, args, diag);
    var flags: Flags = .{ .action = .default_repl, .result = result };

    // A root `--version` (not a value-taking one like `upgrade --version
    // 1.2.3`). `--version` prints the long form, `-V` the short one.
    if (result.getBool("version") and result.getOne("version") == null) {
        const long = for (args) |a| {
            if (std.mem.eql(u8, a, "--version")) break true;
        } else false;
        flags.action = if (long) .version_long else .version_short;
        return flags;
    }

    if (result.contains("help")) {
        flags.action = .{ .help = result.subcommand orelse &defs.root };
        return flags;
    }

    if (result.getOne("log-level")) |level| {
        flags.log_level = std.meta.stringToEnum(LogLevel, level);
    }
    if (result.getBool("quiet")) flags.log_level = .@"error";

    const sub = result.subcommand orelse {
        flags.action = try defaultAction(arena, &result, diag);
        return flags;
    };
    flags.action = if (sub.tag.? == .help)
        .{ .help = if (result.getOne("subcommand")) |name| defs.root.findSubcommand(name) orelse &defs.root else &defs.root }
    else
        .{ .subcommand = sub };
    return flags;
}

/// Commands that, given as the script of a bare `deno` invocation, mean a
/// non-global flag was placed before the subcommand.
const known_subcommands = [_][]const u8{
    "run",      "watch",    "serve",   "eval",      "fmt",
    "lint",     "test",     "upgrade", "cache",     "check",
    "info",     "doc",      "task",    "bench",     "compile",
    "coverage", "repl",     "install", "uninstall", "completions",
    "init",     "create",   "jupyter", "publish",   "add",
    "remove",   "outdated", "update",  "clean",     "approve-scripts",
    "types",    "lsp",      "vendor",  "deploy",    "sandbox",
    "bundle",   "audit",    "x",
};

fn isGlobalName(name: []const u8) bool {
    for ([_][]const u8{ "script_arg", "log-level", "quiet", "unstable" }) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

/// Port of `default_parse`: no subcommand was given.
fn defaultAction(arena: Allocator, result: *const ParseResult, diag: *CliError) Error!Action {
    if (result.getOne("script_arg")) |script| {
        if (isKnownSubcommand(script)) try checkFlagsBeforeSubcommand(arena, result, script, diag);
        return .{ .default_run = script };
    }

    // Flags that indicate the user meant to run a script but forgot it.
    const has_v8_help = if (result.getMany("v8-flags")) |v| for (v) |f| {
        if (std.mem.eql(u8, f, "--help")) break true;
    } else false else false;
    const has_run_flags = result.getBool("no-config") or
        for ([_][]const u8{
            "config", "import-map", "no-remote", "no-npm",
            "lock",   "no-lock",    "reload",    "frozen-lockfile",
            "cert",   "check",      "no-check",
        }) |name| {
            if (result.contains(name)) break true;
        } else false;
    if (has_run_flags and !has_v8_help) {
        diag.* = .{
            .kind = .MissingRequired,
            .message = "[SCRIPT_ARG] may only be omitted with --v8-flags=--help, else to use the repl with arguments, please use the `deno repl` subcommand\n\nUsage: deno [OPTIONS] [COMMAND] [SCRIPT_ARG]...",
        };
        return error.InvalidArgs;
    }
    return .default_repl;
}

fn isKnownSubcommand(name: []const u8) bool {
    for (known_subcommands) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// `deno --allow-net fmt`: a non-global flag before the subcommand name made
/// the parser treat the subcommand as a script.
fn checkFlagsBeforeSubcommand(arena: Allocator, result: *const ParseResult, script: []const u8, diag: *CliError) Error!void {
    const run = defs.root.findSubcommand("run").?;
    var first_flag: ?[]const u8 = null;
    var any = false;
    for (result.args.items) |a| {
        if (!a.is_present or isGlobalName(a.name)) continue;
        any = true;
        if (first_flag != null) continue;
        var it = run.allArgs();
        while (it.next()) |def| {
            if (std.mem.eql(u8, def.name, a.name)) {
                if (def.long) |l| first_flag = try std.fmt.allocPrint(arena, "--{s}", .{l});
                break;
            }
        }
    }
    if (!any) return;
    const flag = first_flag orelse "unknown";
    diag.* = .{
        .kind = .UnknownFlag,
        .message = try std.fmt.allocPrint(arena, "unexpected argument '{s}' found", .{flag}),
    };
    // Only claim `<subcommand> <flag>` exists when the subcommand accepts it.
    if (defs.root.findSubcommand(script)) |sub| {
        if (sub.findArgLong(std.mem.trimStart(u8, flag, "-")) != null) {
            diag.suggestion = try std.fmt.allocPrint(arena, "'{s} {s}' exists", .{ script, flag });
        }
    }
    return error.InvalidArgs;
}

// ------------------------------------------------------------------ tests

const TestCtx = struct {
    arena: std.heap.ArenaAllocator,
    diag: CliError = undefined,

    fn init() TestCtx {
        return .{ .arena = .init(std.testing.allocator) };
    }

    fn deinit(self: *TestCtx) void {
        self.arena.deinit();
    }

    fn parse(self: *TestCtx, args: []const []const u8) Error!Flags {
        const argv = try self.arena.allocator().alloc([]const u8, args.len + 1);
        argv[0] = "deno";
        @memcpy(argv[1..], args);
        return @import("flags.zig").parse(self.arena.allocator(), argv, &self.diag);
    }
};

fn expectSubcommand(args: []const []const u8, tag: Tag) !void {
    var t: TestCtx = .init();
    defer t.deinit();
    const f = try t.parse(args);
    try std.testing.expectEqual(tag, f.action.subcommand.tag.?);
}

fn expectHelp(args: []const []const u8, tag: ?Tag) !void {
    var t: TestCtx = .init();
    defer t.deinit();
    const f = try t.parse(args);
    try std.testing.expectEqual(tag, f.action.help.tag);
}

fn expectAction(args: []const []const u8, action: std.meta.Tag(Action)) !void {
    var t: TestCtx = .init();
    defer t.deinit();
    const f = try t.parse(args);
    try std.testing.expectEqual(action, std.meta.activeTag(f.action));
}

test "bare deno starts the repl" {
    try expectAction(&.{}, .default_repl);
}

test "subcommands and aliases" {
    try expectSubcommand(&.{"fmt"}, .fmt);
    try expectSubcommand(&.{ "run", "main.ts" }, .run);
    try expectSubcommand(&.{ "i", "npm:chalk" }, .install);
    try expectSubcommand(&.{ "rm", "chalk" }, .remove);
    try expectSubcommand(&.{"approve-builds"}, .approve_scripts);
    try expectSubcommand(&.{"bump-version"}, .bump_version);
}

test "global flags" {
    var t: TestCtx = .init();
    defer t.deinit();
    const f = try t.parse(&.{ "--log-level", "debug", "fmt", "--check" });
    try std.testing.expectEqual(Tag.fmt, f.action.subcommand.tag.?);
    try std.testing.expectEqual(LogLevel.debug, f.log_level.?);
    try std.testing.expect(f.result.getBool("check"));

    // `--quiet` wins over `--log-level`.
    const g = try t.parse(&.{ "-Linfo", "-q", "test" });
    try std.testing.expectEqual(LogLevel.@"error", g.log_level.?);
}

test "script without subcommand defaults to run" {
    var t: TestCtx = .init();
    defer t.deinit();
    const f = try t.parse(&.{ "-A", "main.ts", "arg" });
    try std.testing.expectEqualStrings("main.ts", f.action.default_run);
    try std.testing.expect(f.result.getBool("allow-all"));
    try std.testing.expectEqual(@as(usize, 1), f.result.trailing.items.len);
}

test "non-global flag before a subcommand" {
    var t: TestCtx = .init();
    defer t.deinit();
    try std.testing.expectError(error.InvalidArgs, t.parse(&.{ "--allow-net", "test" }));
    try std.testing.expectEqualStrings("unexpected argument '--allow-net' found", t.diag.message);
    try std.testing.expectEqualStrings("'test --allow-net' exists", t.diag.suggestion.?);

    try std.testing.expectError(error.InvalidArgs, t.parse(&.{ "--allow-net", "fmt" }));
    try std.testing.expectEqual(@as(?[]const u8, null), t.diag.suggestion);
}

test "repl flags without a script" {
    var t: TestCtx = .init();
    defer t.deinit();
    try std.testing.expectError(error.InvalidArgs, t.parse(&.{"--reload"}));
    try std.testing.expectEqual(parse_mod.ErrorKind.MissingRequired, t.diag.kind);
    try expectAction(&.{ "--reload", "--v8-flags=--help" }, .default_repl);
}

test "version flags" {
    try expectAction(&.{"--version"}, .version_long);
    try expectAction(&.{"-V"}, .version_short);
    try expectAction(&.{"-v"}, .version_short);
    try expectAction(&.{ "fmt", "--version" }, .version_long);
    // `upgrade --version` selects a version to upgrade to.
    try expectSubcommand(&.{ "upgrade", "--version", "2.0.0" }, .upgrade);
}

test "help" {
    try expectHelp(&.{"--help"}, null);
    try expectHelp(&.{"-h"}, null);
    try expectHelp(&.{ "fmt", "-h" }, .fmt);
    try expectHelp(&.{ "help", "lint" }, .lint);
    try expectHelp(&.{"help"}, null);
    try expectHelp(&.{ "help", "nope" }, null);
    try expectHelp(&.{ "help", "--help" }, .help);
    // After the script, `--help` belongs to the script.
    try expectSubcommand(&.{ "run", "main.ts", "--help" }, .run);
    // Passthrough commands forward `--help`.
    try expectSubcommand(&.{ "deploy", "--help" }, .deploy);
}

test "trailing carriage returns are stripped" {
    var t: TestCtx = .init();
    defer t.deinit();
    const f = try t.parse(&.{ "run", "--allow-net\r", "script.ts" });
    try std.testing.expect(f.result.getBool("allow-net"));
}

test "invalid values" {
    var t: TestCtx = .init();
    defer t.deinit();
    try std.testing.expectError(error.InvalidArgs, t.parse(&.{ "--log-level", "loud" }));
    try std.testing.expectEqual(parse_mod.ErrorKind.InvalidValue, t.diag.kind);
    try std.testing.expectError(error.InvalidArgs, t.parse(&.{"--log-level"}));
    try std.testing.expectEqual(parse_mod.ErrorKind.MissingValue, t.diag.kind);
}
