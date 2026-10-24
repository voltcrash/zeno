// Copyright 2018-2026 the Deno authors. MIT license.
//! Ops: native functions exposed to JavaScript on `Deno.core.ops`. The
//! counterpart of `#[op2]` in `libs/ops` and the bindings in
//! `libs/core/runtime/bindings.rs`.
//!
//! An op is a plain Zig function. `op` generates its V8 callback at comptime
//! from the function's signature:
//!
//! - Parameters: an optional leading `Scope`, then `bool`, `i32`, `u32`,
//!   `f64`, `[]const u8` (the argument converted with `String()`, valid
//!   during the call) or
//!   `*const v8.Value`.
//! - Return types: `void`, `bool`, `i32`, `u32`, `f64`, `[]const u8` (copied
//!   into a JS string) or `*const v8.Value`, optionally as an error union. An
//!   error is thrown as a JS `Error` named after it.
//!
//! Async ops, fast calls and op metrics come later.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const JsRuntime = @import("runtime.zig").JsRuntime;

pub const OpDecl = struct {
    name: []const u8,
    callback: v8.FunctionCallback,
};

/// What an op gets to work with when it declares a leading `Scope` param.
pub const Scope = struct {
    runtime: *JsRuntime,
    isolate: *v8.Isolate,
    context: *const v8.Context,
    /// Valid for the duration of the call.
    arena: std.mem.Allocator,
};

/// The isolate data slot holding the `*JsRuntime`.
pub const runtime_slot = 0;

pub fn op(comptime name: []const u8, comptime func: anytype) OpDecl {
    return .{ .name = name, .callback = Callback(func).call };
}

fn Callback(comptime func: anytype) type {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    const params = info.param_types;
    const takes_scope = params.len > 0 and params[0].? == Scope;
    const js_params = params[@intFromBool(takes_scope)..];

    return struct {
        fn call(cb_info: *const v8.FunctionCallbackInfo) callconv(.c) void {
            const isolate = c.v8__FunctionCallbackInfo__GetIsolate(cb_info);
            const rt: *JsRuntime = @ptrCast(@alignCast(c.v8__Isolate__GetData(isolate, runtime_slot).?));
            var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
            defer arena_state.deinit();
            const scope: Scope = .{
                .runtime = rt,
                .isolate = isolate,
                .context = rt.context,
                .arena = arena_state.allocator(),
            };

            var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            if (takes_scope) args[0] = scope;
            inline for (js_params, 0..) |T, i| {
                const value = c.v8__FunctionCallbackInfo__Get(cb_info, @intCast(i));
                args[i + @intFromBool(takes_scope)] = fromV8(T.?, scope, value) catch |err| {
                    return throwError(scope, err);
                };
            }

            const ret = @call(.auto, func, args);
            const Ret = info.return_type.?;
            const value = if (@typeInfo(Ret) == .error_union)
                ret catch |err| return throwError(scope, err)
            else
                ret;
            const js = toV8(scope, value) catch |err| return throwError(scope, err);
            if (js) |v| {
                var rv = c.v8__FunctionCallbackInfo__GetReturnValue(cb_info);
                c.v8__ReturnValue__Value__Set(&rv, v);
            }
        }
    };
}

pub const ConvertError = error{ OutOfMemory, JsException };

fn fromV8(comptime T: type, scope: Scope, value: *const v8.Value) ConvertError!T {
    switch (T) {
        *const v8.Value => return value,
        bool => return c.v8__Value__BooleanValue(value, scope.isolate),
        f64, i32, u32 => {
            var out: c.Maybe(T) = undefined;
            switch (T) {
                f64 => c.v8__Value__NumberValue(value, scope.context, &out),
                i32 => c.v8__Value__Int32Value(value, scope.context, &out),
                u32 => c.v8__Value__Uint32Value(value, scope.context, &out),
                else => unreachable,
            }
            return if (out.has_value) out.value else error.JsException;
        },
        // Like op2's `#[string]`, other values are converted with `String()`.
        []const u8 => return v8.toUtf8(scope.arena, scope.isolate, scope.context, value),
        else => @compileError("unsupported op parameter type: " ++ @typeName(T)),
    }
}

fn toV8(scope: Scope, value: anytype) ConvertError!?*const v8.Value {
    const T = @TypeOf(value);
    return switch (T) {
        void => null,
        *const v8.Value => value,
        bool => @ptrCast(c.v8__Boolean__New(scope.isolate, value)),
        f64 => @ptrCast(c.v8__Number__New(scope.isolate, value)),
        i32 => @ptrCast(c.v8__Integer__New(scope.isolate, value)),
        u32 => @ptrCast(c.v8__Integer__NewFromUnsigned(scope.isolate, value)),
        []const u8, []u8 => @ptrCast(try v8.newString(scope.isolate, value)),
        else => @compileError("unsupported op return type: " ++ @typeName(T)),
    };
}

/// Throw a Zig error into JS. `error.JsException` means an exception is
/// already pending; other errors become a JS error named after them.
fn throwError(scope: Scope, err: anyerror) void {
    if (err == error.JsException) return;
    const message = v8.newString(scope.isolate, @errorName(err)) catch return;
    _ = c.v8__Isolate__ThrowException(scope.isolate, c.v8__Exception__Error(message));
}

/// Install `ops` on `Deno.core.ops`.
pub fn install(scope: Scope, target: *const v8.Object, ops: []const OpDecl) v8.Error!void {
    for (ops) |decl| {
        const f = try v8.newFunction(scope.context, decl.callback);
        try v8.setProperty(scope.isolate, scope.context, target, decl.name, @ptrCast(f));
    }
}

// ------------------------------------------------------------------ tests

fn testAdd(a: i32, b: i32) i32 {
    return a + b;
}

fn testConcat(scope: Scope, a: []const u8, b: []const u8) ![]const u8 {
    return std.mem.concat(scope.arena, u8, &.{ a, b });
}

fn testHalf(x: f64) f64 {
    return x / 2;
}

fn testNot(b: bool) bool {
    return !b;
}

fn testFail(fail: bool) error{Boom}!u32 {
    if (fail) return error.Boom;
    return 7;
}

fn testIdentity(v: *const v8.Value) *const v8.Value {
    return v;
}

test "ops convert arguments and return values" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        op("op_test_add", testAdd),
        op("op_test_concat", testConcat),
        op("op_test_half", testHalf),
        op("op_test_not", testNot),
        op("op_test_fail", testFail),
        op("op_test_identity", testIdentity),
    } });
    defer rt.destroy(gpa);

    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    const result = rt.executeScript(gpa, "test.js",
        \\const o = Deno.core.ops;
        \\let thrown;
        \\try { o.op_test_fail(true) } catch (e) { thrown = `${e.name}: ${e.message}` }
        \\const obj = {};
        \\[o.op_test_add(2, 40), o.op_test_concat("zig", 8), o.op_test_half(5),
        \\ o.op_test_not(0), o.op_test_fail(false), thrown,
        \\ o.op_test_identity(obj) === obj].join("|")
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception.?});
        return err;
    };
    const s = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("42|zig8|2.5|true|7|Error: Boom|true", s);
}
