// Copyright 2018-2026 the Deno authors. MIT license.
//! The argv parser, ported from `libs/cli_parser/src/parse.rs` (with the
//! `ParseResult` type from `types.rs` and `CliError` from `error.rs`).
//!
//! It walks argv left-to-right, matches subcommands and flags against the
//! static `CommandDef` tables, and produces a `ParseResult` holding the raw
//! values. Turning that into typed flags is a separate step.
//!
//! Allocations are expected to come from an arena: nothing is freed
//! individually. Values are slices of the input argv where possible.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Arg = types.Arg;
const CommandDef = types.CommandDef;
const ValueParser = types.ValueParser;

pub const ErrorKind = enum {
    UnknownFlag,
    UnknownSubcommand,
    MissingRequired,
    MissingValue,
    InvalidValue,
    DisplayVersion,
    DisplayHelp,
    TooManyValues,
    UnexpectedPositional,
};

pub const CliError = struct {
    kind: ErrorKind,
    message: []const u8,
    suggestion: ?[]const u8 = null,

    /// Rendered like the Rust `Display` impl: `error: <message>`, plus a
    /// tip when there is a suggestion.
    pub fn format(self: CliError, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("error: {s}", .{self.message});
        if (self.suggestion) |s| try w.print("\n\n  tip: {s}", .{s});
    }
};

pub const Error = error{ InvalidArgs, OutOfMemory };

/// A single parsed argument with its values.
pub const ParsedArg = struct {
    name: []const u8,
    values: std.ArrayList([]const u8) = .empty,
    is_present: bool = false,
    count: usize = 0,
};

/// Result of parsing: the raw values before conversion to typed flags.
pub const ParseResult = struct {
    /// Which subcommand was matched (null if default/root).
    subcommand: ?*const CommandDef = null,
    /// Parsed arguments, in the order they were first seen.
    args: std.ArrayList(ParsedArg) = .empty,
    /// Remaining positional args after `--`, or trailing var args.
    trailing: std.ArrayList([]const u8) = .empty,

    fn find(self: *const ParseResult, name: []const u8) ?*ParsedArg {
        for (self.args.items) |*a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }

    /// Whether a flag was set.
    pub fn getBool(self: *const ParseResult, name: []const u8) bool {
        return self.contains(name);
    }

    /// The first value of an arg.
    pub fn getOne(self: *const ParseResult, name: []const u8) ?[]const u8 {
        const a = self.find(name) orelse return null;
        return if (a.values.items.len > 0) a.values.items[0] else null;
    }

    /// All values of an arg (for append actions or multi-value args).
    pub fn getMany(self: *const ParseResult, name: []const u8) ?[]const []const u8 {
        const a = self.find(name) orelse return null;
        return if (a.is_present) a.values.items else null;
    }

    /// Whether an arg was provided on the command line.
    pub fn contains(self: *const ParseResult, name: []const u8) bool {
        const a = self.find(name) orelse return false;
        return a.is_present;
    }

    /// The count of a count-action arg.
    pub fn getCount(self: *const ParseResult, name: []const u8) usize {
        const a = self.find(name) orelse return 0;
        return a.count;
    }
};

