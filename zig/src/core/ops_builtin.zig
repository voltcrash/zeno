// Copyright 2018-2026 the Deno authors. MIT license.
//! Built-in ops of every runtime, ported from `libs/core/ops_builtin.rs` and
//! `ops_builtin_v8.rs`. Only the ops the port needs so far; the rest follow
//! as their users are ported.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const ops = @import("ops.zig");
const op = ops.op;
const Scope = ops.Scope;

pub const all = @import("ops_builtin_types.zig").all ++ [_]ops.OpDecl{
    op("op_str_byte_length", opStrByteLength),
    op("op_print", opPrint),
    op("op_resources", opResources),
    op("op_close", opClose),
    op("op_try_close", opTryClose),
    op("op_cancel_read", opCancelRead),
    op("op_timer_now", opTimerNow),
    op("op_timer_schedule", opTimerSchedule),
    op("op_timer_track", opTimerTrack),
    op("op_timer_untrack", opTimerUntrack),
    op("op_run_microtasks", opRunMicrotasks),
    op("op_immediate_check", opImmediateCheck),
    op("op_dispatch_exception", opDispatchException),
    op("op_drain_pending_rejections", opDrainPendingRejections),
    op("op_set_handled_promise_rejection_handler", opSetHandledPromiseRejectionHandler),
    op("op_get_extras_binding_object", opGetExtrasBindingObject),
    op("op_get_ext_import_meta_proto", opGetExtImportMetaProto),
    op("op_set_captured_bootstrap", opSetCapturedBootstrap),
};

fn opPrint(scope: Scope, msg: []const u8, is_err: bool) !void {
    const file = if (is_err) std.Io.File.stderr() else std.Io.File.stdout();
    try file.writeStreamingAll(scope.runtime.io, msg);
}

fn opGetExtrasBindingObject(scope: Scope) *const v8.Value {
    return @ptrCast(c.v8__Context__GetExtrasBindingObject(scope.context));
}

/// The prototype of `import.meta` for `ext:` modules.
fn opGetExtImportMetaProto(scope: Scope) *const v8.Value {
    return @ptrCast(scope.runtime.ext_import_meta_proto.get(scope.isolate));
}

/// Called once by `01_core.js` after `__bootstrap.core` is populated.
fn opSetCapturedBootstrap(scope: Scope, value: *const v8.Value) void {
    const rt = scope.runtime;
    if (rt.captured_bootstrap) |old| old.deinit();
    rt.captured_bootstrap = .init(scope.isolate, value);
}

/// Like Rust, non-strings return zero without coercion.
fn opStrByteLength(scope: Scope, value: *const v8.Value) u32 {
    if (!c.v8__Value__IsString(value)) return 0;
    return @intCast(c.v8__String__Utf8Length(@ptrCast(value), scope.isolate));
}

fn opTimerNow(scope: Scope) f64 {
    return scope.runtime.timers.now(scope.runtime.io);
}

fn opTimerSchedule(scope: Scope, delay_ms: f64) void {
    scope.runtime.timers.schedule(scope.runtime.io, delay_ms);
}

fn opTimerTrack(scope: Scope, id: i32, repeat: bool, system: bool) !void {
    try scope.runtime.timers.active.put(scope.runtime.gpa, id, .{ .repeat = repeat, .system = system });
}

fn opTimerUntrack(scope: Scope, id: i32) void {
    _ = scope.runtime.timers.active.remove(id);
}

fn opRunMicrotasks(scope: Scope) void {
    c.v8__Isolate__PerformMicrotaskCheckpoint(scope.isolate);
}

/// Fatal callback errors are recorded rather than thrown back into JS's
/// reporting path. The event loop reports them once dispatch returns.
fn opDispatchException(scope: Scope, exception: *const v8.Value, is_promise: bool) void {
    if (scope.runtime.dispatched_exception) |old| old.deinit();
    scope.runtime.dispatched_exception = .init(scope.isolate, exception);
    scope.runtime.exception_is_promise = is_promise;
}

fn opDrainPendingRejections(scope: Scope) !*const v8.Value {
    return scope.runtime.exceptions.drainPending(scope.runtime);
}

fn opSetHandledPromiseRejectionHandler(scope: Scope, value: *const v8.Value) !void {
    if (!c.v8__Value__IsNullOrUndefined(value) and !c.v8__Value__IsFunction(value)) {
        const message = try v8.newString(scope.isolate, "expected Function");
        _ = c.v8__Isolate__ThrowException(scope.isolate, c.v8__Exception__TypeError(message));
        return;
    }
    const state = &scope.runtime.exceptions;
    if (state.handled_handler) |old| old.deinit();
    state.handled_handler = if (c.v8__Value__IsFunction(value)) .init(scope.isolate, @ptrCast(value)) else null;
}

fn opImmediateCheck(scope: Scope, make_ref: bool) void {
    scope.runtime.immediate_refed = make_ref;
}

fn opResources(scope: Scope) !*const v8.Value {
    const Name = struct {
        rid: u32,
        name: []const u8,
        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.rid < b.rid;
        }
    };
    var names: std.ArrayList(Name) = .empty;
    var it = scope.runtime.resources.entries.iterator();
    while (it.next()) |entry| try names.append(scope.arena, .{ .rid = entry.key_ptr.*, .name = entry.value_ptr.name() });
    // Rust currently uses a BTreeMap. Preserve its observable RID order in
    // the raw op as well as core.resources()'s integer-keyed object.
    std.mem.sort(Name, names.items, {}, Name.lessThan);
    var pairs: std.ArrayList(*const v8.Value) = .empty;
    for (names.items) |entry| {
        const pair = [_]*const v8.Value{
            @ptrCast(c.v8__Integer__NewFromUnsigned(scope.isolate, entry.rid)),
            @ptrCast(try v8.newString(scope.isolate, entry.name)),
        };
        try pairs.append(scope.arena, @ptrCast(c.v8__Array__New_with_elements(scope.isolate, &pair, 2)));
    }
    return @ptrCast(c.v8__Array__New_with_elements(scope.isolate, pairs.items.ptr, pairs.items.len));
}

fn opClose(scope: Scope, rid: u32) !void {
    const resource = scope.runtime.resources.takeAny(rid) catch {
        return ops.throwCustomError(scope, "BadResource", "Bad resource ID");
    };
    defer resource.deinit();
    // Removal precedes the hook: cancellation callbacks can re-enter ops.
    resource.close();
}

fn opTryClose(scope: Scope, rid: u32) void {
    const resource = scope.runtime.resources.takeAny(rid) catch return;
    defer resource.deinit();
    resource.close();
}

fn opCancelRead(scope: Scope, rid: u32) void {
    const resource = scope.runtime.resources.getAny(rid) catch return;
    defer resource.deinit();
    resource.cancelReadOps();
}
