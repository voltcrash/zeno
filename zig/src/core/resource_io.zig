// Copyright 2018-2026 the Deno authors. MIT license.
//! Native resource I/O algorithms from `libs/core/ops_builtin.rs`.
const std = @import("std");
const R = @import("resources.zig");
const IoScope = R.IoScope;
const AdaptiveBufferStrategy = @import("buffer_strategy.zig").AdaptiveBufferStrategy;

/// Pass each source-owned chunk straight to the sink. Close/abort behavior
/// for source and destination belongs to the JS caller, as in Rust's op_pipe.
pub fn pipe(scope: IoScope, source: R.Resource, sink: R.Resource, canceled: ?*const std.atomic.Value(bool)) !void {
    const hint = source.sizeHint();
    var strategy: AdaptiveBufferStrategy = .init(hint.min, hint.max);
    while (true) {
        if (isCanceled(canceled)) return error.OperationCanceled;
        var chunk = source.readChunk(scope, strategy.bufferSize()) catch |err| return if (isCanceled(canceled)) error.OperationCanceled else err;
        defer chunk.deinit();
        if (chunk.len() == 0) return;
        strategy.notifyRead(chunk.len());
        if (isCanceled(canceled)) return error.OperationCanceled;
        sink.writeAll(scope, chunk.bytes()) catch |err| return if (isCanceled(canceled)) error.OperationCanceled else err;
    }
}

fn isCanceled(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |state| state.load(.acquire) else false;
}

/// Borrow resource for the whole read. The caller owns the returned allocation.
/// Hints only choose allocation sizes; they never limit the bytes read.
pub fn readAll(scope: IoScope, resource: R.Resource) ![]u8 {
    const gpa = scope.buffer_allocator;
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
        const n = try resource.read(scope, available);
        if (n > available.len) return error.InvalidReadCount;
        if (n == 0) break;
        used += n;
        strategy.notifyRead(n);
    }
    buffer.items.len = used;
    return buffer.toOwnedSlice(gpa);
}

const TestIo = struct {
    error_context: @import("errors.zig").Context = .{},
    fn scope(self: *TestIo, gpa: std.mem.Allocator) IoScope {
        return .{ .io = std.testing.io, .allocator = gpa, .buffer_allocator = gpa, .error_context = &self.error_context };
    }
};