/// Parses command-line arguments against a command definition.
const Parser = struct {
    arena: Allocator,
    result: ParseResult = .{},
    diag: *CliError,

    fn fail(self: *Parser, kind: ErrorKind, comptime fmt: []const u8, args: anytype) Error {
        self.diag.* = .{ .kind = kind, .message = try std.fmt.allocPrint(self.arena, fmt, args) };
        return error.InvalidArgs;
    }

    fn entry(self: *Parser, def: *const Arg) Allocator.Error!*ParsedArg {
        if (self.result.find(def.name)) |a| return a;
        try self.result.args.append(self.arena, .{ .name = def.name });
        return &self.result.args.items[self.result.args.items.len - 1];
    }

    /// Mark a flag as present.
    fn setBool(self: *Parser, def: *const Arg) Allocator.Error!void {
        const a = try self.entry(def);
        a.is_present = true;
        a.count += 1;
    }

    fn incrementCount(self: *Parser, def: *const Arg) Allocator.Error!void {
        return self.setBool(def);
    }

    /// Add a value, validating it against the arg's value parser first.
    fn setValue(self: *Parser, def: *const Arg, value: []const u8) Error!void {
        if (def.value_parser) |vp| {
            const flag = if (def.long) |l| try std.fmt.allocPrint(self.arena, "--{s}", .{l}) else def.name;
            try self.validate(vp, value, flag);
        }
        const existing = self.result.find(def.name);
        const a = try self.entry(def);
        if (existing == null) a.count = 1;
        a.is_present = true;
        // For `set`, the last value wins.
        if (def.action == .set) a.values.clearRetainingCapacity();
        try a.values.append(self.arena, value);
    }

    /// Apply a value, splitting it by the arg's delimiter if it has one.
    fn applyValue(self: *Parser, def: *const Arg, value: []const u8) Error!void {
        const delim = def.value_delimiter orelse return self.setValue(def, value);
        // An empty value (e.g. `--flag=`) is kept as an empty string.
        if (value.len == 0) return self.setValue(def, value);
        var parts = std.mem.splitScalar(u8, value, delim);
        while (parts.next()) |part| try self.setValue(def, part);
    }

    fn validate(self: *Parser, vp: ValueParser, value: []const u8, flag: []const u8) Error!void {
        const ok = switch (vp) {
            .choices => |choices| for (choices) |c| {
                if (std.mem.eql(u8, c, value)) break true;
            } else false,
            .bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false"),
            .u8 => parseUnsigned(u8, value) != null,
            .u16 => parseUnsigned(u16, value) != null,
            .u32 => parseUnsigned(u32, value) != null,
            .u64 => parseUnsigned(u64, value) != null,
            .usize => parseUnsigned(usize, value) != null,
            .non_zero_u8 => (parseUnsigned(u8, value) orelse 0) != 0,
            .non_zero_u32 => (parseUnsigned(u32, value) orelse 0) != 0,
            .non_zero_usize => (parseUnsigned(usize, value) orelse 0) != 0,
            .u32_range => |r| if (parseUnsigned(u32, value)) |n| n >= r.lo and n <= r.hi else false,
        };
        if (ok) return;
        switch (vp) {
            .choices => |choices| {
                const joined = try std.mem.join(self.arena, ", ", choices);
                return self.fail(.InvalidValue, "invalid value '{s}' for '{s}': possible values: {s}", .{ value, flag, joined });
            },
            .u32_range => |r| return self.fail(.InvalidValue, "invalid value '{s}' for '{s}': must be in range {d}..={d}", .{ value, flag, r.lo, r.hi }),
            else => return self.fail(.InvalidValue, "invalid value '{s}' for '{s}'", .{ value, flag }),
        }
    }

    fn unknownFlag(self: *Parser, flag: []const u8, cmd: *const CommandDef) Error {
        self.diag.* = .{
            .kind = .UnknownFlag,
            .message = try std.fmt.allocPrint(self.arena, "unexpected argument '{s}' found", .{flag}),
        };
        if (try findClosestFlag(self.arena, flag, cmd)) |s| {
            self.diag.suggestion = try std.fmt.allocPrint(self.arena, "a similar argument exists: '{s}'", .{s});
        }
        return error.InvalidArgs;
    }

    fn missingValue(self: *Parser, flag: []const u8) Error {
        return self.fail(.MissingValue, "a value is required for '{s}' but none was supplied", .{flag});
    }

    fn parseArgs(
        self: *Parser,
        cmd: *const CommandDef,
        root: *const CommandDef,
        args: []const []const u8,
        skip_subcommand: ?[]const u8,
    ) Error!void {
        var i: usize = 0;
        var positional_index: usize = 0;
        var trailing_mode = false;
        // Set when `--` appears before the first positional: the remaining
        // args fill the positionals literally (a leading hyphen is not a flag).
        var positional_only = false;
        // Whether any positional value has been consumed yet.
        var positional_started = false;
        var found_subcommand = skip_subcommand == null;
        var passthrough_from: ?usize = null;
        // Per-positional trailing: when set, all remaining args (including
        // flags) go into this positional's values.
        var positional_trailing: ?*const Arg = null;

        var positionals: std.ArrayList(*const Arg) = .empty;
        var it = cmd.allArgs();
        while (it.next()) |a| if (a.positional) try positionals.append(self.arena, a);
        const pos_defs = positionals.items;

        while (i < args.len) {
            const arg = args[i];

            // Per-positional trailing mode: absorb everything into this
            // positional. This always strips `--`, which is only correct
            // because no command with a `.trailing` positional keeps `--`.
            if (positional_trailing) |trail| {
                std.debug.assert(!cmd.keep_double_dash);
                if (eql(arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) try self.setValue(trail, args[i]);
                    continue;
                }
                try self.setValue(trail, arg);
                i += 1;
                continue;
            }

            // Positional-only mode: a `--` appeared before the first
            // positional of an entrypoint-style command, so consume
            // positionals without treating leading hyphens as flags (e.g.
            // `deno run -- -script.ts`). Only the first `--` is special.
            if (positional_only) {
                if (positional_index < pos_defs.len) {
                    const pos = pos_defs[positional_index];
                    try self.applyValue(pos, arg);
                    if (!isMulti(pos)) positional_index += 1;
                } else {
                    // Only entered when `cmd.trailing_var_arg` is set.
                    try self.result.trailing.append(self.arena, arg);
                }
                i += 1;
                continue;
            }

            // After `--`, everything is trailing.
            if (trailing_mode) {
                try self.result.trailing.append(self.arena, arg);
                i += 1;
                continue;
            }

            if (eql(arg, "--")) {
                // If the next positional is `trailing`, args after `--` go
                // into it rather than into `result.trailing`.
                if (positional_index < pos_defs.len and pos_defs[positional_index].trailing) {
                    positional_trailing = pos_defs[positional_index];
                    i += 1;
                    continue;
                }
                // For entrypoint-style commands (a single-value positional
                // followed by trailing var args: run/serve/eval/task/compile),
                // a `--` before the first positional marks the rest as
                // positional-only, so the entrypoint may start with a hyphen.
                // Commands with a multi-value positional (test/bench/install)
                // keep args after `--` trailing instead.
                if (!positional_started and cmd.trailing_var_arg and
                    positional_index < pos_defs.len and !isMulti(pos_defs[positional_index]))
                {
                    positional_only = true;
                    i += 1;
                    continue;
                }
                trailing_mode = true;
                // Keep the `--` in the forwarded args for subcommands that
                // mirror clap's `.last(true)`; strip it otherwise.
                if (cmd.keep_double_dash) try self.result.trailing.append(self.arena, arg);
                i += 1;
                continue;
            }

            // Skip the subcommand token when we encounter it.
            if (!found_subcommand and !std.mem.startsWith(u8, arg, "-") and cmd.matches(arg)) {
                found_subcommand = true;
                if (cmd.passthrough) {
                    passthrough_from = i + 1;
                    break;
                }
                i += 1;
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--")) {
                i = try self.parseLongFlag(cmd, root, args, i);
            } else if (arg.len > 1 and arg[0] == '-') {
                i = try self.parseShortFlag(cmd, root, args, i);
            } else if (positional_index < pos_defs.len) {
                const pos = pos_defs[positional_index];
                positional_started = true;
                try self.applyValue(pos, arg);

                // A trailing positional absorbs everything that follows.
                if (pos.trailing) {
                    positional_trailing = pos;
                    i += 1;
                    continue;
                }

                if (!isMulti(pos)) {
                    positional_index += 1;

                    if (positional_index < pos_defs.len and pos_defs[positional_index].trailing) {
                        positional_trailing = pos_defs[positional_index];
                        i += 1;
                        continue;
                    }

                    // After the last positional of a trailing_var_arg command,
                    // everything remaining is forwarded.
                    if (cmd.trailing_var_arg and positional_index >= pos_defs.len) {
                        i += 1;
                        // Strip a leading `--` unless the command keeps it
                        // (`deno run x.ts -- -a` forwards `["--", "-a"]`, but
                        // `deno eval code -- a` forwards `["a"]`).
                        if (!cmd.keep_double_dash and i < args.len and eql(args[i], "--")) i += 1;
                        while (i < args.len) : (i += 1) try self.result.trailing.append(self.arena, args[i]);
                        continue;
                    }
                }
                i += 1;
            } else {
                // No more positional defs.
                if (!cmd.trailing_var_arg) {
                    return self.fail(.UnexpectedPositional, "unexpected argument '{s}'", .{arg});
                }
                try self.result.trailing.append(self.arena, arg);
                i += 1;
            }
        }

        if (passthrough_from) |start| {
            for (args[start..]) |arg| try self.result.trailing.append(self.arena, arg);
        }

        // `--help`/`--version` preempt validation: the command never runs.
        // A value-taking `--version` (`upgrade --version 1.2.3`) is a normal
        // arg, not the root version flag.
        if (self.result.contains("help") or
            (self.result.contains("version") and self.result.getOne("version") == null))
        {
            return;
        }

        // Every `required` arg must be present.
        it = cmd.allArgs();
        while (it.next()) |a| {
            if (a.required and !self.result.contains(a.name)) {
                return self.fail(.MissingRequired, "the following required arguments were not provided: {s}", .{a.name});
            }
        }

        // Mutually exclusive args (clap's `conflicts_with`).
        it = cmd.allArgs();
        while (it.next()) |a| {
            if (!self.result.contains(a.name)) continue;
            for (a.conflicts) |other| {
                if (!self.result.contains(other)) continue;
                const other_display = if (findArgByName(cmd, other)) |o|
                    try displayArg(self.arena, o)
                else
                    other;
                return self.fail(.InvalidValue, "the argument '{s}' cannot be used with '{s}'", .{ try displayArg(self.arena, a), other_display });
            }
        }

        // Arg dependencies (clap's `requires`). A missing requirement is
        // waived when the required arg conflicts with a present arg (e.g.
        // `--no-clear-screen` requires `--watch` but is fine with
        // `--watch-hmr`, which conflicts with `--watch`).
        it = cmd.allArgs();
        while (it.next()) |a| {
            if (!self.result.contains(a.name)) continue;
            for (a.requires) |required| {
                if (!self.result.contains(required) and !self.requirementWaived(cmd, required)) {
                    return self.fail(.MissingRequired, "the following required arguments were not provided: --{s}", .{required});
                }
            }
        }
    }

    fn requirementWaived(self: *Parser, cmd: *const CommandDef, required: []const u8) bool {
        const required_conflicts: []const []const u8 = if (findArgByName(cmd, required)) |r| r.conflicts else &.{};
        var it = cmd.allArgs();
        while (it.next()) |a| {
            if (!self.result.contains(a.name)) continue;
            if (contains(a.conflicts, required) or contains(required_conflicts, a.name)) return true;
        }
        return false;
    }

    /// Parse `--long-flag` or `--long-flag=value`. Returns the next index.
    fn parseLongFlag(self: *Parser, cmd: *const CommandDef, root: *const CommandDef, args: []const []const u8, pos: usize) Error!usize {
        const arg = args[pos];
        const after_dashes = arg[2..];
        const eq = std.mem.indexOfScalar(u8, after_dashes, '=');
        const flag_name = after_dashes[0 .. eq orelse after_dashes.len];
        const inline_value: ?[]const u8 = if (eq) |e| after_dashes[e + 1 ..] else null;

        // Look the flag up in the command first, then the root's globals.
        const def = cmd.findArgLong(flag_name) orelse findGlobal(root, flag_name, null) orelse
            return self.unknownFlag(arg, cmd);

        switch (def.action) {
            .set_true => {
                try self.setBool(def);
                // A bool flag with optional values takes an inline value
                // (e.g. `--help=full`).
                if (inline_value) |v| if (def.num_args == .optional or def.num_args == .zero_or_more) {
                    try self.setValue(def, v);
                };
                return pos + 1;
            },
            .count => {
                try self.incrementCount(def);
                return pos + 1;
            },
            .set, .append => switch (def.num_args) {
                .exact => |n| if (n == 0) {
                    try self.setBool(def);
                    return pos + 1;
                } else return self.takeRequiredValue(def, args, pos, inline_value),
                .optional => {
                    if (inline_value) |v| {
                        try self.setBool(def);
                        try self.applyValue(def, v);
                    } else if (def.require_equals) {
                        // Present, but without a value.
                        try self.setBool(def);
                    } else if (pos + 1 < args.len and !std.mem.startsWith(u8, args[pos + 1], "-")) {
                        try self.setValue(def, args[pos + 1]);
                        return pos + 2;
                    } else {
                        try self.setBool(def);
                    }
                    return pos + 1;
                },
                .zero_or_more => {
                    try self.setBool(def);
                    if (inline_value) |v| {
                        try self.applyValue(def, v);
                    } else if (!def.require_equals) {
                        // Consume the following non-flag args.
                        var next = pos + 1;
                        while (next < args.len and !std.mem.startsWith(u8, args[next], "-")) : (next += 1) {
                            try self.setValue(def, args[next]);
                        }
                        return next;
                    }
                    return pos + 1;
                },
                .one_or_more => return self.takeRequiredValue(def, args, pos, inline_value),
            },
        }
    }

    fn takeRequiredValue(self: *Parser, def: *const Arg, args: []const []const u8, pos: usize, inline_value: ?[]const u8) Error!usize {
        if (inline_value) |v| {
            try self.applyValue(def, v);
            return pos + 1;
        }
        if (pos + 1 < args.len) {
            try self.applyValue(def, args[pos + 1]);
            return pos + 2;
        }
        return self.missingValue(args[pos]);
    }

    /// Parse short flags: `-A`, `-f value`, `-fvalue`, or combined `-ABC`.
    fn parseShortFlag(self: *Parser, cmd: *const CommandDef, root: *const CommandDef, args: []const []const u8, pos: usize) Error!usize {
        const arg = args[pos];
        var chars = Chars{ .s = arg[1..] };
        while (chars.peek()) |c| {
            const def = findShort(cmd, root, c.cp, true) orelse {
                const flag = try std.fmt.allocPrint(self.arena, "-{s}", .{c.bytes});
                return self.unknownFlag(flag, cmd);
            };
            chars.advance(c);
            const rest = chars.rest();

            switch (def.action) {
                .set_true => try self.setBool(def),
                .count => try self.incrementCount(def),
                .set, .append => switch (def.num_args) {
                    .exact => |n| if (n == 0) {
                        try self.setBool(def);
                    } else {
                        return self.takeShortValue(def, args, pos, rest, c.bytes);
                    },
                    .optional, .zero_or_more => {
                        try self.setBool(def);
                        // If the next char is itself a known short flag, keep
                        // going (combined shorts); otherwise the rest is the
                        // value.
                        if (chars.peek()) |next| {
                            if (findShort(cmd, root, next.cp, false) == null) {
                                try self.applyValue(def, stripEquals(rest));
                                return pos + 1;
                            }
                        }
                    },
                    .one_or_more => return self.takeShortValue(def, args, pos, rest, c.bytes),
                },
            }
        }
        return pos + 1;
    }

    fn takeShortValue(self: *Parser, def: *const Arg, args: []const []const u8, pos: usize, rest: []const u8, short: []const u8) Error!usize {
        if (rest.len > 0) {
            // `-fvalue` or `-f=value`.
            try self.applyValue(def, stripEquals(rest));
            return pos + 1;
        }
        if (pos + 1 < args.len) {
            try self.applyValue(def, args[pos + 1]);
            return pos + 2;
        }
        return self.missingValue(try std.fmt.allocPrint(self.arena, "-{s}", .{short}));
    }
};

