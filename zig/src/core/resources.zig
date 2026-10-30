// Copyright 2018-2026 the Deno authors. MIT license.
//! Resource ownership and I/O from `libs/core/io/{resource,resource_table}.rs`.
//! Handles are reference counted on the runtime thread, like Rust's Rc.
//! Closing a rid removes table ownership; outstanding operation handles can
//! retain the value until their work finishes.
const std = @import("std");
pub const ByteView = @import("byte_view.zig").ByteView;
pub const JsError = @import("errors.zig").JsError;

pub const ResourceId = u32;
pub const LookupError = error{BadResourceId};
pub const SizeHint = struct { min: u64 = 0, max: ?u64 = null };

const VTable = struct {
    type_token: *const u8,
    ptr: *const fn (*Header) *anyopaque,
    name: *const fn (*Header) []const u8,
    close: *const fn (*Header) void,
    cancel_read: *const fn (*Header) void,
    read: *const fn (*Header, std.Io, []u8) anyerror!usize,
    read_chunk: *const fn (*Header, std.Io, std.mem.Allocator, usize) anyerror!ByteView,
    write: *const fn (*Header, std.Io, []const u8) anyerror!usize,
    write_error: *const fn (*Header, std.Io, JsError) anyerror!void,
    read_sync: *const fn (*Header, std.Io, []u8) anyerror!usize,
    write_sync: *const fn (*Header, std.Io, []const u8) anyerror!usize,
    write_all: *const fn (*Header, std.Io, []const u8) anyerror!void,
    shutdown: *const fn (*Header, std.Io) anyerror!void,
    size_hint: *const fn (*Header) SizeHint,
    destroy: *const fn (*Header) void,
};
const Header = struct {
    refs: usize = 1,
    gpa: std.mem.Allocator,
    vtable: *const VTable,
};

/// An owning erased handle. Copies require `clone`; each owner calls `deinit`.
/// T may provide name(*const T), close(*T), cancelReadOps(*T), and
/// deinit(*T, Allocator). Only final release invokes deinit; close is explicit.
/// Optional I/O methods take (*T, std.Io, buffer) and return !usize:
/// read/readSync use []u8, write/writeSync use []const u8. writeAll takes
/// []const u8 and returns !void; shutdown takes (*T, std.Io) and returns !void.
/// sizeHint(*const T) returns SizeHint; it may be queried on an I/O worker.
/// readChunk(*T, std.Io, Allocator, limit) returns an owned !ByteView. A
/// resource can provide this instead of read, or override both paths.
/// writeError(*T, std.Io, JsError) returns !void and borrows the error fields.
pub const Resource = struct {
    pub const ResourceType = void;
    header: *Header,

    /// Ownership of value transfers on success; on failure it stays with the caller.
    pub fn create(gpa: std.mem.Allocator, comptime T: type, value: T) !Resource {
        const node = try gpa.create(Impl(T).Node);
        node.* = .{ .header = .{ .gpa = gpa, .vtable = &Impl(T).vtable }, .value = value };
        return .{ .header = &node.header };
    }

    pub fn clone(self: Resource) Resource {
        std.debug.assert(self.header.refs > 0);
        self.header.refs += 1;
        return self;
    }

    pub fn deinit(self: Resource) void {
        std.debug.assert(self.header.refs > 0);
        self.header.refs -= 1;
        if (self.header.refs == 0) self.header.vtable.destroy(self.header);
    }

    pub fn name(self: Resource) []const u8 {
        return self.header.vtable.name(self.header);
    }

    pub fn close(self: Resource) void {
        self.header.vtable.close(self.header);
    }

    pub fn cancelReadOps(self: Resource) void {
        self.header.vtable.cancel_read(self.header);
    }

    /// Native I/O bodies borrow this handle and its buffers. Async methods
    /// run on workers and must synchronize their own state; refcounts and
    /// close hooks remain on the runtime thread. Use cancellable std.Io
    /// waits/locks so runtime shutdown can join blocked operations.
    pub fn read(self: Resource, io: std.Io, data: []u8) !usize {
        return self.header.vtable.read(self.header, io, data);
    }
    /// Read an owned chunk with at most limit bytes. Native pipes pass this
    /// view directly to a sink; BYOB-only resources allocate their own chunk.
    pub fn readChunk(self: Resource, io: std.Io, gpa: std.mem.Allocator, limit: usize) !ByteView {
        return self.header.vtable.read_chunk(self.header, io, gpa, limit);
    }
    pub fn write(self: Resource, io: std.Io, data: []const u8) !usize {
        return self.header.vtable.write(self.header, io, data);
    }
    pub fn writeError(self: Resource, io: std.Io, exception: JsError) !void {
        return self.header.vtable.write_error(self.header, io, exception);
    }
    pub fn readSync(self: Resource, io: std.Io, data: []u8) !usize {
        return self.header.vtable.read_sync(self.header, io, data);
    }
    pub fn writeSync(self: Resource, io: std.Io, data: []const u8) !usize {
        return self.header.vtable.write_sync(self.header, io, data);
    }
    pub fn writeAll(self: Resource, io: std.Io, data: []const u8) !void {
        return self.header.vtable.write_all(self.header, io, data);
    }
    pub fn shutdown(self: Resource, io: std.Io) !void {
        return self.header.vtable.shutdown(self.header, io);
    }
    pub fn sizeHint(self: Resource) SizeHint {
        return self.header.vtable.size_hint(self.header);
    }

    pub fn downcast(self: Resource, comptime T: type) LookupError!ResourceRef(T) {
        if (self.header.vtable.type_token != &Impl(T).type_token) return error.BadResourceId;
        return .{ .resource = self.clone() };
    }
};

