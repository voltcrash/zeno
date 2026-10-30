// Copyright 2018-2026 the Deno authors. MIT license.
//! Owned native byte ranges from `libs/core/io/buffers.rs`.
const std = @import("std");

/// Copies require clone(); every owner calls deinit(). Clones and split views
/// share the allocation, while each has its own cursor and bounds. Clones may
/// be read across worker threads; mutable access requires unique ownership.
/// The allocator must be thread-safe when owners cross threads, and must
/// outlive all views. Runtime I/O workers use std.heap.smp_allocator.
pub const ByteView = struct {
    const Storage = struct {
        refs: std.atomic.Value(usize) = .init(1),
        gpa: std.mem.Allocator,
        allocation: []u8,
    };

    storage: ?*Storage = null,
    start: usize = 0,
    end: usize = 0,
    cursor: usize = 0,

    pub const empty: ByteView = .{};

    /// Takes ownership on success. On failure the caller still owns data.
    pub fn fromOwnedSlice(gpa: std.mem.Allocator, data: []u8) !ByteView {
        if (data.len == 0) {
            gpa.free(data);
            return .empty;
        }
        const storage = try gpa.create(Storage);
        storage.* = .{ .gpa = gpa, .allocation = data };
        return .{ .storage = storage, .end = data.len };
    }

    pub fn alloc(gpa: std.mem.Allocator, size: usize) !ByteView {
        const allocation = try gpa.alloc(u8, size);
        errdefer gpa.free(allocation);
        @memset(allocation, 0);
        return fromOwnedSlice(gpa, allocation);
    }

    pub fn copy(gpa: std.mem.Allocator, data: []const u8) !ByteView {
        const allocation = try gpa.dupe(u8, data);
        errdefer gpa.free(allocation);
        return fromOwnedSlice(gpa, allocation);
    }

    pub fn clone(self: ByteView) ByteView {
        if (self.storage) |storage| {
            const previous = storage.refs.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0);
        }
        return self;
    }

    pub fn deinit(self: *ByteView) void {
        const storage = self.storage;
        self.* = .empty;
        if (storage) |owner| if (owner.refs.fetchSub(1, .acq_rel) == 1) {
            const gpa = owner.gpa;
            gpa.free(owner.allocation);
            gpa.destroy(owner);
        };
    }

    pub fn len(self: ByteView) usize {
        return self.end - self.start - self.cursor;
    }

    pub fn bytes(self: ByteView) []const u8 {
        return if (self.storage) |storage| storage.allocation[self.start + self.cursor .. self.end] else &.{};
    }

    /// Fill a freshly allocated chunk before sharing or returning it.
    pub fn mutableBytes(self: *ByteView) []u8 {
        const storage = self.storage orelse return &.{};
        std.debug.assert(storage.refs.load(.acquire) == 1);
        return storage.allocation[self.start + self.cursor .. self.end];
    }

    pub fn advance(self: *ByteView, n: usize) void {
        std.debug.assert(n <= self.len());
        self.cursor += n;
    }

    pub fn resetCursor(self: *ByteView) usize {
        const old = self.cursor;
        self.cursor = 0;
        return old;
    }

    pub fn truncate(self: *ByteView, size: usize) void {
        self.end = self.start + self.cursor + @min(size, self.len());
    }

    /// Split relative to the current cursor. The tail starts at cursor zero;
    /// the current view keeps its previous cursor, as Rust's split_off does.
    pub fn splitOff(self: *ByteView, at: usize) ByteView {
        std.debug.assert(at <= self.len());
        const split = self.start + self.cursor + at;
        var tail = self.clone();
        tail.start = split;
        tail.cursor = 0;
        self.end = split;
        return tail;
    }

    /// The prefix keeps the previous cursor; the remaining view starts at zero.
    pub fn splitTo(self: *ByteView, at: usize) ByteView {
        std.debug.assert(at <= self.len());
        const split = self.start + self.cursor + at;
        var prefix = self.clone();
        prefix.end = split;
        self.start = split;
        self.cursor = 0;
        return prefix;
    }
};

test "cursor, truncation and split views preserve Rust buffer ranges" {
    const gpa = std.testing.allocator;
    var view = try ByteView.copy(gpa, &.{ 1, 2, 3, 4 });
    defer view.deinit();
    view.advance(1);
    view.truncate(2);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, view.bytes());
    view.advance(1);
    try std.testing.expectEqual(@as(usize, 2), view.resetCursor());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, view.bytes());

    var original = try ByteView.alloc(gpa, 100);
    defer original.deinit();
    for (original.mutableBytes(), 0..) |*byte, i| byte.* = @intCast(i);
    original.advance(25);
    var tail = original.splitOff(10);
    defer tail.deinit();
    var prefix = tail.splitTo(20);
    defer prefix.deinit();
    try std.testing.expectEqual(@as(usize, 25), original.cursor);
    try std.testing.expectEqual(@as(usize, 10), original.len());
    try std.testing.expectEqual(@as(usize, 20), prefix.len());
    try std.testing.expectEqual(@as(usize, 45), tail.len());
    try std.testing.expectEqual(@as(u8, 35), prefix.bytes()[0]);
    try std.testing.expectEqual(@as(u8, 55), tail.bytes()[0]);
    try std.testing.expectEqual(@as(usize, 25), original.resetCursor());
    try std.testing.expectEqual(@as(usize, 100), original.len() + prefix.len() + tail.len());
    original.deinit();
    // Split owners retain their original allocation after the source drops.
    try std.testing.expectEqual(@as(u8, 99), tail.bytes()[44]);
}

fn allocationFailureExercise(gpa: std.mem.Allocator) !void {
    var original = try ByteView.copy(gpa, "shared chunks");
    defer original.deinit();
    var clone = original.clone();
    defer clone.deinit();
    original.deinit();
    try std.testing.expectEqualStrings("shared chunks", clone.bytes());
}

test "native views release every owner on allocation failures and empty splits" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
    var empty = try ByteView.alloc(std.testing.allocator, 0);
    defer empty.deinit();
    var tail = empty.splitOff(0);
    defer tail.deinit();
    var prefix = tail.splitTo(0);
    defer prefix.deinit();
    try std.testing.expectEqual(@as(usize, 0), prefix.len());
}

test "shared native chunk ownership can cross worker threads" {
    const F = struct {
        fn work(input: ByteView) void {
            var owner = input;
            defer owner.deinit();
            for (0..1000) |_| {
                var clone = owner.clone();
                std.debug.assert(std.mem.eql(u8, clone.bytes(), "worker chunk"));
                clone.deinit();
            }
        }
    };
    const io = std.testing.io;
    var original = try ByteView.copy(std.testing.allocator, "worker chunk");
    defer original.deinit();
    var futures: [4]std.Io.Future(void) = undefined;
    var initialized: usize = 0;
    defer for (futures[0..initialized]) |*future| future.await(io);
    for (&futures) |*future| {
        var owner = original.clone();
        future.* = io.concurrent(F.work, .{owner}) catch |err| {
            owner.deinit();
            return err;
        };
        initialized += 1;
    }
}