/// Parse `args` (including the binary name in `args[0]`) against `root`.
/// On `error.InvalidArgs`, `diag` describes the problem.
pub fn parse(arena: Allocator, root: *const CommandDef, args: []const []const u8, diag: *CliError) Error!ParseResult {
    var p: Parser = .{ .arena = arena, .diag = diag };
    const rest = if (args.len > 0) args[1..] else args;

    if (resolveSubcommand(root, rest)) |sub| {
        p.result.subcommand = sub;
        try p.parseArgs(sub, root, rest, sub.name);
    } else if (root.default_subcommand) |name| {
        // No subcommand matched: parse with the default subcommand's args,
        // but leave `subcommand` null so callers know it was implicit.
        const def = root.findSubcommand(name) orelse root;
        try p.parseArgs(def, root, rest, null);
    } else {
        try p.parseArgs(root, root, rest, null);
    }
    return p.result;
}

/// Find the subcommand in `args`, walking past any global flags before it.
pub fn resolveSubcommand(root: *const CommandDef, args: []const []const u8) ?*const CommandDef {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (eql(arg, "--")) return null;
        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const name = body[0 .. std.mem.indexOfScalar(u8, body, '=') orelse body.len];
            // Only the primary long name counts here, not aliases.
            const def = findGlobalPrimaryLong(root, name) orelse return null;
            i += 1;
            // Skip the value if this flag takes one.
            if (!def.num_args.isNone() and def.action != .set_true and
                std.mem.indexOfScalar(u8, arg, '=') == null)
            {
                i += 1;
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            // Only the first short flag of a cluster is checked.
            const c = (Chars{ .s = arg[1..] }).peek().?;
            const def = findGlobalPrimaryShort(root, c.cp) orelse return null;
            i += 1;
            if (!def.num_args.isNone() and def.action != .set_true and arg.len == 2) i += 1;
        } else {
            return root.findSubcommand(arg);
        }
    }
    return null;
}