pub fn ResourceRef(comptime T: type) type {
    return struct {
        pub const ResourceType = T;
        resource: Resource,

        pub fn ptr(self: @This()) *T {
            return @ptrCast(@alignCast(self.resource.header.vtable.ptr(self.resource.header)));
        }

        pub fn clone(self: @This()) @This() {
            return .{ .resource = self.resource.clone() };
        }

        pub fn deinit(self: @This()) void {
            self.resource.deinit();
        }
    };
}

fn Impl(comptime T: type) type {
    return struct {
        const Node = struct { header: Header, value: T };
        // Mutable storage gives each concrete type a unique address, even if
        // the linker folds otherwise identical vtables or empty resources.
        var type_token: u8 = 0;
        const vtable: VTable = .{
            .type_token = &type_token,
            .ptr = ptr,
            .name = name,
            .close = close,
            .cancel_read = cancelRead,
            .read = read,
            .read_chunk = readChunk,
            .write = write,
            .write_error = writeError,
            .read_sync = readSync,
            .write_sync = writeSync,
            .write_all = writeAll,
            .shutdown = shutdown,
            .size_hint = sizeHint,
            .destroy = destroy,
        };

        fn node(h: *Header) *Node {
            return @alignCast(@fieldParentPtr("header", h));
        }
        fn ptr(h: *Header) *anyopaque {
            return &node(h).value;
        }
        fn name(h: *Header) []const u8 {
            return if (@hasDecl(T, "name")) node(h).value.name() else @typeName(T);
        }
        fn close(h: *Header) void {
            if (@hasDecl(T, "close")) node(h).value.close();
        }
        fn cancelRead(h: *Header) void {
            if (@hasDecl(T, "cancelReadOps")) node(h).value.cancelReadOps();
        }
        fn read(h: *Header, io: std.Io, data: []u8) !usize {
            if (@hasDecl(T, "read")) return node(h).value.read(io, data);
            if (@hasDecl(T, "readChunk")) {
                var chunk = try readChunk(h, io, std.heap.smp_allocator, data.len);
                defer chunk.deinit();
                @memcpy(data[0..chunk.len()], chunk.bytes());
                return chunk.len();
            }
            return error.NotSupported;
        }
        fn readChunk(h: *Header, io: std.Io, gpa: std.mem.Allocator, limit: usize) !ByteView {
            if (@hasDecl(T, "readChunk")) {
                var chunk = try node(h).value.readChunk(io, gpa, limit);
                if (chunk.len() > limit) {
                    chunk.deinit();
                    return error.InvalidReadCount;
                }
                return chunk;
            }
            if (@hasDecl(T, "read")) {
                var chunk = try ByteView.alloc(gpa, limit);
                errdefer chunk.deinit();
                const n = try node(h).value.read(io, chunk.mutableBytes());
                if (n > limit) return error.InvalidReadCount;
                chunk.truncate(n);
                return chunk;
            }
            return error.NotSupported;
        }
        fn write(h: *Header, io: std.Io, data: []const u8) !usize {
            if (@hasDecl(T, "write")) return node(h).value.write(io, data);
            return error.NotSupported;
        }
        fn writeError(h: *Header, io: std.Io, exception: JsError) !void {
            if (@hasDecl(T, "writeError")) return node(h).value.writeError(io, exception);
            return error.NotSupported;
        }
        fn readSync(h: *Header, io: std.Io, data: []u8) !usize {
            if (@hasDecl(T, "readSync")) return node(h).value.readSync(io, data);
            return error.NotSupported;
        }
        fn writeSync(h: *Header, io: std.Io, data: []const u8) !usize {
            if (@hasDecl(T, "writeSync")) return node(h).value.writeSync(io, data);
            return error.NotSupported;
        }
        fn writeAll(h: *Header, io: std.Io, data: []const u8) !void {
            if (@hasDecl(T, "writeAll")) return node(h).value.writeAll(io, data);
            var offset: usize = 0;
            while (offset < data.len) {
                const n = try write(h, io, data[offset..]);
                if (n == 0) return error.WriteZero;
                if (n > data.len - offset) return error.InvalidWriteCount;
                offset += n;
            }
        }
        fn shutdown(h: *Header, io: std.Io) !void {
            if (@hasDecl(T, "shutdown")) return node(h).value.shutdown(io);
            return error.NotSupported;
        }
        fn sizeHint(h: *Header) SizeHint {
            return if (@hasDecl(T, "sizeHint")) node(h).value.sizeHint() else .{};
        }
        fn destroy(h: *Header) void {
            const n = node(h);
            const gpa = h.gpa;
            if (@hasDecl(T, "deinit")) n.value.deinit(gpa);
            gpa.destroy(n);
        }
    };
}

