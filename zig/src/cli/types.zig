// Copyright 2018-2026 the Deno authors. MIT license.
//! Static command/argument definitions, ported from
//! `libs/cli_parser/src/types.rs`. Like the Rust version, every definition is
//! comptime-known and lives in read-only memory.

const command_table = @import("command_table.zig");

pub const Tag = command_table.Tag;

/// How many values an argument accepts.
pub const NumArgs = union(enum) {
    exact: u8,
    optional,
    zero_or_more,
    one_or_more,
};

pub const ArgAction = enum {
    set,
    set_true,
    append,
    count,
};

/// Definition of a single CLI argument/flag.
pub const Arg = struct {
    /// Internal identifier for this arg.
    name: []const u8,
    short: ?u8 = null,
    long: ?[]const u8 = null,
    short_aliases: []const u8 = &.{},
    long_aliases: []const []const u8 = &.{},
    help: []const u8 = "",
    action: ArgAction = .set,
    num_args: NumArgs = .{ .exact = 1 },
    /// If true, the value must be attached with `=` (e.g. `--flag=val`).
    require_equals: bool = false,
    global: bool = false,
    hidden: bool = false,
    positional: bool = false,
    value_name: ?[]const u8 = null,
    /// Allowed values, if restricted (clap's `value_parser` choices).
    choices: []const []const u8 = &.{},

    /// Whether this flag consumes a value from the following argv entry when
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
        for (self.short_aliases) |a| if (a == short) return true;
        return false;
    }
};

/// Definition of a top-level subcommand.
pub const Command = struct {
    tag: Tag,
    name: []const u8,
    about: []const u8,
    aliases: []const []const u8 = &.{},
    /// Once the first positional is consumed, all remaining args are
    /// positional (they're forwarded to the program being run).
    trailing: bool = false,
    /// All args after the subcommand name are forwarded without parsing.
    passthrough: bool = false,

    pub fn matches(self: Command, name: []const u8) bool {
        if (eql(self.name, name)) return true;
        for (self.aliases) |a| if (eql(a, name)) return true;
        return false;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}
