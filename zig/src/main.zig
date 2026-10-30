// Copyright 2018-2026 the Deno authors. MIT license.
//! Entry point of the Zig port of the Deno CLI (see `zig/PORTING.md`).

const std = @import("std");
const build_options = @import("build_options");
const flags = @import("cli/flags.zig");
const help = @import("cli/help.zig");
const version = @import("version.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;

    var diag: flags.CliError = undefined;
    const parsed = flags.parse(init.arena.allocator(), argv, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidArgs => {
            try err.print("{f}\n", .{diag});
            try err.flush();
            return 1;
        },
    };

    const code: u8 = switch (parsed.action) {
        .version_short => printStdout(out, version.render, .{false}),
        .version_long => printStdout(out, version.render, .{true}),
        .help => |cmd| printStdout(out, help.render, .{cmd}),
        .subcommand => |cmd| switch (cmd.tag.?) {
            .eval => if (build_options.have_v8)
                try @import("tools/eval.zig").run(init.gpa, io, &parsed.result, err)
            else
                try noV8(err),
            .run => if (!build_options.have_v8)
                try noV8(err)
            else if (parsed.result.getOne("script_arg")) |script|
                try @import("tools/run.zig").run(init.gpa, io, script, err)
            else
                try notPorted(err, "run (without a script)"),
            else => try notPorted(err, cmd.name),
        },
        .default_run => |script| if (build_options.have_v8)
            try @import("tools/run.zig").run(init.gpa, io, script, err)
        else
            try noV8(err),
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

fn noV8(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: this build of the Zig port has no V8 (no prebuilt rusty_v8 archive for this target yet)\n");
    return 1;
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
    _ = @import("core/resources.zig");
    _ = @import("cli/parse.zig");
    if (build_options.have_v8) {
        _ = @import("core/runtime.zig");
        _ = @import("core/ops.zig");
        _ = @import("core/url.zig");
        _ = @import("core/modules.zig");
        _ = @import("v8/v8.zig");
    }
    _ = help;
    _ = version;
}