pub const ResourceTable = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(ResourceId, Resource) = .empty,
    next_rid: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) ResourceTable {
        return .{ .gpa = gpa };
    }

    /// Dropping table ownership does not call close hooks, matching Rust's
    /// table drop. Final resource destructors still release their native data.
    pub fn deinit(self: *ResourceTable) void {
        var entries = self.entries;
        self.entries = .empty;
        defer entries.deinit(self.gpa);
        var it = entries.valueIterator();
        while (it.next()) |resource| resource.deinit();
    }

    pub fn len(self: *const ResourceTable) usize {
        return self.entries.count();
    }

    pub fn has(self: *const ResourceTable, rid: ResourceId) bool {
        return self.entries.contains(rid);
    }

    /// Consumes the supplied owner, including on error. IDs increase without
    /// reuse; exhausting u32 IDs fails rather than aliasing a stale handle.
    pub fn add(self: *ResourceTable, resource: Resource) !ResourceId {
        errdefer resource.deinit();
        const rid = std.math.cast(ResourceId, self.next_rid) orelse return error.ResourceIdExhausted;
        try self.entries.put(self.gpa, rid, resource);
        self.next_rid += 1;
        return rid;
    }

    pub fn getAny(self: *const ResourceTable, rid: ResourceId) LookupError!Resource {
        return (self.entries.get(rid) orelse return error.BadResourceId).clone();
    }

    pub fn get(self: *const ResourceTable, comptime T: type, rid: ResourceId) LookupError!ResourceRef(T) {
        return (self.entries.get(rid) orelse return error.BadResourceId).downcast(T);
    }

    /// Transfer ownership out of the table without invoking the close hook.
    pub fn takeAny(self: *ResourceTable, rid: ResourceId) LookupError!Resource {
        return (self.entries.fetchRemove(rid) orelse return error.BadResourceId).value;
    }

    pub fn take(self: *ResourceTable, comptime T: type, rid: ResourceId) LookupError!ResourceRef(T) {
        const result = try self.get(T, rid);
        (try self.takeAny(rid)).deinit();
        return result;
    }

    /// Consumes a new owner and drops the old table owner without calling
    /// close, as Rust's replace does. Existing handles keep their old value.
    pub fn replace(self: *ResourceTable, rid: ResourceId, resource: Resource) LookupError!void {
        errdefer resource.deinit();
        const entry = self.entries.getPtr(rid) orelse return error.BadResourceId;
        const old = entry.*;
        entry.* = resource;
        old.deinit();
    }
};

