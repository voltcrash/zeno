// Copyright 2018-2026 the Deno authors. MIT license.
//! Runtime-thread registration/consumption of op_pipe's optional cancel RID.
const std = @import("std");
const ops = @import("ops.zig");
const v8 = @import("../v8/v8.zig");
const R = @import("resources.zig");
const CancelHandle = @import("async_cancel.zig").CancelHandle;

pub const PipeCancel = struct {
    pub const is_async_arg = true;
    runtime: *@import("runtime.zig").JsRuntime,
    promise_id: i32,
    rid: ?u32,
    handle: ?R.ResourceRef(CancelHandle),
    finished: bool = false,

    pub fn fromV8(scope: ops.Scope, value: *const v8.Value) ops.ConvertError!PipeCancel {
        const rid = if (v8.c.v8__Value__IsNullOrUndefined(value)) null else try ops.fromV8(u32, scope, value);
        const handle = if (rid) |id| scope.runtime.resources.get(CancelHandle, id) catch null else null;
        errdefer if (handle) |h| h.deinit();
        const promise_id = scope.promise_id.?;
        if (handle) |h| try h.ptr().register(promise_id, &scope.runtime.async_driver, cancelNative);
        return .{ .runtime = scope.runtime, .promise_id = promise_id, .rid = rid, .handle = handle };
    }

    fn cancelNative(context: *anyopaque, id: i32) void {
        const driver: *@import("async_ops.zig").Driver = @ptrCast(@alignCast(context));
        driver.cancel(id);
    }

    /// Worker access is limited to this stable native atomic flag.
    pub fn flag(self: PipeCancel) ?*const std.atomic.Value(bool) {
        return if (self.handle) |handle| handle.ptr().flag() else null;
    }

    /// Rust consumes the optional RID on success and error, including a RID
    /// that names another resource type. Do this before building errors or
    /// settling promises; microtasks must observe the consumed handle.
    pub fn beforeResolve(self: *PipeCancel) void {
        if (self.finished) return;
        self.finished = true;
        if (self.handle) |h| h.ptr().unregister(self.promise_id);
        if (self.rid) |rid| {
            const resource = self.runtime.resources.takeAny(rid) catch return;
            defer resource.deinit();
            resource.close();
        }
    }

    pub fn deinit(self: *PipeCancel) void {
        self.beforeResolve();
        if (self.handle) |h| h.deinit();
        self.handle = null;
    }
};