fn isMulti(a: *const Arg) bool {
    return a.num_args == .zero_or_more or a.num_args == .one_or_more;
}

fn findGlobal(root: *const CommandDef, long: []const u8, short: ?u21) ?*const Arg {
    var it = root.allArgs();
    while (it.next()) |a| {
        if (!a.global) continue;
        if (short) |s| {
            if (s < 128 and a.matchesShort(@intCast(s))) return a;
        } else if (a.matchesLong(long)) return a;
    }
    return null;
}

fn findGlobalPrimaryLong(root: *const CommandDef, long: []const u8) ?*const Arg {
    var it = root.allArgs();
    while (it.next()) |a| if (a.global and a.long != null and eql(a.long.?, long)) return a;
    return null;
}

fn findGlobalPrimaryShort(root: *const CommandDef, short: u21) ?*const Arg {
    var it = root.allArgs();
    while (it.next()) |a| if (a.global and a.short != null and a.short.? == short) return a;
    return null;
}

/// Look up a short flag in the command, then the root's globals. Rust only
/// honors short aliases of globals when resolving the flag itself, not when
/// checking whether the next char of a cluster is a flag.
fn findShort(cmd: *const CommandDef, root: *const CommandDef, cp: u21, global_aliases: bool) ?*const Arg {
    if (cp < 128) if (cmd.findArgShort(@intCast(cp))) |a| return a;
    return if (global_aliases) findGlobal(root, "", cp) else findGlobalPrimaryShort(root, cp);
}