const TestCounts = struct { closes: usize = 0, cancels: usize = 0, drops: usize = 0 };

const TestChunkSource = struct {
    pending: ByteView,
    pub fn readChunk(self: *@This(), _: std.Io, _: std.mem.Allocator, limit: usize) !ByteView {
        return self.pending.splitTo(@min(limit, self.pending.len()));
    }
    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.pending.deinit();
    }
};

test "source-owned chunks retain the source allocation and support BYOB fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var retained: ByteView = .empty;
    defer retained.deinit();
    {
        const resource = owned: {
            var source = try ByteView.copy(gpa, "source owned bytes");
            errdefer source.deinit();
            break :owned try Resource.create(gpa, TestChunkSource, .{ .pending = source });
        };
        defer resource.deinit();
        const held = try resource.downcast(TestChunkSource);
        defer held.deinit();
        const address = @intFromPtr(held.ptr().pending.bytes().ptr);
        retained = try resource.readChunk(io, gpa, 6);
        try std.testing.expectEqual(address, @intFromPtr(retained.bytes().ptr));
        var buffer: [32]u8 = undefined;
        const n = try resource.read(io, &buffer);
        try std.testing.expectEqualStrings(" owned bytes", buffer[0..n]);
        try std.testing.expectEqual(@as(usize, 0), try resource.read(io, &buffer));
        try std.testing.expectError(error.NotSupported, resource.readSync(io, &buffer));
    }
    try std.testing.expectEqualStrings("source", retained.bytes());
}

fn chunkAllocationFailureExercise(gpa: std.mem.Allocator) !void {
    const Reader = struct {
        pub fn read(_: *@This(), _: std.Io, data: []u8) !usize {
            const n = @min(data.len, 3);
            @memcpy(data[0..n], "abc"[0..n]);
            return n;
        }
    };
    const resource = try Resource.create(gpa, Reader, .{});
    defer resource.deinit();
    var chunk = try resource.readChunk(std.testing.io, gpa, 8);
    defer chunk.deinit();
    try std.testing.expectEqualStrings("abc", chunk.bytes());
}

test "BYOB resources allocate chunks and release failed read allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, chunkAllocationFailureExercise, .{});
    const Failing = struct {
        pub fn read(_: *@This(), _: std.Io, _: []u8) !usize {
            return error.ReadFailure;
        }
    };
    const resource = try Resource.create(std.testing.allocator, Failing, .{});
    defer resource.deinit();
    try std.testing.expectError(error.ReadFailure, resource.readChunk(std.testing.io, std.testing.allocator, 1024));
}

