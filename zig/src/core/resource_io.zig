// Copyright 2018-2026 the Deno authors. MIT license.
//! Native resource I/O algorithms from `libs/core/ops_builtin.rs`.
const std = @import("std");
const R = @import("resources.zig");
const AdaptiveBufferStrategy = @import("buffer_strategy.zig").AdaptiveBufferStrategy;

/// Borrow resource for the whole read. The caller owns the returned allocation.
/// Hints only choose allocation sizes; they never limit the bytes read.
pub fn readAll(gpa: std.mem.Allocator, io: std.Io, resource: R.Resource) ![]u8 {
    const hint = resource.sizeHint();
    var strategy: AdaptiveBufferStrategy = .init(hint.min, hint.max);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var used: usize = 0;
    while (true) {
        const target = std.math.add(usize, used, strategy.bufferSize()) catch return error.OutOfMemory;
        if (target > buffer.items.len) {
            const old_len = buffer.items.len;
            try buffer.resize(gpa, target);
            @memset(buffer.items[old_len..], 0);
        }
        const available = buffer.items[used..];
        const n = try resource.read(io, available);
        if (n > available.len) return error.InvalidReadCount;
        if (n == 0) break;
        used += n;
        strategy.notifyRead(n);
    }
    buffer.items.len = used;
    return buffer.toOwnedSlice(gpa);
}

const TestReader = struct {
    data: []const u8,
    offset: usize = 0,
    limit: usize = std.math.maxInt(usize),
    hint: R.SizeHint = .{},
    fail_at: ?usize = null,

    pub fn read(self: *@This(), _: std.Io, buffer: []u8) !usize {
        if (self.fail_at) |at| if (self.offset >= at) return error.ReadFailure;
        const n = @min(buffer.len, self.data.len - self.offset, self.limit);
        @memcpy(buffer[0..n], self.data[self.offset..][0..n]);
        self.offset += n;
        return n;
    }
    pub fn sizeHint(self: *const @This()) R.SizeHint {
        return self.hint;
    }
};

test "read-all consumes short reads and ignores inaccurate hints" {
    const gpa = std.testing.allocator;
    for ([_]R.SizeHint{ .{}, .{ .min = 0, .max = 0 }, .{ .min = 3, .max = 3 }, .{ .min = 1000, .max = 1000 } }) |hint| {
        const resource = try R.Resource.create(gpa, TestReader, .{ .data = "short reads keep going", .limit = 3, .hint = hint });
        defer resource.deinit();
        const result = try readAll(gpa, std.testing.io, resource);
        defer gpa.free(result);
        try std.testing.expectEqualStrings("short reads keep going", result);
    }
    const empty = try R.Resource.create(gpa, TestReader, .{ .data = "" });
    defer empty.deinit();
    const result = try readAll(gpa, std.testing.io, empty);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

fn allocationFailureExercise(gpa: std.mem.Allocator) !void {
    const resource = try R.Resource.create(gpa, TestReader, .{ .data = "an allocation may fail", .limit = 3 });
    defer resource.deinit();
    const result = try readAll(gpa, std.testing.io, resource);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("an allocation may fail", result);
}

test "read-all releases partial output on allocation and native failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
    const resource = try R.Resource.create(std.testing.allocator, TestReader, .{ .data = "partial", .limit = 3, .fail_at = 3 });
    defer resource.deinit();
    try std.testing.expectError(error.ReadFailure, readAll(std.testing.allocator, std.testing.io, resource));
}
