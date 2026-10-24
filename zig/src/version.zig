// Copyright 2018-2026 the Deno authors. MIT license.
//! Version information, ported from `cli/lib/version.rs` and
//! `render_version` in `cli/args/flags.rs`.

const std = @import("std");
const builtin = @import("builtin");

pub const deno = "2.9.8";
pub const typescript = "6.0.3";
/// The V8 build the port links against (rusty_v8 150.4.0's prebuilt
/// `librusty_v8.a`).
pub const v8 = "15.0.245.2-rusty";
pub const release_channel = "stable";

/// `debug` or `release`, mirroring the cargo profile name.
pub const profile = if (builtin.mode == .debug) "debug" else "release";

/// The target, spelled as a Rust target triple so `deno --version` reads
/// the same as the Rust build's.
pub const target = rustTriple(builtin.target);

fn rustTriple(t: std.Target) []const u8 {
    const arch = switch (t.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @tagName(t.cpu.arch),
    };
    return switch (t.os.tag) {
        .linux => arch ++ "-unknown-linux-" ++ switch (t.abi) {
            .musl => "musl",
            else => "gnu",
        },
        .macos => arch ++ "-apple-darwin",
        .windows => arch ++ "-pc-windows-msvc",
        else => arch ++ "-unknown-" ++ @tagName(t.os.tag),
    };
}

/// Render the text printed by `deno --version` (`long`) and `deno -V`.
pub fn render(w: *std.Io.Writer, long: bool) std.Io.Writer.Error!void {
    if (long) {
        try w.print("deno {s} ({s}, {s}, {s})\nv8 {s}\ntypescript {s}\n", .{
            deno, release_channel, profile, target, v8, typescript,
        });
    } else {
        try w.print("deno {s}\n", .{deno});
    }
}

test "short version" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, false);
    try std.testing.expectEqualStrings("deno " ++ deno ++ "\n", w.buffered());
}
