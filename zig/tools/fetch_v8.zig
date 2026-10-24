// Copyright 2018-2026 the Deno authors. MIT license.
//! Build-time tool: download a gzipped prebuilt `librusty_v8` archive, check
//! its SHA-256, and write the decompressed archive.
//!
//!   fetch_v8 <url> <sha256 of the .gz> <output path>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) fatal("usage: fetch_v8 <url> <sha256> <output>", .{});
    const url, const expected_hex, const out_path = .{ args[1], args[2], args[3] };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch |err| fatal("downloading {s}: {t}", .{ url, err });
    if (res.status != .ok) fatal("downloading {s}: HTTP {d}", .{ url, @backingInt(res.status) });
    const gz = body.written();

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(gz, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hex, expected_hex)) {
        fatal("checksum mismatch for {s}\n  expected {s}\n  actual   {s}", .{ url, expected_hex, &actual_hex });
    }

    var in: std.Io.Reader = .fixed(gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var out = file.writer(io, &buf);
    _ = try decompress.reader.streamRemaining(&out.interface);
    try out.interface.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fetch_v8: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