test "chunk overrides take priority and invalid counts release the chunk" {
    const Override = struct {
        pub fn read(_: *@This(), _: std.Io, _: []u8) !usize {
            return error.ByobOverride;
        }
        pub fn readChunk(_: *@This(), _: std.Io, gpa: std.mem.Allocator, _: usize) !ByteView {
            return ByteView.copy(gpa, "chunk override");
        }
    };
    const gpa = std.testing.allocator;
    const resource = try Resource.create(gpa, Override, .{});
    defer resource.deinit();
    var chunk = try resource.readChunk(std.testing.io, gpa, 32);
    defer chunk.deinit();
    try std.testing.expectEqualStrings("chunk override", chunk.bytes());
    var data: [32]u8 = undefined;
    try std.testing.expectError(error.ByobOverride, resource.read(std.testing.io, &data));
    try std.testing.expectError(error.InvalidReadCount, resource.readChunk(std.testing.io, gpa, 1));
}

test "I/O defaults and partial write-all follow resource contracts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const empty = try Resource.create(gpa, struct {}, .{});
    defer empty.deinit();
    var data: [8]u8 = undefined;
    try std.testing.expectError(error.NotSupported, empty.read(io, &data));
    try std.testing.expectError(error.NotSupported, empty.readChunk(io, gpa, data.len));
    try std.testing.expectError(error.NotSupported, empty.readSync(io, &data));
    try std.testing.expectError(error.NotSupported, empty.write(io, "x"));
    try std.testing.expectError(error.NotSupported, empty.writeError(io, JsError.typeError("stream error")));
    try std.testing.expectError(error.NotSupported, empty.writeSync(io, "x"));
    try std.testing.expectError(error.NotSupported, empty.shutdown(io));
    try empty.writeAll(io, "");

    const Partial = struct {
        output: [8]u8 = undefined,
        len: usize = 0,
        calls: usize = 0,
        pub fn write(self: *@This(), _: std.Io, bytes: []const u8) !usize {
            const n = @min(bytes.len, 2);
            @memcpy(self.output[self.len..][0..n], bytes[0..n]);
            self.len += n;
            self.calls += 1;
            return n;
        }
    };
    const writer = try Resource.create(gpa, Partial, .{});
    defer writer.deinit();
    try writer.writeAll(io, "partial");
    const held = try writer.downcast(Partial);
    defer held.deinit();
    try std.testing.expectEqualStrings("partial", held.ptr().output[0..held.ptr().len]);
    try std.testing.expectEqual(@as(usize, 4), held.ptr().calls);
    // Providing async write does not silently implement synchronous write.
    try std.testing.expectError(error.NotSupported, writer.writeSync(io, "x"));
}

test "resources receive typed native error descriptions and propagate write failures" {
    const Receiver = struct {
        calls: usize = 0,
        pub fn writeError(self: *@This(), _: std.Io, exception: JsError) !void {
            try std.testing.expectEqualStrings("TypeError", exception.class_name);
            if (std.mem.eql(u8, exception.message, "reject")) return error.WriteFailure;
            try std.testing.expectEqualStrings("stream failure", exception.message);
            self.calls += 1;
        }
    };
    const gpa = std.testing.allocator;
    const resource = try Resource.create(gpa, Receiver, .{});
    defer resource.deinit();
    try resource.writeError(std.testing.io, JsError.typeError("stream failure"));
    try std.testing.expectError(error.WriteFailure, resource.writeError(std.testing.io, JsError.typeError("reject")));
    const held = try resource.downcast(Receiver);
    defer held.deinit();
    try std.testing.expectEqual(@as(usize, 1), held.ptr().calls);
}

