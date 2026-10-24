// Copyright 2018-2026 the Deno authors. MIT license.
//! `deno eval`, ported from `eval_command` in `cli/tools/run/mod.rs`.
//!
//! For now the code runs as a classic script in a bare V8 context with a
//! temporary native `console`; the Deno runtime (`Deno.*`, web APIs, ES
//! modules, TypeScript) comes in later phases of the port.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const JsRuntime = @import("../core/runtime.zig").JsRuntime;
const ParseResult = @import("../cli/parse.zig").ParseResult;

/// The script name used in stack traces, as in the Rust implementation.
const specifier = "$deno$eval.mts";

pub fn run(gpa: std.mem.Allocator, io: std.Io, result: *const ParseResult, err: *std.Io.Writer) !u8 {
    const code = result.getOne("code_arg").?;
    const print = result.getBool("print");

    const platform: v8.Platform = .init("");
    defer platform.deinit();
    const rt = try JsRuntime.create(gpa, io, .{});
    defer rt.destroy(gpa);

    // `--print` logs the value of the last expression.
    const source = if (print)
        try std.fmt.allocPrint(gpa, "console.log(eval({f}))", .{std.json.fmt(code, .{})})
    else
        code;
    defer if (print) gpa.free(source);

    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    _ = rt.executeScript(gpa, specifier, source, &exception) catch |e| switch (e) {
        error.JsException => {
            try err.print("error: Uncaught {s}\n", .{exception orelse "exception"});
            return 1;
        },
        else => return e,
    };
    return 0;
}
