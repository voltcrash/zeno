// Copyright 2018-2026 the Deno authors. MIT license.
//! Help text rendering, ported from `libs/cli_parser/src/help.rs`.

const std = @import("std");
const Writer = std.Io.Writer;

const types = @import("types.zig");
const Arg = types.Arg;
const CommandDef = types.CommandDef;
const defs = @import("defs.zig");
const env_vars = @import("env_vars.zig");

/// Render help text for a command (the root or a subcommand).
pub fn render(w: *Writer, cmd: *const CommandDef) Writer.Error!void {
    if (cmd.about.len > 0) try w.print("{s}\n\n", .{cmd.about});

    if (cmd.tag == null) {
        try w.print("Usage: {s} [OPTIONS]", .{cmd.name});
    } else {
        try w.print("Usage: deno {s} [OPTIONS]", .{cmd.name});
    }
    var it = cmd.allArgs();
    while (it.next()) |pos| {
        if (!pos.positional) continue;
        var name_buf: [64]u8 = undefined;
        const name = std.ascii.upperString(&name_buf, pos.value_name orelse pos.name);
        switch (pos.num_args) {
            .optional => try w.print(" [{s}]", .{name}),
            .zero_or_more => try w.print(" [{s}]...", .{name}),
            .one_or_more => try w.print(" <{s}>...", .{name}),
            .exact => |n| if (n != 0) try w.print(" <{s}>", .{name}),
        }
    }
    if (cmd.subcommands.len > 0) try w.writeAll(" [COMMAND]");
    try w.writeByte('\n');

    if (cmd.subcommands.len > 0) try renderSubcommands(w, cmd.subcommands);
    try renderOptions(w, cmd);

    // The permission args are hidden from the options table and documented
    // in this section instead.
    if (cmd.hasArgGroup(defs.permission_args)) {
        try w.writeByte('\n');
        try w.writeAll(defs.permission_help);
    }

    // Environment variables are only documented in the root help.
    if (cmd.tag == null) try renderEnvVars(w);
}

fn isJsonReference(cmd: *const CommandDef) bool {
    return std.mem.startsWith(u8, cmd.name, "json_reference");
}

fn renderSubcommands(w: *Writer, subcommands: []const CommandDef) Writer.Error!void {
    try w.writeAll("\nCommands:\n");
    var max_name_len: usize = 0;
    for (subcommands) |*sub| {
        if (isJsonReference(sub)) continue;
        max_name_len = @max(max_name_len, sub.name.len);
    }
    for (subcommands) |*sub| {
        if (isJsonReference(sub)) continue;
        // Only use the first line of about text in the commands table.
        const short_about = std.mem.sliceTo(sub.about, '\n');
        try w.writeAll("  ");
        try padRight(w, sub.name, max_name_len);
        try w.print("  {s}\n", .{short_about});
    }
}

fn renderOptions(w: *Writer, cmd: *const CommandDef) Writer.Error!void {
    var any = false;
    var it = cmd.allArgs();
    while (it.next()) |arg| {
        if (arg.positional or arg.hidden) continue;
        if (!any) try w.writeAll("\nOptions:\n");
        any = true;

        var buf: [256]u8 = undefined;
        var flag: Writer = .fixed(&buf);
        formatFlag(&flag, arg) catch unreachable;

        var lines = std.mem.splitScalar(u8, arg.help, '\n');
        try w.writeAll("  ");
        try padRight(w, flag.buffered(), 22);
        try w.print("  {s}\n", .{lines.first()});
        while (lines.next()) |rest_line| {
            // Indent to the description column; any further indentation is
            // baked into the help string itself.
            try w.splatByteAll(' ', 26);
            try w.print("{s}\n", .{rest_line});
        }
    }
}

fn formatFlag(w: *Writer, arg: *const Arg) Writer.Error!void {
    if (arg.short) |short| {
        try w.print("-{c}", .{short});
        if (arg.long != null) try w.writeAll(", ");
    } else {
        try w.writeAll("    ");
    }
    const long = arg.long orelse return;
    try w.print("--{s}", .{long});
    const vn = arg.value_name orelse "VALUE";
    switch (arg.num_args) {
        .exact => |n| if (n != 0) try w.print(" <{s}>", .{vn}),
        .optional => if (arg.require_equals)
            try w.print("[=<{s}>]", .{vn})
        else
            try w.print(" [<{s}>]", .{vn}),
        .zero_or_more => if (arg.require_equals)
            try w.print("[={s}...]", .{vn})
        else
            try w.print(" [{s}...]", .{vn}),
        .one_or_more => try w.print(" <{s}>", .{vn}),
    }
}

/// Render the "Environment variables" section of `deno --help`.
fn renderEnvVars(w: *Writer) Writer.Error!void {
    try w.writeAll("\nEnvironment variables:\nDocs: https://docs.deno.com/go/env-vars\n\n");
    var width: usize = 0;
    for (env_vars.all) |v| width = @max(width, v.name.len);
    width += 1;

    for (env_vars.all, 0..) |v, i| {
        if (i > 0) try w.writeByte('\n');
        try w.writeAll("  ");
        try padRight(w, v.name, width);
        var lines = std.mem.splitScalar(u8, v.description, '\n');
        try w.writeAll(lines.first());
        while (lines.next()) |line| {
            try w.writeAll("\n  ");
            try w.splatByteAll(' ', width);
            try w.writeAll(line);
        }
        if (v.example) |example| {
            try w.writeAll("\n  ");
            try w.splatByteAll(' ', width);
            try w.print(" {s}", .{example});
        }
    }
    try w.writeByte('\n');
}

fn padRight(w: *Writer, s: []const u8, width: usize) Writer.Error!void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}

fn expectHelp(cmd: *const CommandDef, expected: []const u8) !void {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, cmd);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "root help matches the Rust implementation" {
    try expectHelp(&defs.root, @embedFile("golden/root.txt"));
}

test "subcommand help matches the Rust implementation" {
    inline for (defs.subcommands) |sub| {
        if (comptime std.mem.startsWith(u8, sub.name, "json_reference")) continue;
        expectHelp(&sub, @embedFile("golden/" ++ sub.name ++ ".txt")) catch |err| {
            std.debug.print("help for `{s}` differs\n", .{sub.name});
            return err;
        };
    }
}
