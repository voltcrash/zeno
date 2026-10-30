// Copyright 2018-2026 the Deno authors. MIT license.
//! Adaptive read sizing from `libs/core/io/buffer_strategy.rs`.
const std = @import("std");

const standard_size = 64 * 1024;
const tiny_size = 1024;
const max_grow_len = 16 * 1024 * 1024;

fn cappedNextPowerOfTwo(n: usize) usize {
    return @min(std.math.ceilPowerOfTwo(usize, n) catch max_grow_len, max_grow_len);
}

pub const AdaptiveBufferStrategy = struct {
    grow_len: usize,
    expected_remaining: usize,

    pub fn init(min_u64: u64, max_u64: ?u64) AdaptiveBufferStrategy {
        const min = std.math.cast(usize, min_u64) orelse std.math.maxInt(usize);
        const max: ?usize = if (max_u64) |n| std.math.cast(usize, n) orelse std.math.maxInt(usize) else null;
        const size = initial: {
            if (max) |n| {
                if (min == 0 and n == 0) break :initial 0;
                if (min == n) break :initial cappedNextPowerOfTwo(min);
                if (min == 0) break :initial @min(standard_size, cappedNextPowerOfTwo(n));
            } else if (min == 0) break :initial standard_size;
            break :initial @max(standard_size, cappedNextPowerOfTwo(min));
        };
        return .{ .grow_len = @max(size, tiny_size), .expected_remaining = max orelse std.math.maxInt(usize) };
    }

    pub fn bufferSize(self: AdaptiveBufferStrategy) usize {
        return self.grow_len;
    }

    pub fn notifyRead(self: *AdaptiveBufferStrategy, nread: usize) void {
        self.expected_remaining -|= nread;
        if (nread >= self.grow_len and self.grow_len < max_grow_len and self.expected_remaining > 0) self.grow_len *= 2;
    }
};

fn expectReads(min: u64, max: ?u64, limit: usize, total: usize, expected: []const usize) !void {
    var strategy: AdaptiveBufferStrategy = .init(min, max);
    var remaining = total;
    for (expected) |want| {
        const n = @min(remaining, limit, strategy.bufferSize());
        try std.testing.expectEqual(want, n);
        remaining -= n;
        strategy.notifyRead(n);
    }
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "adaptive read sizes match Rust unknown and known hint fixtures" {
    try expectReads(0, null, 8 * 1024, 10 * 1024, &.{ 8192, 2048 });
    try expectReads(0, null, 128 * 1024, 512 * 1024, &.{ 65536, 131072, 131072, 131072, 65536 });
    try expectReads(0, null, 1024 * 1024, 1024 * 1024, &.{ 65536, 131072, 262144, 524288, 65536 });
    try expectReads(0, null, std.math.maxInt(usize), 64 * 1024 * 1024, &.{
        65536,    131072,   262144,   524288, 1048576, 2097152, 4194304, 8388608,
        16777216, 16777216, 16777216, 65536,
    });
    try expectReads(10 * 1024, 10 * 1024, 8 * 1024, 10 * 1024, &.{ 8192, 2048 });
    // Hints are estimates, including a source larger than its advertised size.
    try expectReads(10 * 1024, 10 * 1024, 8 * 1024, 16 * 1024, &.{ 8192, 8192 });
}

test "size hint classes saturate, round and cap like Rust" {
    const Case = struct { min: u64, max: ?u64, size: usize, remaining: usize };
    for ([_]Case{
        .{ .min = 0, .max = null, .size = standard_size, .remaining = std.math.maxInt(usize) },
        .{ .min = 0, .max = 0, .size = tiny_size, .remaining = 0 },
        .{ .min = 5, .max = 5, .size = tiny_size, .remaining = 5 },
        .{ .min = 1025, .max = 1025, .size = 2048, .remaining = 1025 },
        .{ .min = 0, .max = 5000, .size = 8192, .remaining = 5000 },
        .{ .min = 5000, .max = null, .size = standard_size, .remaining = std.math.maxInt(usize) },
        .{ .min = 5000, .max = 9000, .size = standard_size, .remaining = 9000 },
        .{ .min = std.math.maxInt(u64), .max = null, .size = max_grow_len, .remaining = std.math.maxInt(usize) },
        .{ .min = std.math.maxInt(u64), .max = std.math.maxInt(u64), .size = max_grow_len, .remaining = std.math.maxInt(usize) },
        .{ .min = 0, .max = std.math.maxInt(u64), .size = standard_size, .remaining = std.math.maxInt(usize) },
    }) |case| {
        const strategy: AdaptiveBufferStrategy = .init(case.min, case.max);
        try std.testing.expectEqual(case.size, strategy.bufferSize());
        try std.testing.expectEqual(case.remaining, strategy.expected_remaining);
    }
    var empty: AdaptiveBufferStrategy = .init(0, 0);
    empty.notifyRead(8192);
    try std.testing.expectEqual(@as(usize, tiny_size), empty.bufferSize());
    try std.testing.expectEqual(@as(usize, 0), empty.expected_remaining);
}
