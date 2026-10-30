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
//!   `*const v8.Value`, a retained buffer, `Resource` or `ResourceRef(T)`. Managed
//!   arguments are borrowed by the function and released by the binding.
//! - Return types: `void`, `bool`, `i32`, `u32`, `f64`, `[]const u8` (copied
//!   into a JS string) or `*const v8.Value`, optionally as an error union. An
//!   error is thrown as a JS `Error` named after it.
//!
//! Async declarations live in `async_ops.zig`; fast calls and metrics follow.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const JsRuntime = @import("runtime.zig").JsRuntime;

pub const OpDecl = struct {
    name: []const u8,
    callback: v8.FunctionCallback,
    arg_count: usize = 0,
    is_async: bool = false,
};

/// What an op gets to work with when it declares a leading `Scope` param.
pub const Scope = struct {
    runtime: *JsRuntime,
    isolate: *v8.Isolate,
    context: *const v8.Context,
    /// Valid for the duration of the call.
    arena: std.mem.Allocator,
    /// Available while converting async-only arguments on the runtime thread.
    promise_id: ?i32 = null,
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
            var initialized: usize = 0;
            defer inline for (js_params, 0..) |T, i| {
                if (i < initialized) releaseArg(T.?, args[i + @intFromBool(takes_scope)]);
            };
            inline for (js_params, 0..) |T, i| {
                if (comptime isAsyncArg(T.?)) @compileError("async-only argument in a synchronous op");
                const value = c.v8__FunctionCallbackInfo__Get(cb_info, @intCast(i));
                args[i + @intFromBool(takes_scope)] = fromV8(T.?, scope, value) catch |err| {
                    return throwError(scope, err);
                };
                initialized += 1;
            }

            const ret = @call(.auto, func, args);
            const Ret = info.return_type.?;
            const value = if (@typeInfo(Ret) == .error_union)
                ret catch |err| return throwError(scope, err)
            else
                ret;
            defer releaseArg(@TypeOf(value), value);
            const js = toV8(scope, value) catch |err| return throwError(scope, err);
            if (js) |v| {
                var rv = c.v8__FunctionCallbackInfo__GetReturnValue(cb_info);
                c.v8__ReturnValue__Value__Set(&rv, v);
            }
        }
    };
}

pub const ConvertError = error{ OutOfMemory, JsException };

pub fn fromV8(comptime T: type, scope: Scope, value: *const v8.Value) ConvertError!T {
    if (comptime isAsyncArg(T)) return T.fromV8(scope, value);
    if (comptime isBuffer(T)) return T.fromV8(scope, value);
    if (comptime isResource(T)) {
        const rid = try fromV8(u32, scope, value);
        const result = if (T.ResourceType == void) scope.runtime.resources.getAny(rid) else scope.runtime.resources.get(T.ResourceType, rid);
        return result catch {
            try throwCustomError(scope, "BadResource", "Bad resource ID");
            return error.JsException;
        };
    }
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

pub fn toV8(scope: Scope, value: anytype) ConvertError!?*const v8.Value {
    const T = @TypeOf(value);
    if (comptime isBuffer(T)) return try value.toV8(scope);
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

pub fn isBuffer(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_op_buffer");
}

pub fn isResource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "ResourceType");
}

/// Internal native async arguments convert and release on the runtime thread.
/// Their optional beforeResolve hook runs after joining the worker and before
/// error construction or promise settlement. Bodies only borrow these values.
pub fn isAsyncArg(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_async_arg");
}

/// Bindings own arguments and returned buffers; native bodies borrow args.
pub fn releaseArg(comptime T: type, value: T) void {
    if (comptime isBuffer(T) or isAsyncArg(T)) {
        var owner = value;
        owner.deinit();
    } else if (comptime isResource(T)) value.deinit();
}

/// Throw a Zig error into JS. `error.JsException` means an exception is
/// already pending. Known resource errors use registered classes; other
/// errors become a JS Error whose message is the Zig error name.
pub fn throwError(scope: Scope, err: anyerror) void {
    if (err == error.JsException) return;
    const value = errorValue(scope, err) catch return;
    _ = c.v8__Isolate__ThrowException(scope.isolate, value);
}

pub fn errorValue(scope: Scope, err: anyerror) ConvertError!*const v8.Value {
    if (err == error.NotSupported) return customError(scope, "NotSupported", "The operation is not supported");
    if (err == error.OperationCanceled) return customError(scope, "Interrupted", "operation canceled");
    return c.v8__Exception__Error(try v8.newString(scope.isolate, @errorName(err)));
}

/// Build a registered JS error class through core's captured, trusted
/// builder, preserving its prototype and message (e.g. BadResource).
pub fn throwCustomError(scope: Scope, class_name: []const u8, message: []const u8) ConvertError!void {
    _ = c.v8__Isolate__ThrowException(scope.isolate, try customError(scope, class_name, message));
}

pub fn customError(scope: Scope, class_name: []const u8, message: []const u8) ConvertError!*const v8.Value {
    const bootstrap = scope.runtime.captured_bootstrap orelse {
        // During bootstrap the registered constructors may not exist yet.
        const err = c.v8__Exception__Error(try v8.newString(scope.isolate, message));
        try v8.setProperty(scope.isolate, scope.context, @ptrCast(err), "name", @ptrCast(try v8.newString(scope.isolate, class_name)));
        return err;
    };
    const core = try v8.getProperty(scope.isolate, scope.context, @ptrCast(bootstrap.get(scope.isolate)), "core");
    const builder = try v8.getProperty(scope.isolate, scope.context, @ptrCast(core), "buildCustomError");
    const args = [_]*const v8.Value{
        @ptrCast(try v8.newString(scope.isolate, class_name)),
        @ptrCast(try v8.newString(scope.isolate, message)),
    };
    return c.v8__Function__Call(@ptrCast(builder), scope.context, @ptrCast(c.v8__Undefined(scope.isolate)), 2, &args) orelse error.JsException;
}

/// Install `ops` on `Deno.core.ops`.
pub fn install(scope: Scope, target: *const v8.Object, ops: []const OpDecl) v8.Error!void {
    for (ops) |decl| {
        const f = c.v8__Function__New(scope.context, decl.callback, null, @intCast(decl.arg_count), .throw, .has_side_effect) orelse return error.JsException;
        var value: *const v8.Value = @ptrCast(f);
        if (decl.is_async) {
            const deno = try v8.getProperty(scope.isolate, scope.context, c.v8__Context__Global(scope.context), "Deno");
            const core = try v8.getProperty(scope.isolate, scope.context, @ptrCast(deno), "core");
            const builder = try v8.getProperty(scope.isolate, scope.context, @ptrCast(core), "setUpAsyncStub");
            const args = [_]*const v8.Value{ @ptrCast(try v8.newString(scope.isolate, decl.name)), value };
            value = c.v8__Function__Call(@ptrCast(builder), scope.context, @ptrCast(c.v8__Undefined(scope.isolate)), 2, &args) orelse return error.JsException;
        }
        try v8.setProperty(scope.isolate, scope.context, target, decl.name, value);
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