fn findArgByName(cmd: *const CommandDef, name: []const u8) ?*const Arg {
    var it = cmd.allArgs();
    while (it.next()) |a| if (eql(a.name, name)) return a;
    return null;
}

/// Render an arg the way clap did in conflict messages: `--long <value>` for
/// value-taking flags, `--long` for booleans, `<NAME>` for positionals.
fn displayArg(arena: Allocator, a: *const Arg) Allocator.Error![]const u8 {
    const value_name = a.value_name orelse a.name;
    if (a.positional) return std.fmt.allocPrint(arena, "<{s}>", .{value_name});
    const flag = if (a.long) |l|
        try std.fmt.allocPrint(arena, "--{s}", .{l})
    else if (a.short) |s|
        try std.fmt.allocPrint(arena, "-{c}", .{s})
    else
        a.name;
    if (a.num_args.isNone()) return flag;
    return std.fmt.allocPrint(arena, "{s} <{s}>", .{ flag, value_name });
}

fn findClosestFlag(arena: Allocator, input: []const u8, cmd: *const CommandDef) Allocator.Error!?[]const u8 {
    const stripped = std.mem.trimStart(u8, input, "-");
    var best: ?struct { dist: usize, long: []const u8 } = null;
    var it = cmd.allArgs();
    while (it.next()) |a| {
        const long = a.long orelse continue;
        const dist = try levenshtein(arena, stripped, long);
        const threshold = @max(long.len / 3, 2);
        if (dist <= threshold and (best == null or dist < best.?.dist)) best = .{ .dist = dist, .long = long };
    }
    const b = best orelse return null;
    return try std.fmt.allocPrint(arena, "--{s}", .{b.long});
}

