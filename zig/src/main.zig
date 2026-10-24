// Copyright 2018-2026 the Deno authors. MIT license.
//! Entry point of the Zig port of the Deno CLI (see `zig/PORTING.md`).

const std = @import("std");
const flags = @import("cli/flags.zig");
const defs = @import("cli/defs.zig");
const help = @import("cli/help.zig");
const version = @import("version.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 0) argv[1..] else argv;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;

    var diag: flags.Diagnostic = .{};
    const parsed = flags.parse(args, &diag) catch {
        try diag.print(err);
        try err.flush();
        return 1;
    };

    const code: u8 = switch (parsed.action) {
        .version_short => printStdout(out, version.render, .{false}),
        .version_long => printStdout(out, version.render, .{true}),
        .help => |cmd| printStdout(out, help.render, .{cmd orelse &defs.root}),
        .subcommand => |cmd| try notPorted(err, cmd.name),
        .default_run => try notPorted(err, "run"),
        .default_repl => try notPorted(err, "repl"),
    };
    try err.flush();
    return code;
}

/// Write informational output (help, version) to stdout. Like the Rust
/// CLI's `drop_write_stdout`, write failures such as a closed pipe
/// (`deno --help | head -1`) are ignored.
fn printStdout(out: *std.Io.Writer, comptime render: anytype, args: anytype) u8 {
    @call(.auto, render, .{out} ++ args) catch return 0;
    out.flush() catch {};
    return 0;
}

fn notPorted(err: *std.Io.Writer, name: []const u8) !u8 {
    try err.print(
        "error: `deno {s}` has not been ported to Zig yet (see zig/PORTING.md)\n",
        .{name},
    );
    return 1;
}

test {
    std.testing.refAllDecls(@This());
    _ = flags;
    _ = help;
    _ = version;
}
