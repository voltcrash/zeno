// Copyright 2018-2026 the Deno authors. MIT license.
//! CancelHandle from `libs/core/async_cancel.rs`, using native I/O cancellation.
const std = @import("std");

/// Registrations and cancel/close run on the runtime thread. Workers only
/// read the atomic cancellation flag. Callbacks cancel and join their native
/// future; they must not execute JS or mutate this registration table.
pub const CancelHandle = struct {
    const Registration = struct { context: *anyopaque, cancel: *const fn (*anyopaque, i32) void };
    gpa: std.mem.Allocator,
    canceled: std.atomic.Value(bool) = .init(false),
    registrations: std.AutoHashMapUnmanaged(i32, Registration) = .empty,

    pub fn init(gpa: std.mem.Allocator) CancelHandle {
        return .{ .gpa = gpa };
    }
    pub fn name(_: *const CancelHandle) []const u8 {
        return "cancellation";
    }
    pub fn register(self: *CancelHandle, id: i32, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) !void {
        // A newly registered worker must check the flag before starting I/O,
        // including when the handle was canceled before it was registered.
        try self.registrations.put(self.gpa, id, .{ .context = context, .cancel = callback });
    }
    pub fn unregister(self: *CancelHandle, id: i32) void {
        _ = self.registrations.remove(id);
    }
    pub fn isCanceled(self: *const CancelHandle) bool {
        return self.canceled.load(.acquire);
    }
    pub fn flag(self: *const CancelHandle) *const std.atomic.Value(bool) {
        return &self.canceled;
    }
    pub fn cancel(self: *CancelHandle) void {
        if (self.canceled.swap(true, .acq_rel)) return;
        var it = self.registrations.iterator();
        while (it.next()) |entry| entry.value_ptr.cancel(entry.value_ptr.context, entry.key_ptr.*);
    }
    pub fn close(self: *CancelHandle) void {
        self.cancel();
    }
    pub fn deinit(self: *CancelHandle, _: std.mem.Allocator) void {
        std.debug.assert(self.registrations.count() == 0);
        self.registrations.deinit(self.gpa);
    }
};

test "cancel handles broadcast once and retain cancellation for new work" {
    const Context = struct {
        mask: u32 = 0,
        fn cancel(ctx: *anyopaque, id: i32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mask |= @as(u32, 1) << @intCast(id);
        }
    };
    const gpa = std.testing.allocator;
    var handle: CancelHandle = .init(gpa);
    defer handle.deinit(gpa);
    var context: Context = .{};
    try handle.register(1, &context, Context.cancel);
    try handle.register(2, &context, Context.cancel);
    handle.unregister(2);
    handle.close();
    try std.testing.expectEqual(@as(u32, 2), context.mask);
    context.mask = 0;
    handle.cancel();
    try std.testing.expectEqual(@as(u32, 0), context.mask);
    try handle.register(3, &context, Context.cancel);
    try std.testing.expect(handle.isCanceled());
    handle.unregister(1);
    handle.unregister(3);
}

fn allocationFailureExercise(gpa: std.mem.Allocator) !void {
    const C = struct {
        fn cancel(context: *anyopaque, _: i32) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    var handle: CancelHandle = .init(gpa);
    defer handle.deinit(gpa);
    var calls: usize = 0;
    try handle.register(1, &calls, C.cancel);
    defer handle.unregister(1);
    try handle.register(2, &calls, C.cancel);
    defer handle.unregister(2);
    handle.cancel();
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "cancel registrations release allocations after setup failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
}