/// Levenshtein distance over Unicode scalar values, like the Rust version.
fn levenshtein(arena: Allocator, a: []const u8, b: []const u8) Allocator.Error!usize {
    const a_cps = try codepoints(arena, a);
    const b_cps = try codepoints(arena, b);
    // Rust measures the empty-string cases in bytes.
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    // Rust sizes the rows by byte length; only the first `chars` entries
    // are filled, and the result is read at the byte length.
    const prev = try arena.alloc(usize, b.len + 1);
    const curr = try arena.alloc(usize, b.len + 1);
    for (prev, 0..) |*p, j| p.* = j;
    @memset(curr, 0);
    var prev_row = prev;
    var curr_row = curr;
    for (a_cps, 0..) |ac, i| {
        curr_row[0] = i + 1;
        for (b_cps, 0..) |bc, j| {
            const cost: usize = if (ac == bc) 0 else 1;
            curr_row[j + 1] = @min(prev_row[j + 1] + 1, curr_row[j] + 1, prev_row[j] + cost);
        }
        std.mem.swap([]usize, &prev_row, &curr_row);
    }
    return prev_row[b.len];
}

fn codepoints(arena: Allocator, s: []const u8) Allocator.Error![]u21 {
    var list: std.ArrayList(u21) = .empty;
    var chars = Chars{ .s = s };
    while (chars.peek()) |c| {
        try list.append(arena, c.cp);
        chars.advance(c);
    }
    return list.items;
}

