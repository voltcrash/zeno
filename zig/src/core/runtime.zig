// Copyright 2018-2026 the Deno authors. MIT license.
//! The JavaScript runtime: an isolate with one context, bootstrapped with
//! `libs/core`'s JavaScript. The start of the port of `JsRuntime` from
//! `libs/core/runtime/jsruntime.rs`; modules, async ops and the event loop
//! come later.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const ops = @import("ops.zig");
const ops_builtin = @import("ops_builtin.zig");

/// Run right after the context is created, to set up what ops need
/// (`CONTEXT_SETUP_SOURCES`).
const context_setup_sources = [_][]const u8{ "00_primordials.js", "00_infra.js" };
/// Run once ops are bound (`BUILTIN_SOURCES`).
const builtin_sources = [_][]const u8{ "02_timers.js", "01_core.js" };

pub const JsRuntime = struct {
    owned: v8.OwnedIsolate,
    /// Keeps the context handle alive for the runtime's lifetime.
    scope: v8.HandleScope,
    context: *const v8.Context,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The prototype of `import.meta` objects of `ext:` modules.
    ext_import_meta_proto: v8.Global(v8.Object),
    /// The bootstrap object captured by `01_core.js`.
    captured_bootstrap: ?v8.Global(v8.Value) = null,

    pub const CreateError = error{ OutOfMemory, JsException, CoreBootstrapFailed };

    pub const Options = struct {
        /// Ops to bind in addition to the built-in ones.
        ops: []const ops.OpDecl = &.{},
    };

    /// Create a runtime. `v8.Platform.init` must have been called. The
    /// runtime must stay at a stable address, so it's heap-allocated.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: Options) CreateError!*JsRuntime {
        const self = try gpa.create(JsRuntime);
        errdefer gpa.destroy(self);
        self.* = .{
            .owned = .init(),
            .scope = undefined,
            .context = undefined,
            .gpa = gpa,
            .io = io,
            .ext_import_meta_proto = undefined,
        };
        const iso = self.owned.isolate;
        v8.c.v8__Isolate__SetData(iso, ops.runtime_slot, self);
        self.scope.init(iso);
        self.context = v8.newContext(iso);
        v8.c.v8__Context__Enter(self.context);
        self.ext_import_meta_proto = .init(iso, v8.c.v8__Object__New(iso));
        try self.bootstrapCore(options.ops);
        try self.installTemporaryConsole();
        return self;
    }

    pub fn destroy(self: *JsRuntime, gpa: std.mem.Allocator) void {
        if (self.captured_bootstrap) |g| g.deinit();
        self.ext_import_meta_proto.deinit();
        v8.c.v8__Context__Exit(self.context);
        self.scope.deinit();
        self.owned.deinit();
        gpa.destroy(self);
    }

    /// Set up `Deno.core` and run `libs/core`'s JavaScript, binding the ops
    /// on `Deno.core.ops` in between. The equivalent of the context setup in
    /// `JsRuntime::new` and `bindings.rs`.
    fn bootstrapCore(self: *JsRuntime, extra_ops: []const ops.OpDecl) CreateError!void {
        const iso = self.isolate();
        const ctx = self.context;
        const scope: ops.Scope = .{ .runtime = self, .isolate = iso, .context = ctx, .arena = self.gpa };

        // `Deno.core = { ops, callConsole, console }`.
        const deno = v8.c.v8__Object__New(iso);
        const core = v8.c.v8__Object__New(iso);
        const core_ops = v8.c.v8__Object__New(iso);
        try v8.setProperty(iso, ctx, core, "ops", @ptrCast(core_ops));
        try v8.setProperty(iso, ctx, core, "callConsole", @ptrCast(try v8.newFunction(ctx, callConsole)));
        const extras = v8.c.v8__Context__GetExtrasBindingObject(ctx);
        try v8.setProperty(iso, ctx, core, "console", try v8.getProperty(iso, ctx, extras, "console"));
        try v8.setProperty(iso, ctx, deno, "core", @ptrCast(core));
        try v8.setProperty(iso, ctx, v8.c.v8__Context__Global(ctx), "Deno", @ptrCast(deno));

        inline for (context_setup_sources) |name| try self.runCoreSource(name);
        try ops.install(scope, core_ops, &ops_builtin.all);
        try ops.install(scope, core_ops, extra_ops);
        inline for (builtin_sources) |name| try self.runCoreSource(name);
    }

    fn runCoreSource(self: *JsRuntime, comptime name: []const u8) CreateError!void {
        const specifier = "ext:core/" ++ name;
        var exception: ?[]u8 = null;
        _ = self.executeScript(self.gpa, specifier, @embedFile(specifier), &exception) catch |err| {
            if (exception) |e| {
                std.log.err("failed to run {s}: {s}", .{ specifier, e });
                self.gpa.free(e);
                return error.CoreBootstrapFailed;
            }
            return err;
        };
    }

    /// `Deno.core.callConsole(inspectorConsoleMethod, denoConsoleMethod,
    /// ...args)`: forwards a console call to both. There is no inspector yet,
    /// so only the Deno method is called.
    fn callConsole(info: *const v8.FunctionCallbackInfo) callconv(.c) void {
        const c = v8.c;
        const iso = c.v8__FunctionCallbackInfo__GetIsolate(info);
        const ctx = c.v8__Isolate__GetCurrentContext(iso);
        const n: usize = @intCast(c.v8__FunctionCallbackInfo__Length(info));
        if (n < 2) return;
        const deno_method = c.v8__FunctionCallbackInfo__Get(info, 1);
        if (!c.v8__Value__IsFunction(deno_method)) return;
        var args: [32]*const v8.Value = undefined;
        const argc = @min(n - 2, args.len);
        for (0..argc) |i| args[i] = c.v8__FunctionCallbackInfo__Get(info, @intCast(i + 2));
        _ = c.v8__Function__Call(@ptrCast(deno_method), ctx, @ptrCast(c.v8__Undefined(iso)), @intCast(argc), &args);
    }

    pub fn isolate(self: *JsRuntime) *v8.Isolate {
        return self.owned.isolate;
    }

    pub const ExecuteError = v8.Error;

    /// Run a classic script. On an uncaught exception, returns
    /// `error.JsException` and sets `exception` to its description (the
    /// stack trace when there is one), allocated with `gpa`.
    pub fn executeScript(
        self: *JsRuntime,
        gpa: std.mem.Allocator,
        name: []const u8,
        source: []const u8,
        exception: *?[]u8,
    ) ExecuteError!*const v8.Value {
        const iso = self.isolate();
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(iso);
        defer try_catch.deinit();

        return v8.runScript(iso, self.context, name, source) catch |err| {
            if (err == error.JsException and try_catch.hasCaught()) {
                const value = try_catch.stackTrace(self.context) orelse try_catch.exception().?;
                exception.* = try v8.toUtf8(gpa, iso, self.context, value);
            }
            return err;
        };
    }

    /// Install a minimal native `console` until the runtime's JS
    /// (`ext/console`) is ported. Arguments are converted with `String()`
    /// and joined with spaces.
    fn installTemporaryConsole(self: *JsRuntime) !void {
        const iso = self.isolate();
        const console = v8.c.v8__Object__New(iso);
        inline for (.{ "log", "info", "debug" }) |name| {
            try v8.setProperty(iso, self.context, console, name, @ptrCast(try v8.newFunction(self.context, consoleStdout)));
        }
        inline for (.{ "error", "warn" }) |name| {
            try v8.setProperty(iso, self.context, console, name, @ptrCast(try v8.newFunction(self.context, consoleStderr)));
        }
        try v8.setProperty(iso, self.context, v8.c.v8__Context__Global(self.context), "console", @ptrCast(console));
        current = self;
    }

    /// The runtime the console callbacks write through. One runtime per
    /// process for now.
    var current: ?*JsRuntime = null;

    fn consoleStdout(info: *const v8.FunctionCallbackInfo) callconv(.c) void {
        consoleWrite(info, std.Io.File.stdout());
    }

    fn consoleStderr(info: *const v8.FunctionCallbackInfo) callconv(.c) void {
        consoleWrite(info, std.Io.File.stderr());
    }

    fn consoleWrite(info: *const v8.FunctionCallbackInfo, file: std.Io.File) void {
        const rt = current orelse return;
        const iso = v8.c.v8__FunctionCallbackInfo__GetIsolate(info);
        const gpa = std.heap.smp_allocator;
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        const n = v8.c.v8__FunctionCallbackInfo__Length(info);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const arg = v8.c.v8__FunctionCallbackInfo__Get(info, i);
            // On a throwing conversion the exception propagates to JS.
            const s = v8.toUtf8(gpa, iso, rt.context, arg) catch return;
            defer gpa.free(s);
            if (i > 0) line.writer.writeByte(' ') catch return;
            line.writer.writeAll(s) catch return;
        }
        line.writer.writeByte('\n') catch return;
        file.writeStreamingAll(rt.io, line.written()) catch {};
    }
};

