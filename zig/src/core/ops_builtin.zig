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
    op("op_timer_now", opTimerNow),
    op("op_timer_schedule", opTimerSchedule),
    op("op_timer_track", opTimerTrack),
    op("op_timer_untrack", opTimerUntrack),
    op("op_run_microtasks", opRunMicrotasks),
    op("op_dispatch_exception", opDispatchException),
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
fn opDispatchException(scope: Scope, exception: *const v8.Value, _: bool) void {
    if (scope.runtime.dispatched_exception) |old| old.deinit();
    scope.runtime.dispatched_exception = .init(scope.isolate, exception);
}
