// Copyright 2018-2026 the Deno authors. MIT license.
//! Help text rendering, ported from `libs/cli_parser/src/help.rs`.

const std = @import("std");
const Writer = std.Io.Writer;

const types = @import("types.zig");
const Arg = types.Arg;
const Command = types.Command;
const command_table = @import("command_table.zig");
const env_vars = @import("env_vars.zig");
const global_args = @import("global_args.zig");

pub const root_about = "A modern JavaScript and TypeScript runtime";

/// Render `deno --help`.
pub fn renderRoot(w: *Writer) Writer.Error!void {
    try w.print("{s}\n\n", .{root_about});
    try w.writeAll("Usage: deno [OPTIONS] [COMMAND]\n");

    try w.writeAll("\nCommands:\n");
    var max_name_len: usize = 0;
    for (command_table.all) |sub| {
        if (isJsonReference(sub)) continue;
        max_name_len = @max(max_name_len, sub.name.len);
    }
    for (command_table.all) |sub| {
        if (isJsonReference(sub)) continue;
        // Only use the first line of about text in the commands table.
        const short_about = std.mem.sliceTo(sub.about, '\n');
        try w.writeAll("  ");
        try padRight(w, sub.name, max_name_len);
        try w.print("  {s}\n", .{short_about});
    }

    try renderOptions(w, &global_args.all);
    try renderEnvVars(w);
}

/// Render `deno <command> --help`.
///
/// Only the header and usage line are rendered for now: the per-command
/// argument tables have not been ported yet.
pub fn renderCommand(w: *Writer, cmd: Command) Writer.Error!void {
    if (cmd.about.len > 0) try w.print("{s}\n\n", .{cmd.about});
    try w.print("Usage: deno {s} [OPTIONS]\n", .{cmd.name});
    try renderOptions(w, &global_args.all);
}

fn isJsonReference(cmd: Command) bool {
    return std.mem.startsWith(u8, cmd.name, "json_reference");
}

fn renderOptions(w: *Writer, args: []const Arg) Writer.Error!void {
    var any = false;
    for (args) |arg| {
        if (arg.positional or arg.hidden) continue;
        if (!any) try w.writeAll("\nOptions:\n");
        any = true;

        var buf: [128]u8 = undefined;
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

fn formatFlag(w: *Writer, arg: Arg) Writer.Error!void {
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

test "root help matches the Rust implementation" {
    const expected = @embedFile("golden/root_help.txt");
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderRoot(&out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}
