// Copyright 2018-2026 the Deno authors. MIT license.
//! `deno eval`, ported from `eval_command` in `cli/tools/run/mod.rs`.
//!
//! The code runs as the ES module `./$deno$eval.<ext>` (`mts` by default),
//! in a runtime bootstrapped with `libs/core` only: `Deno.*`, web APIs,
//! TypeScript and CommonJS come in later phases of the port. `console` is a
//! temporary native one.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const url = @import("../core/url.zig");
const JsRuntime = @import("../core/runtime.zig").JsRuntime;
const ParseResult = @import("../cli/parse.zig").ParseResult;

pub fn run(gpa: std.mem.Allocator, io: std.Io, result: *const ParseResult, err: *std.Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code = result.getOne("code_arg").?;
    const ext = result.getOne("ext") orelse "mts";
    const cwd = try std.process.currentPathAlloc(io, arena);
    const specifier = try url.fromFilePath(arena, try std.fmt.allocPrint(arena, "{s}/$deno$eval.{s}", .{ cwd, ext }));

    // `--print` logs the value of the expression. `[eval]` matches Node's
    // URL for `-e` scripts; it's appended so line numbers are preserved.
    const source = if (result.getBool("print"))
        try std.fmt.allocPrint(arena, "console.log({s})\n//# sourceURL=[eval]\n", .{code})
    else
        try std.fmt.allocPrint(arena, "{s}\n//# sourceURL=[eval]\n", .{code});

    return runMainModule(gpa, io, specifier, source, err);
}

/// Run `specifier` as the main module, reporting an uncaught exception or a
/// load error on `err`. Returns the exit code.
pub fn runMainModule(gpa: std.mem.Allocator, io: std.Io, specifier: []const u8, source: ?[]const u8, err: *std.Io.Writer) !u8 {
    const platform: v8.Platform = .init("");
    defer platform.deinit();
    const rt = try JsRuntime.create(gpa, io, .{});
    defer rt.destroy(gpa);

    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, specifier, source, &exception) catch |e| switch (e) {
        error.JsException => {
            try err.print("error: Uncaught {s}\n", .{exception orelse "exception"});
            return 1;
        },
        error.ModuleLoadFailed => {
            try err.print("error: {s}\n", .{exception.?});
            return 1;
        },
        else => return e,
    };
    return 0;
}
