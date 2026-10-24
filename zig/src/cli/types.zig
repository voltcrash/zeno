// Copyright 2018-2026 the Deno authors. MIT license.
//! Static command/argument definitions, ported from
//! `libs/cli_parser/src/types.rs`. Like the Rust version, every definition is
//! comptime-known and lives in read-only memory. The definitions themselves
//! are generated into `defs.zig`.

const std = @import("std");

pub const Tag = @import("defs.zig").Tag;

/// How many values an argument accepts.
pub const NumArgs = union(enum) {
    exact: u8,
    optional,
    zero_or_more,
    one_or_more,
};

/// What the parser does when it encounters an argument.
pub const ArgAction = enum {
    /// Boolean flag, set to true when present.
    set_true,
    /// Takes a single value; the last one wins.
    set,
    /// Collects every occurrence.
    append,
    /// Counts occurrences (e.g. `-vvv` is 3).
    count,
};

/// Declarative value validation, mirroring clap's `value_parser`.
pub const ValueParser = union(enum) {
    /// One of a fixed set of allowed strings.
    choices: []const []const u8,
    bool,
    u8,
    u16,
    u32,
    u64,
    usize,
    non_zero_u8,
    non_zero_u32,
    non_zero_usize,
    /// A u32 within an inclusive range.
    u32_range: struct { lo: u32, hi: u32 },
};

/// Definition of a single CLI argument/flag.
pub const Arg = struct {
    /// Internal identifier for this arg (used to retrieve parsed values).
    name: []const u8,
    short: ?u8 = null,
    long: ?[]const u8 = null,
    short_aliases: []const u8 = &.{},
    long_aliases: []const []const u8 = &.{},
    help: []const u8 = "",
    action: ArgAction = .set,
    num_args: NumArgs = .{ .exact = 1 },
    /// If set, values like `--flag=a,b,c` are split on this character.
    value_delimiter: ?u8 = null,
    /// If true, the value must be attached with `=` (e.g. `--flag=val`).
    require_equals: bool = false,
    required: bool = false,
    default_value: ?[]const u8 = null,
    global: bool = false,
    hidden: bool = false,
    /// A positional argument (no `--`/`-` prefix).
    positional: bool = false,
    /// Once this positional starts consuming values, all remaining args
    /// (including flags) are collected as its values.
    trailing: bool = false,
    value_name: ?[]const u8 = null,
    /// Args that can't be combined with this one.
    conflicts: []const []const u8 = &.{},
    /// Args that must be present when this one is.
    requires: []const []const u8 = &.{},
    value_parser: ?ValueParser = null,

    /// Whether this flag consumes the following argv entry as its value when
    /// one isn't attached with `=`.
    pub fn takesSeparateValue(self: Arg) bool {
        if (self.action == .set_true or self.action == .count) return false;
        if (self.require_equals) return false;
        return switch (self.num_args) {
            .exact => |n| n > 0,
            else => true,
        };
    }

    pub fn matchesLong(self: Arg, long: []const u8) bool {
        if (self.long) |l| if (eql(l, long)) return true;
        for (self.long_aliases) |a| if (eql(a, long)) return true;
        return false;
    }

    pub fn matchesShort(self: Arg, short: u8) bool {
        if (self.short) |s| if (s == short) return true;
        return std.mem.indexOfScalar(u8, self.short_aliases, short) != null;
    }
};

/// Definition of a command: the `deno` root or one of its subcommands.
pub const CommandDef = struct {
    /// Set for subcommands; null for the root.
    tag: ?Tag = null,
    name: []const u8,
    about: []const u8 = "",
    aliases: []const []const u8 = &.{},
    args: []const Arg = &.{},
    /// Groups of args shared between commands (e.g. permission args). They
    /// are flattened into `args` when parsing.
    arg_groups: []const []const Arg = &.{},
    subcommands: []const CommandDef = &.{},
    /// When no subcommand name matches argv, use this subcommand's args.
    default_subcommand: ?[]const u8 = null,
    /// Once the first positional is consumed, all remaining args are
    /// positional (they're forwarded to the program being run).
    trailing_var_arg: bool = false,
    /// All args after the subcommand name are forwarded without parsing.
    passthrough: bool = false,
    /// Whether a `--` before the forwarded args is kept in them (`deno run
    /// x.ts -- -a` forwards `["--", "-a"]`) or stripped.
    keep_double_dash: bool = false,

    /// Whether `name` is this command's name or one of its aliases.
    pub fn matches(self: *const CommandDef, name: []const u8) bool {
        if (eql(self.name, name)) return true;
        for (self.aliases) |a| if (eql(a, name)) return true;
        return false;
    }

    /// Find a subcommand by name or alias.
    pub fn findSubcommand(self: *const CommandDef, name: []const u8) ?*const CommandDef {
        for (self.subcommands) |*sub| if (sub.matches(name)) return sub;
        return null;
    }

    /// Iterate over the command's own args, then those of its arg groups.
    pub fn allArgs(self: *const CommandDef) ArgIterator {
        return .{ .cmd = self };
    }

    pub fn findArgLong(self: *const CommandDef, long: []const u8) ?*const Arg {
        var it = self.allArgs();
        while (it.next()) |a| if (a.matchesLong(long)) return a;
        return null;
    }

    pub fn findArgShort(self: *const CommandDef, short: u8) ?*const Arg {
        var it = self.allArgs();
        while (it.next()) |a| if (a.matchesShort(short)) return a;
        return null;
    }

    pub fn hasArgGroup(self: *const CommandDef, group: []const Arg) bool {
        for (self.arg_groups) |g| if (g.ptr == group.ptr) return true;
        return false;
    }
};

pub const ArgIterator = struct {
    cmd: *const CommandDef,
    /// 0 is the command's own args; `n` is `arg_groups[n - 1]`.
    group: usize = 0,
    index: usize = 0,

    pub fn next(self: *ArgIterator) ?*const Arg {
        while (true) {
            const list = if (self.group == 0)
                self.cmd.args
            else if (self.group <= self.cmd.arg_groups.len)
                self.cmd.arg_groups[self.group - 1]
            else
                return null;
            if (self.index < list.len) {
                defer self.index += 1;
                return &list[self.index];
            }
            self.group += 1;
            self.index = 0;
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