const TestReader = struct {
    data: []const u8,
    offset: usize = 0,
    limit: usize = std.math.maxInt(usize),
    hint: R.SizeHint = .{},
    fail_at: ?usize = null,

    pub fn read(self: *@This(), _: IoScope, buffer: []u8) !usize {
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
    var test_io: TestIo = .{};
    for ([_]R.SizeHint{ .{}, .{ .min = 0, .max = 0 }, .{ .min = 3, .max = 3 }, .{ .min = 1000, .max = 1000 } }) |hint| {
        const resource = try R.Resource.create(gpa, TestReader, .{ .data = "short reads keep going", .limit = 3, .hint = hint });
        defer resource.deinit();
        const result = try readAll(test_io.scope(gpa), resource);
        defer gpa.free(result);
        try std.testing.expectEqualStrings("short reads keep going", result);
    }
    const empty = try R.Resource.create(gpa, TestReader, .{ .data = "" });
    defer empty.deinit();
    const result = try readAll(test_io.scope(gpa), empty);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

fn allocationFailureExercise(gpa: std.mem.Allocator) !void {
    var test_io: TestIo = .{};
    const resource = try R.Resource.create(gpa, TestReader, .{ .data = "an allocation may fail", .limit = 3 });
    defer resource.deinit();
    const result = try readAll(test_io.scope(gpa), resource);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("an allocation may fail", result);
}

test "read-all releases partial output on allocation and native failures" {
    var test_io: TestIo = .{};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
    const resource = try R.Resource.create(std.testing.allocator, TestReader, .{ .data = "partial", .limit = 3, .fail_at = 3 });
    defer resource.deinit();
    try std.testing.expectError(error.ReadFailure, readAll(test_io.scope(std.testing.allocator), resource));
}

const PipeSink = struct {
    gpa: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    expected_address: ?usize = null,
    fail_at: ?usize = null,
    pub fn write(self: *@This(), _: IoScope, bytes: []const u8) !usize {
        if (self.fail_at) |at| if (self.output.items.len >= at) return error.WriteFailure;
        if (self.expected_address) |address| {
            if (@intFromPtr(bytes.ptr) != address + self.output.items.len) return error.CopiedChunk;
        }
        const n = @min(bytes.len, 2);
        try self.output.appendSlice(self.gpa, bytes[0..n]);
        return n;
    }
    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.output.deinit(self.gpa);
    }
};

test "pipe passes source-owned chunks directly through partial sink writes" {
    const ChunkSource = struct {
        pending: R.ByteView,
        pub fn readChunk(self: *@This(), _: IoScope, limit: usize) !R.ByteView {
            return self.pending.splitTo(@min(limit, self.pending.len(), 3));
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.pending.deinit();
        }
    };
    const gpa = std.testing.allocator;
    var test_io: TestIo = .{};
    const source = owned: {
        var view = try R.ByteView.copy(gpa, "source-owned pipe chunks");
        errdefer view.deinit();
        break :owned try R.Resource.create(gpa, ChunkSource, .{ .pending = view });
    };
    defer source.deinit();
    const source_ref = try source.downcast(ChunkSource);
    defer source_ref.deinit();
    const sink = try R.Resource.create(gpa, PipeSink, .{ .gpa = gpa, .expected_address = @intFromPtr(source_ref.ptr().pending.bytes().ptr) });
    defer sink.deinit();
    try pipe(test_io.scope(gpa), source, sink, null);
    const sink_ref = try sink.downcast(PipeSink);
    defer sink_ref.deinit();
    try std.testing.expectEqualStrings("source-owned pipe chunks", sink_ref.ptr().output.items);
}

fn pipeAllocationFailureExercise(gpa: std.mem.Allocator) !void {
    var test_io: TestIo = .{};
    const source = try R.Resource.create(gpa, TestReader, .{ .data = "native pipe", .limit = 3 });
    defer source.deinit();
    const sink = try R.Resource.create(gpa, PipeSink, .{ .gpa = gpa });
    defer sink.deinit();
    try pipe(test_io.scope(gpa), source, sink, null);
    const held = try sink.downcast(PipeSink);
    defer held.deinit();
    try std.testing.expectEqualStrings("native pipe", held.ptr().output.items);
}

test "pipe cleans up chunk allocations on allocation, read, write and cancellation errors" {
    const gpa = std.testing.allocator;
    var test_io: TestIo = .{};
    try std.testing.checkAllAllocationFailures(gpa, pipeAllocationFailureExercise, .{});
    const source = try R.Resource.create(gpa, TestReader, .{ .data = "partial", .limit = 3, .fail_at = 3 });
    defer source.deinit();
    const sink = try R.Resource.create(gpa, PipeSink, .{ .gpa = gpa });
    defer sink.deinit();
    try std.testing.expectError(error.ReadFailure, pipe(test_io.scope(gpa), source, sink, null));
    const other_source = try R.Resource.create(gpa, TestReader, .{ .data = "write failure" });
    defer other_source.deinit();
    const other_sink = try R.Resource.create(gpa, PipeSink, .{ .gpa = gpa, .fail_at = 2 });
    defer other_sink.deinit();
    try std.testing.expectError(error.WriteFailure, pipe(test_io.scope(gpa), other_source, other_sink, null));
    const canceled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.OperationCanceled, pipe(test_io.scope(gpa), source, sink, &canceled));
}

test "owned I/O buffers do not allocate from the error and result arena" {
    const gpa = std.testing.allocator;
    var test_io: TestIo = .{};
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var scope = test_io.scope(gpa);
    scope.allocator = failing.allocator();
    const source = try R.Resource.create(gpa, TestReader, .{ .data = "independent chunk allocation", .limit = 3 });
    defer source.deinit();
    const sink = try R.Resource.create(gpa, PipeSink, .{ .gpa = gpa });
    defer sink.deinit();
    try pipe(scope, source, sink, null);
    const held = try sink.downcast(PipeSink);
    defer held.deinit();
    try std.testing.expectEqualStrings("independent chunk allocation", held.ptr().output.items);
    const another_source = try R.Resource.create(gpa, TestReader, .{ .data = "owned read-all result" });
    defer another_source.deinit();
    const output = try readAll(scope, another_source);
    defer gpa.free(output);
    try std.testing.expectEqualStrings("owned read-all result", output);
}

test "typed resource failures remain available after adapter buffer cleanup" {
    const Reader = struct {
        pub fn read(_: *@This(), scope: IoScope, _: []u8) !usize {
            return scope.fail(.{
                .class_name = "NotFound",
                .message = "native read failure",
                .properties = &.{.{ .name = "code", .value = .{ .string = "ENOENT" } }},
            });
        }
    };
    const gpa = std.testing.allocator;
    var test_io: TestIo = .{};
    const scope = test_io.scope(gpa);
    const resource = try R.Resource.create(gpa, Reader, .{});
    defer resource.deinit();
    try std.testing.expectError(error.OpError, resource.readChunk(scope, 1024));
    try std.testing.expectEqualStrings("NotFound", test_io.error_context.exception.?.class_name);
    try std.testing.expectError(error.OpError, readAll(scope, resource));
    const exception = test_io.error_context.exception.?;
    try std.testing.expectEqualStrings("native read failure", exception.message);
    try std.testing.expectEqualStrings("ENOENT", exception.properties[0].value.string);
}