test "write-all handles zero progress, native errors and overrides" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Zero = struct {
        pub fn write(_: *@This(), _: std.Io, _: []const u8) !usize {
            return 0;
        }
    };
    const zero = try Resource.create(gpa, Zero, .{});
    defer zero.deinit();
    try std.testing.expectError(error.WriteZero, zero.writeAll(io, "x"));
    const Failure = struct {
        pub fn write(_: *@This(), _: std.Io, _: []const u8) !usize {
            return error.BrokenPipe;
        }
    };
    const failure = try Resource.create(gpa, Failure, .{});
    defer failure.deinit();
    try std.testing.expectError(error.BrokenPipe, failure.writeAll(io, "x"));
    const Override = struct {
        pub fn writeAll(_: *@This(), _: std.Io, bytes: []const u8) !void {
            if (!std.mem.eql(u8, bytes, "optimized")) return error.WrongBuffer;
        }
    };
    const optimized = try Resource.create(gpa, Override, .{});
    defer optimized.deinit();
    try optimized.writeAll(io, "optimized");
}
const TestResource = struct {
    counts: *TestCounts,
    value: u32,
    pub fn name(_: *const @This()) []const u8 {
        return "testResource";
    }
    pub fn close(self: *@This()) void {
        self.counts.closes += 1;
    }
    pub fn cancelReadOps(self: *@This()) void {
        self.counts.cancels += 1;
    }
    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.counts.drops += 1;
    }
};

test "typed ownership survives removal and IDs are not reused" {
    const gpa = std.testing.allocator;
    var table: ResourceTable = .init(gpa);
    defer table.deinit();
    var counts: TestCounts = .{};
    const rid = try table.add(try Resource.create(gpa, TestResource, .{ .counts = &counts, .value = 42 }));
    try std.testing.expectEqual(@as(u32, 0), rid);
    const wrong_type = struct {};
    try std.testing.expectError(error.BadResourceId, table.take(wrong_type, rid));
    try std.testing.expect(table.has(rid));
    const held = try table.get(TestResource, rid);
    const taken = try table.take(TestResource, rid);
    try std.testing.expect(!table.has(rid));
    try std.testing.expectEqual(@as(usize, 0), counts.closes);
    taken.resource.close();
    taken.resource.cancelReadOps();
    taken.deinit();
    try std.testing.expectEqual(@as(usize, 0), counts.drops);
    try std.testing.expectEqual(@as(u32, 42), held.ptr().value);
    held.deinit();
    try std.testing.expectEqual(TestCounts{ .closes = 1, .cancels = 1, .drops = 1 }, counts);
    const next = try table.add(try Resource.create(gpa, wrong_type, .{}));
    try std.testing.expectEqual(@as(u32, 1), next);
    try std.testing.expectError(error.BadResourceId, table.getAny(rid));
}

test "replacement and table drop release owners without calling close" {
    const gpa = std.testing.allocator;
    var table: ResourceTable = .init(gpa);
    var old_counts: TestCounts = .{};
    var new_counts: TestCounts = .{};
    const rid = try table.add(try Resource.create(gpa, TestResource, .{ .counts = &old_counts, .value = 1 }));
    const held = try table.get(TestResource, rid);
    try table.replace(rid, try Resource.create(gpa, TestResource, .{ .counts = &new_counts, .value = 2 }));
    const current = try table.get(TestResource, rid);
    try std.testing.expectEqual(@as(u32, 1), held.ptr().value);
    try std.testing.expectEqual(@as(u32, 2), current.ptr().value);
    current.deinit();
    table.deinit();
    try std.testing.expectEqual(@as(usize, 1), new_counts.drops);
    try std.testing.expectEqual(@as(usize, 0), old_counts.drops);
    held.deinit();
    try std.testing.expectEqual(@as(usize, 1), old_counts.drops);
    try std.testing.expectEqual(@as(usize, 0), old_counts.closes + new_counts.closes);
}

fn allocationFailureExercise(gpa: std.mem.Allocator) !void {
    var table: ResourceTable = .init(gpa);
    defer table.deinit();
    _ = try table.add(try Resource.create(gpa, struct {}, .{}));
}

test "failed insertion releases its resource owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
}