test "run a script" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);

    var exception: ?[]u8 = null;
    const result = try rt.executeScript(gpa, "test.js", "[1, 2, 3].map((x) => x * 2).join()", &exception);
    const s = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("2,4,6", s);

    try std.testing.expectError(error.JsException, rt.executeScript(gpa, "test.js", "throw new TypeError('boom')", &exception));
    try std.testing.expect(std.mem.startsWith(u8, exception.?, "TypeError: boom\n    at test.js:1:7"));
    gpa.free(exception.?);

    try std.testing.expectError(error.JsException, rt.executeScript(gpa, "test.js", "syntax error(", &exception));
    try std.testing.expect(std.mem.startsWith(u8, exception.?, "SyntaxError"));
    gpa.free(exception.?);

    // Temporal is disabled until the port provides temporal_rs.
    try std.testing.expectEqualStrings("undefined", try typeOf(rt, "Temporal"));
}

fn typeOf(rt: *JsRuntime, expr: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const code = try std.fmt.bufPrint(&buf, "typeof {s}", .{expr});
    var exception: ?[]u8 = null;
    const v = try rt.executeScript(std.testing.allocator, "test.js", code, &exception);
    const s = try v8.toUtf8(std.testing.allocator, rt.isolate(), rt.context, v);
    defer std.testing.allocator.free(s);
    return if (std.mem.eql(u8, s, "undefined")) "undefined" else "defined";
}

test "libs/core's JavaScript is loaded" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    const v = rt.executeScript(gpa, "test.js",
        \\[typeof Deno.core.print, typeof Deno.core.ops.op_print,
        \\ typeof globalThis.__bootstrap.primordials.ArrayPrototypeMap,
        \\ typeof queueMicrotask, Object.isFrozen(globalThis.__bootstrap.core)].join()
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception.?});
        return err;
    };
    const s = try v8.toUtf8(gpa, rt.isolate(), rt.context, v);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("function,function,function,function,true", s);
    try std.testing.expect(rt.captured_bootstrap != null);
}
