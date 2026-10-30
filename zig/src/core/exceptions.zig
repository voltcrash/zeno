// Copyright 2018-2026 the Deno authors. MIT license.
//! HostPromiseRejectionTracker from runtime/exception_state.rs.
const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const JsRuntime = @import("runtime.zig").JsRuntime;

const Rejection = struct {
    promise: v8.Global(c.Promise),
    reason: v8.Global(v8.Value),
    context: v8.Global(v8.Value),

    fn deinit(self: Rejection) void {
        self.promise.deinit();
        self.reason.deinit();
        self.context.deinit();
    }
};

pub const ExceptionState = struct {
    pending: std.ArrayList(Rejection) = .empty,
    handled: std.ArrayList(Rejection) = .empty,
    handled_handler: ?v8.Global(c.Function) = null,
    allocation_failed: bool = false,

    pub fn deinit(self: *ExceptionState, gpa: std.mem.Allocator) void {
        for (self.pending.items) |r| r.deinit();
        for (self.handled.items) |r| r.deinit();
        self.pending.deinit(gpa);
        self.handled.deinit(gpa);
        if (self.handled_handler) |f| f.deinit();
    }

    /// Removing a rejection promptly releases our strong reference. Identity
    /// uses V8's equality operation, not handle addresses or identity hashes.
    pub fn removePending(self: *ExceptionState, iso: *v8.Isolate, promise: *const c.Promise) bool {
        for (self.pending.items, 0..) |r, i| {
            if (c.v8__Value__StrictEquals(@ptrCast(r.promise.get(iso)), @ptrCast(promise))) {
                self.pending.orderedRemove(i).deinit();
                return true;
            }
        }
        return false;
    }

    pub fn promiseRejectCallback(message: c.PromiseRejectMessage) callconv(.c) void {
        const iso = c.v8__Isolate__GetCurrent();
        const rt = JsRuntime.fromIsolate(iso);
        const self = &rt.exceptions;
        const promise = c.v8__PromiseRejectMessage__GetPromise(&message);
        const event = c.v8__PromiseRejectMessage__GetEvent(&message);
        if (event == .handler_added_after_reject) {
            if (self.removePending(iso, promise) or self.handled_handler == null) return;
        } else if (event != .reject_with_no_handler) {
            return; // resolve/reject after settlement must not warn
        }
        const reason = if (event == .reject_with_no_handler)
            c.v8__PromiseRejectMessage__GetValue(&message) orelse @as(*const v8.Value, @ptrCast(c.v8__Undefined(iso)))
        else
            c.v8__Promise__Result(promise);
        const r: Rejection = .{
            .promise = .init(iso, promise),
            .reason = .init(iso, reason),
            .context = .init(iso, c.v8__Context__GetContinuationPreservedEmbedderData(iso)),
        };
        const queue = if (event == .reject_with_no_handler) &self.pending else &self.handled;
        queue.append(rt.gpa, r) catch {
            r.deinit();
            self.allocation_failed = true;
        };
        if (event == .reject_with_no_handler) {
            // This buffer is private to core and rooted for the runtime's
            // lifetime. Do not re-enter JS from V8's rejection callback.
            if (rt.tick_info) |info| info[1] = 1;
        }
    }

    /// Drain as [promise, reason, asyncContext, ...], as the Rust op does.
    pub fn drainPending(self: *ExceptionState, rt: *JsRuntime) v8.Error!*const v8.Value {
        const iso = rt.isolate();
        if (self.allocation_failed) return error.OutOfMemory;
        if (self.pending.items.len == 0) return @ptrCast(c.v8__Undefined(iso));
        var queue = self.pending;
        self.pending = .empty;
        defer {
            for (queue.items) |r| r.deinit();
            queue.deinit(rt.gpa);
        }
        const length = std.math.cast(c_int, queue.items.len * 3) orelse return error.OutOfMemory;
        const array = c.v8__Array__New(iso, length);
        for (queue.items, 0..) |r, i| {
            const values = [_]*const v8.Value{ @ptrCast(r.promise.get(iso)), r.reason.get(iso), r.context.get(iso) };
            for (values, 0..) |value, j| {
                if (c.v8__Object__SetIndex(@ptrCast(array), rt.context, @intCast(i * 3 + j), value) != .just_true) return error.JsException;
            }
        }
        return @ptrCast(array);
    }

    /// Deliver late-handler notifications before the unhandled queue, as in
    /// jsruntime.rs. Detach the batch so callbacks may safely queue more work.
    pub fn dispatchHandled(self: *ExceptionState, rt: *JsRuntime) v8.Error!void {
        if (self.allocation_failed) return error.OutOfMemory;
        var queue = self.handled;
        self.handled = .empty;
        defer {
            for (queue.items) |r| r.deinit();
            queue.deinit(rt.gpa);
        }
        const iso = rt.isolate();
        var scope: v8.HandleScope = undefined;
        scope.init(iso);
        defer scope.deinit();
        for (queue.items) |r| {
            if (self.handled_handler) |f| {
                const args = [_]*const v8.Value{ @ptrCast(r.promise.get(iso)), r.reason.get(iso) };
                _ = c.v8__Function__Call(f.get(iso), rt.context, @ptrCast(c.v8__Undefined(iso)), 2, &args) orelse return error.JsException;
            }
        }
    }
};
