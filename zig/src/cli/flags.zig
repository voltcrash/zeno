// Copyright 2018-2026 the Deno authors. MIT license.
//! Top-level argument routing, ported from `resolve_subcommand` in
//! `libs/cli_parser/src/parse.rs` and the dispatch in `convert.rs`.
//!
//! This walks past global flags to find the subcommand (if any), and
//! recognizes `--help` / `--version`. Parsing of each subcommand's own flags
//! is not ported yet; the remaining argv is handed to the subcommand as-is.

const std = @import("std");
const types = @import("types.zig");
const Arg = types.Arg;
const Command = types.Command;
const Tag = types.Tag;
const command_table = @import("command_table.zig");
const global_args = @import("global_args.zig");

pub const LogLevel = enum { trace, debug, info };

pub const Action = union(enum) {
    /// `-V`: print `deno <version>`.
    version_short,
    /// `--version`: print the multi-line version info.
    version_long,
    /// `--help` / `deno help [command]`. `null` means the root help.
    help: ?Command,
    /// An explicit subcommand, e.g. `deno fmt`.
    subcommand: Command,
    /// No subcommand given, but there are arguments: `deno script.ts`
    /// behaves like `deno run script.ts`.
    default_run,
    /// Bare `deno`: start the REPL.
    default_repl,
};

pub const Flags = struct {
    action: Action,
    log_level: ?LogLevel = null,
    quiet: bool = false,
    /// Arguments following the subcommand token (or, for `default_run`, all
    /// arguments, including any non-global flags).
    args: []const []const u8 = &.{},
};

/// Details for a parse error, rendered by `Diagnostic.print`.
pub const Diagnostic = struct {
    kind: Kind = .missing_value,
    /// Long name of the flag, without the leading `--`.
    flag: []const u8 = "",
    value: []const u8 = "",
    choices: []const []const u8 = &.{},

    pub const Kind = enum { missing_value, invalid_value };

    pub fn print(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .missing_value => try w.print(
                "error: a value is required for '--{s}' but none was supplied\n",
                .{self.flag},
            ),
            .invalid_value => {
                try w.print(
                    "error: invalid value '{s}' for '--{s}': possible values: ",
                    .{ self.value, self.flag },
                );
                for (self.choices, 0..) |c, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(c);
                }
                try w.writeByte('\n');
            },
        }
    }
};

pub const Error = error{InvalidArgs};

/// Parse `args` (argv without the binary name).
pub fn parse(args: []const []const u8, diag: *Diagnostic) Error!Flags {
    var state: State = .{};

    var i: usize = 0;
    const sub: ?Command = while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break null;

        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const def = findGlobalLong(body[0 .. eq orelse body.len]) orelse break null;
            i += 1;
            var value: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
            if (value == null and def.takesSeparateValue()) {
                if (i >= args.len) return missingValue(diag, def);
                value = args[i];
                i += 1;
            }
            try applyGlobal(&state, def, value, true, diag);
        } else if (arg.len > 1 and arg[0] == '-') {
            if (!try parseShortCluster(&state, args, &i, diag)) break null;
        } else {
            break findCommand(arg);
        }
    } else null;

    var flags = state.flags;
    var help = state.help;
    var version = state.version;
    if (sub) |cmd| {
        flags.args = args[i + 1 ..];
        if (cmd.tag == .help) {
            flags.action = .{ .help = if (flags.args.len > 0) findCommand(flags.args[0]) else null };
            return flags;
        }
        scanSubcommandArgs(cmd, flags.args, &help, &version);
        if (version) |v| {
            flags.action = v;
        } else if (help) {
            flags.action = .{ .help = cmd };
        } else {
            flags.action = .{ .subcommand = cmd };
        }
        return flags;
    }

    flags.args = args[i..];
    if (version) |v| {
        flags.action = v;
    } else if (help) {
        flags.action = .{ .help = null };
    } else if (flags.args.len > 0) {
        flags.action = .default_run;
    } else {
        flags.action = .default_repl;
    }
    return flags;
}