/// Iterates over UTF-8 characters, treating invalid bytes as single chars.
const Chars = struct {
    s: []const u8,
    i: usize = 0,

    const Char = struct { cp: u21, bytes: []const u8 };

    fn peek(self: Chars) ?Char {
        if (self.i >= self.s.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.s[self.i]) catch 1;
        if (self.i + len <= self.s.len) {
            const bytes = self.s[self.i .. self.i + len];
            if (std.unicode.utf8Decode(bytes)) |cp| return .{ .cp = cp, .bytes = bytes } else |_| {}
        }
        return .{ .cp = 0xFFFD, .bytes = self.s[self.i .. self.i + 1] };
    }

    fn advance(self: *Chars, c: Char) void {
        self.i += c.bytes.len;
    }

    fn rest(self: Chars) []const u8 {
        return self.s[self.i..];
    }
};

/// Parse an unsigned integer the way Rust's `str::parse` does: an optional
/// `+` followed by one or more ASCII digits, with no overflow.
fn parseUnsigned(comptime T: type, s: []const u8) ?T {
    const digits = if (std.mem.startsWith(u8, s, "+")) s[1..] else s;
    if (digits.len == 0) return null;
    var n: T = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        n = std.math.mul(T, n, 10) catch return null;
        n = std.math.add(T, n, c - '0') catch return null;
    }
    return n;
}

fn stripEquals(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "=")) s[1..] else s;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |item| if (eql(item, s)) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ------------------------------------------------------------------ tests

const defs = @import("defs.zig");

/// Render a parse outcome in the same form as
/// `zig/tools/cli_reference`'s `render_parse`.
fn renderOutcome(w: *std.Io.Writer, argv: []const []const u8, arena: Allocator) !void {
    try w.writeAll("> ");
    try std.json.Stringify.value(argv, .{}, w);
    try w.writeByte('\n');
    var diag: CliError = undefined;
    if (parse(arena, &defs.root, argv, &diag)) |r| {
        if (r.subcommand) |sub| try w.print("subcommand {s}\n", .{sub.name});
        for (r.args.items) |a| {
            try w.print("arg {s} present={} count={d} [", .{ a.name, a.is_present, a.count });
            try writeJsonList(w, a.values.items);
            try w.writeAll("]\n");
        }
        if (r.trailing.items.len > 0) {
            try w.writeAll("trailing [");
            try writeJsonList(w, r.trailing.items);
            try w.writeAll("]\n");
        }
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidArgs => {
            var buf: std.Io.Writer.Allocating = .init(arena);
            try diag.format(&buf.writer);
            try w.print("error {s}: ", .{@tagName(diag.kind)});
            try std.json.Stringify.value(buf.written(), .{}, w);
            try w.writeByte('\n');
        },
    }
}

fn writeJsonList(w: *std.Io.Writer, items: []const []const u8) !void {
    for (items, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(v, .{}, w);
    }
}

test "parse results match the Rust implementation" {
    const corpus = @embedFile("testdata/parse_corpus.jsonl");
    const golden = @embedFile("testdata/parse_corpus.golden");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const argv = try std.json.parseFromSliceLeaky([]const []const u8, arena, line, .{});
        try renderOutcome(&out.writer, argv, arena);
        cases += 1;
    }
    try std.testing.expect(cases > 500);
    try std.testing.expectEqualStrings(golden, out.written());
}

test "parseUnsigned follows Rust's rules" {
    try std.testing.expectEqual(@as(?u8, 5), parseUnsigned(u8, "+5"));
    try std.testing.expectEqual(@as(?u8, 255), parseUnsigned(u8, "255"));
    try std.testing.expectEqual(@as(?u8, null), parseUnsigned(u8, "256"));
    try std.testing.expectEqual(@as(?u8, null), parseUnsigned(u8, "1_0"));
    try std.testing.expectEqual(@as(?u8, null), parseUnsigned(u8, "-1"));
    try std.testing.expectEqual(@as(?u8, null), parseUnsigned(u8, ""));
    try std.testing.expectEqual(@as(?u8, null), parseUnsigned(u8, "+"));
}
