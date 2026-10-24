// Copyright 2018-2026 the Deno authors. MIT license.
//! `deno run <script>`, ported from `run_script` in `cli/tools/run/mod.rs`.
//!
//! For now this runs JavaScript ES modules from disk (or any URL the module
//! loader handles) in a runtime bootstrapped with `libs/core` only.
//! Permissions, `Deno.args`, TypeScript, npm/jsr, remote modules and
//! `--watch` come in later phases.

const std = @import("std");
const url = @import("../core/url.zig");
const eval = @import("eval.zig");

pub fn run(gpa: std.mem.Allocator, io: std.Io, script: []const u8, err: *std.Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `resolve_url_or_path`: a URL as is, else a path relative to the cwd.
    const specifier = if (url.hasScheme(script))
        script
    else if (std.fs.path.isAbsolute(script))
        try url.fromFilePath(arena, script)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, arena);
        const joined = try std.fs.path.resolve(arena, &.{ cwd, script });
        break :blk try url.fromFilePath(arena, joined);
    };
    return eval.runMainModule(gpa, io, specifier, null, err);
}