/// Look for `--help` / `--version` among a subcommand's arguments, stopping
/// where the arguments start being forwarded to the program being run.
fn scanSubcommandArgs(cmd: Command, args: []const []const u8, help: *bool, version: *?Action) void {
    if (cmd.passthrough) return;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or
            std.mem.startsWith(u8, arg, "--help="))
        {
            help.* = true;
        } else if (cmd.tag != .upgrade and std.mem.eql(u8, arg, "--version")) {
            // `deno upgrade --version <v>` has its own `--version` flag.
            version.* = .version_long;
        } else if (cmd.tag != .upgrade and (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "-v"))) {
            version.* = .version_short;
        } else if (arg.len == 0 or arg[0] != '-') {
            // The first positional of a trailing command starts the
            // arguments forwarded to the script.
            if (cmd.trailing) return;
        }
    }
}

const State = struct {
    flags: Flags = .{ .action = .default_repl },
    help: bool = false,
    version: ?Action = null,
};

/// Parse a cluster of short global flags such as `-q`, `-qL debug` or
/// `-Ldebug`, advancing `i` past it (and past a separate value). Returns false
/// without consuming anything if the cluster contains a non-global flag, which
/// leaves it for the subcommand to parse.
fn parseShortCluster(state: *State, args: []const []const u8, i: *usize, diag: *Diagnostic) Error!bool {
    const arg = args[i.*];
    for (arg[1..]) |c| {
        const def = findGlobalShort(c) orelse return false;
        // Whatever follows a flag that takes a value is that value.
        if (def.takesSeparateValue()) break;
    }
    i.* += 1;
    for (arg[1..], 1..) |c, j| {
        const def = findGlobalShort(c).?;
        if (def.takesSeparateValue()) {
            // The value is either the rest of the cluster or the next arg.
            var value: []const u8 = arg[j + 1 ..];
            if (value.len == 0) {
                if (i.* >= args.len) return missingValue(diag, def);
                value = args[i.*];
                i.* += 1;
            }
            try applyGlobal(state, def, value, false, diag);
            return true;
        }
        try applyGlobal(state, def, null, false, diag);
    }
    return true;
}

fn applyGlobal(state: *State, def: Arg, value: ?[]const u8, long_form: bool, diag: *Diagnostic) Error!void {
    const name = def.name;
    if (std.mem.eql(u8, name, "help")) {
        state.help = true;
    } else if (std.mem.eql(u8, name, "version")) {
        state.version = if (long_form) .version_long else .version_short;
    } else if (std.mem.eql(u8, name, "quiet")) {
        state.flags.quiet = true;
    } else if (std.mem.eql(u8, name, "log-level")) {
        const v = value.?;
        state.flags.log_level = std.meta.stringToEnum(LogLevel, v) orelse {
            diag.* = .{ .kind = .invalid_value, .flag = def.long.?, .value = v, .choices = def.choices };
            return error.InvalidArgs;
        };
    } else if (std.mem.eql(u8, name, "env-file")) {
        // TODO(zig-port): load env files once the runtime is ported.
    }
}

fn missingValue(diag: *Diagnostic, def: Arg) Error {
    diag.* = .{ .kind = .missing_value, .flag = def.long.? };
    return error.InvalidArgs;
}

fn findGlobalLong(name: []const u8) ?Arg {
    for (global_args.all) |a| if (a.matchesLong(name)) return a;
    return null;
}

fn findGlobalShort(c: u8) ?Arg {
    for (global_args.all) |a| if (a.matchesShort(c)) return a;
    return null;
}

pub fn findCommand(name: []const u8) ?Command {
    for (command_table.all) |c| if (c.matches(name)) return c;
    return null;
}

// ------------------------------------------------------------------ tests

fn testParse(args: []const []const u8) !Flags {
    var diag: Diagnostic = .{};
    return parse(args, &diag);
}

