// Copyright 2018-2026 the Deno authors. MIT license.
//! Resource identity and ownership from `libs/core/io/resource_table.rs`.
//! Handles are reference counted on the runtime thread, like Rust's Rc.
//! Closing a rid removes table ownership; outstanding operation handles can
//! retain the value until their work finishes. I/O methods follow with ops.
const std = @import("std");

pub const ResourceId = u32;
pub const LookupError = error{BadResourceId};

const VTable = struct {
    type_token: *const u8,
    ptr: *const fn (*Header) *anyopaque,
    name: *const fn (*Header) []const u8,
    close: *const fn (*Header) void,
    cancel_read: *const fn (*Header) void,
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
pub const Resource = struct {
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