fn expectSubcommand(args: []const []const u8, tag: Tag) !void {
    const f = try testParse(args);
    try std.testing.expectEqual(tag, f.action.subcommand.tag);
}

test "bare deno starts the repl" {
    const f = try testParse(&.{});
    try std.testing.expectEqual(Action.default_repl, f.action);
}

test "subcommands and aliases" {
    try expectSubcommand(&.{"fmt"}, .fmt);
    try expectSubcommand(&.{ "run", "main.ts" }, .run);
    try expectSubcommand(&.{ "i", "npm:chalk" }, .install);
    try expectSubcommand(&.{ "rm", "chalk" }, .remove);
    try expectSubcommand(&.{"approve-builds"}, .approve_scripts);
    try expectSubcommand(&.{"bump-version"}, .bump_version);
}

test "global flags before the subcommand" {
    const f = try testParse(&.{ "-q", "--log-level", "debug", "fmt", "--check" });
    try std.testing.expectEqual(Tag.fmt, f.action.subcommand.tag);
    try std.testing.expect(f.quiet);
    try std.testing.expectEqual(LogLevel.debug, f.log_level.?);
    try std.testing.expectEqual(@as(usize, 1), f.args.len);
    try std.testing.expectEqualStrings("--check", f.args[0]);

    const g = try testParse(&.{ "-Linfo", "--env-file=.env", "test" });
    try std.testing.expectEqual(Tag.@"test", g.action.subcommand.tag);
    try std.testing.expectEqual(LogLevel.info, g.log_level.?);
}

test "script without subcommand defaults to run" {
    const f = try testParse(&.{ "main.ts", "arg" });
    try std.testing.expectEqual(Action.default_run, f.action);
    try std.testing.expectEqual(@as(usize, 2), f.args.len);

    // Non-global flags stop subcommand resolution.
    const g = try testParse(&.{ "--allow-net", "fmt" });
    try std.testing.expectEqual(Action.default_run, g.action);
    try std.testing.expectEqual(@as(usize, 2), g.args.len);
}

test "version flags" {
    try std.testing.expectEqual(Action.version_long, (try testParse(&.{"--version"})).action);
    try std.testing.expectEqual(Action.version_short, (try testParse(&.{"-V"})).action);
    try std.testing.expectEqual(Action.version_short, (try testParse(&.{"-v"})).action);
    try std.testing.expectEqual(Action.version_long, (try testParse(&.{ "fmt", "--version" })).action);
    // `upgrade --version` selects a version to upgrade to.
    try expectSubcommand(&.{ "upgrade", "--version", "2.0.0" }, .upgrade);
}

test "help flags" {
    try std.testing.expectEqual(@as(?Command, null), (try testParse(&.{"--help"})).action.help);
    try std.testing.expectEqual(@as(?Command, null), (try testParse(&.{"-h"})).action.help);
    try std.testing.expectEqual(Tag.fmt, (try testParse(&.{ "fmt", "-h" })).action.help.?.tag);
    try std.testing.expectEqual(Tag.lint, (try testParse(&.{ "help", "lint" })).action.help.?.tag);
    try std.testing.expectEqual(@as(?Command, null), (try testParse(&.{"help"})).action.help);
    // After the script, `--help` belongs to the script.
    try expectSubcommand(&.{ "run", "main.ts", "--help" }, .run);
    try expectSubcommand(&.{ "fmt", "--", "--help" }, .fmt);
    // Passthrough commands never see `--help`.
    try expectSubcommand(&.{ "deploy", "--help" }, .deploy);
}

test "invalid global flag values" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidArgs, parse(&.{ "--log-level", "loud" }, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.invalid_value, diag.kind);
    try std.testing.expectEqualStrings("loud", diag.value);

    try std.testing.expectError(error.InvalidArgs, parse(&.{"--log-level"}, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.missing_value, diag.kind);
}
