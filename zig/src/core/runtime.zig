// Copyright 2018-2026 the Deno authors. MIT license.
//! The JavaScript runtime: an isolate with one context, bootstrapped with
//! `libs/core`'s JavaScript. The start of the port of `JsRuntime` from
//! `libs/core/runtime/jsruntime.rs`; modules, async ops and the event loop
//! come later.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const ops = @import("ops.zig");
const ops_builtin = @import("ops_builtin.zig");
const modules = @import("modules.zig");

/// Run right after the context is created, to set up what ops need
/// (`CONTEXT_SETUP_SOURCES`).
const context_setup_sources = [_][]const u8{ "00_primordials.js", "00_infra.js" };
/// Run once ops are bound (`BUILTIN_SOURCES`).
const builtin_sources = [_][]const u8{ "02_timers.js", "01_core.js" };
/// Evaluated after the builtin sources (`BUILTIN_ES_MODULES`).
const builtin_es_modules = [_][]const u8{"mod.js"};

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
    modules: modules.ModuleMap,

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
            .modules = .init(gpa),
        };
        const iso = self.owned.isolate;
        v8.c.v8__Isolate__SetData(iso, ops.runtime_slot, self);
        v8.c.v8__Isolate__SetHostInitializeImportMetaObjectCallback(iso, modules.ModuleMap.initializeImportMeta);
        self.scope.init(iso);
        self.context = v8.newContext(iso);
        v8.c.v8__Context__Enter(self.context);
        self.ext_import_meta_proto = .init(iso, v8.c.v8__Object__New(iso));
        try self.bootstrapCore(options.ops);
        try self.installTemporaryConsole();
        return self;
    }

    pub fn destroy(self: *JsRuntime, gpa: std.mem.Allocator) void {
        self.modules.deinit();
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

        // `ext:core/ops` exports every op.
        var exports: std.ArrayList(modules.Source.Export) = .empty;
        const arena = self.modules.arena.allocator();
        for ([_][]const ops.OpDecl{ &ops_builtin.all, extra_ops }) |decls| {
            for (decls) |decl| {
                const f = try v8.getProperty(iso, ctx, core_ops, decl.name);
                try exports.append(arena, .{ .name = decl.name, .value = .init(iso, f) });
            }
        }
        try self.modules.addBuiltin("ext:core/ops", .{ .synthetic = exports.items });
        inline for (builtin_es_modules) |name| {
            const specifier = "ext:core/" ++ name;
            try self.modules.addBuiltin(specifier, .{ .code = @embedFile(specifier) });
            var exception: ?[]u8 = null;
            self.executeModule(specifier, &exception) catch |err| {
                if (exception) |e| {
                    std.log.err("failed to evaluate {s}: {s}", .{ specifier, e });
                    self.gpa.free(e);
                }
                return if (err == error.OutOfMemory) error.OutOfMemory else error.CoreBootstrapFailed;
            };
        }
    }

    /// Load and evaluate a (non-main) module.
    fn executeModule(self: *JsRuntime, specifier: []const u8, exception: *?[]u8) ExecuteError!void {
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate());
        defer try_catch.deinit();
        var thrown: ?*const v8.Value = null;
        const module = self.modules.load(self, specifier, null, false) catch |err| return self.moduleError(self.gpa, err, &try_catch, null, exception);
        self.modules.evaluate(self, module, &thrown) catch |err| return self.moduleError(self.gpa, err, &try_catch, thrown, exception);
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

    /// The runtime that owns `iso`, for V8 callbacks.
    pub fn fromIsolate(iso: *v8.Isolate) *JsRuntime {
        return @ptrCast(@alignCast(v8.c.v8__Isolate__GetData(iso, ops.runtime_slot).?));
    }

    /// Load `specifier` as the main module and evaluate it. `code` is its
    /// source if it's in memory; otherwise it is read from its URL. On
    /// failure, `exception` describes the error (allocated with `gpa`).
    pub fn executeMainModule(self: *JsRuntime, gpa: std.mem.Allocator, specifier: []const u8, code: ?[]const u8, exception: *?[]u8) ExecuteError!void {
        const iso = self.isolate();
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(iso);
        defer try_catch.deinit();

        var thrown: ?*const v8.Value = null;
        const module = self.modules.load(self, specifier, code, true) catch |err| return self.moduleError(gpa, err, &try_catch, null, exception);
        self.modules.evaluate(self, module, &thrown) catch |err| return self.moduleError(gpa, err, &try_catch, thrown, exception);
    }

    fn moduleError(self: *JsRuntime, gpa: std.mem.Allocator, err: modules.LoadError, try_catch: *const v8.TryCatch, thrown: ?*const v8.Value, exception: *?[]u8) ExecuteError {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ModuleNotFound, error.ResolutionFailed => {
                exception.* = try gpa.dupe(u8, self.modules.last_error orelse @errorName(err));
                return error.ModuleLoadFailed;
            },
            error.JsException => {
                const value = thrown orelse
                    (if (try_catch.hasCaught()) try_catch.stackTrace(self.context) orelse try_catch.exception() else null);
                exception.* = if (value) |v|
                    try self.describeException(gpa, v)
                else
                    try gpa.dupe(u8, "Top-level await promise never resolved");
                return error.JsException;
            },
        }
    }

    /// An exception's stack trace if it has one, else `String(exception)`.
    fn describeException(self: *JsRuntime, gpa: std.mem.Allocator, exception: *const v8.Value) v8.Error![]u8 {
        const iso = self.isolate();
        if (v8.c.v8__Value__IsObject(exception)) {
            if (v8.getProperty(iso, self.context, @ptrCast(exception), "stack")) |stack| {
                if (v8.c.v8__Value__IsString(stack)) return v8.toUtf8(gpa, iso, self.context, stack);
            } else |_| {}
        }
        return v8.toUtf8(gpa, iso, self.context, exception);
    }

    pub const ExecuteError = v8.Error || error{ModuleLoadFailed};

    /// Run a classic script. On an uncaught exception, returns
    /// `error.JsException` and sets `exception` to its description (the
    /// stack trace when there is one), allocated with `gpa`.
    pub fn executeScript(
        self: *JsRuntime,
        gpa: std.mem.Allocator,
        name: []const u8,
        source: []const u8,
        exception: *?[]u8,
    ) v8.Error!*const v8.Value {
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

test "ES modules" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.js", .data = "export const answer = 42;\nexport const meta = import.meta.url;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.js", .data =
        \\import { answer, meta } from "./dep.js";
        \\import { op_print } from "ext:core/ops";
        \\import { core, primordials } from "ext:core/mod.js";
        \\globalThis.result = [answer, meta.endsWith("/dep.js"), import.meta.main,
        \\  op_print === Deno.core.ops.op_print, typeof core.print,
        \\  typeof primordials.ArrayPrototypeMap, await Promise.resolve("tla")].join();
        \\
    });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const main_url = try @import("url.zig").fromFilePath(arena, try std.fmt.allocPrint(arena, "{s}/main.js", .{dir}));

    const rt = try JsRuntime.create(gpa, io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, main_url, null, &exception) catch |err| {
        std.debug.print("{s}\n", .{exception.?});
        return err;
    };
    const v = try rt.executeScript(gpa, "test.js", "globalThis.result", &exception);
    const s = try v8.toUtf8(gpa, rt.isolate(), rt.context, v);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("42,true,true,true,function,function,tla", s);

    // Errors: a throwing module, a missing module, a bare specifier.
    const cases = [_][2][]const u8{
        .{ "throw new RangeError('nope')", "RangeError: nope\n    at file:///x/a.js:1:7" },
        .{ "await Promise.reject(new Error('async nope'))", "Error: async nope\n    at file:///x/b.js:1:22" },
        .{ "import './missing.js'", "Module not found \"file:///x/missing.js\"." },
        .{ "import 'lodash'", "Relative import path \"lodash\" not prefixed with / or ./ or ../ from \"file:///x/d.js\"" },
    };
    for (cases, [_][]const u8{ "file:///x/a.js", "file:///x/b.js", "file:///x/c.js", "file:///x/d.js" }) |case, spec| {
        try std.testing.expect(std.meta.isError(rt.executeMainModule(gpa, spec, case[0], &exception)));
        try std.testing.expect(std.mem.startsWith(u8, exception.?, case[1]));
        gpa.free(exception.?);
        exception = null;
    }
}

test "core value predicates inspect V8 types without coercion" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    const result = try rt.executeScript(gpa, "types.js",
        \\const core = Deno.core;
        \\const pairs = [
        \\ ["AnyArrayBuffer", new ArrayBuffer(0)], ["AnyArrayBuffer", new SharedArrayBuffer(0)],
        \\ ["ArgumentsObject", (function() { return arguments; })()],
        \\ ["ArrayBuffer", new ArrayBuffer(0)], ["ArrayBufferView", new DataView(new ArrayBuffer(0))],
        \\ ["AsyncFunction", async function() {}], ["BigIntObject", Object(1n)],
        \\ ["BooleanObject", new Boolean(false)], ["BoxedPrimitive", Object(Symbol())],
        \\ ["BoxedPrimitive", new String("")], ["BoxedPrimitive", new Number(0)],
        \\ ["BoxedPrimitive", Object(1n)], ["BoxedPrimitive", new Boolean(false)],
        \\ ["DataView", new DataView(new ArrayBuffer(0))], ["Date", new Date()],
        \\ ["GeneratorFunction", function*() {}], ["GeneratorObject", (function*() {})()],
        \\ ["Map", new Map()], ["MapIterator", new Map().entries()],
        \\ ["NativeError", new TypeError()], ["NumberObject", new Number(0)],
        \\ ["Promise", Promise.resolve()], ["Proxy", new Proxy({}, {})],
        \\ ["RegExp", /a/], ["Set", new Set()], ["SetIterator", new Set().values()],
        \\ ["SharedArrayBuffer", new SharedArrayBuffer(0)], ["StringObject", new String("")],
        \\ ["SymbolObject", Object(Symbol())], ["TypedArray", new Uint8Array(0)],
        \\ ["WeakMap", new WeakMap()], ["WeakSet", new WeakSet()],
        \\];
        \\for (const [name, value] of pairs) {
        \\  if (!core["is" + name](value)) throw new Error(name);
        \\  for (const wrong of [undefined, null, false, 0, "", 1n, Symbol(), {}]) {
        \\    if (core["is" + name](wrong)) throw new Error(name + " false positive");
        \\  }
        \\}
        \\const fake = { [Symbol.toStringTag]: "Map", toString() { throw 1; } };
        \\const {proxy, revoke} = Proxy.revocable({}, {}); revoke();
        \\if (core.isMap(fake) || !core.isProxy(proxy) || core.isTypedArray(new DataView(new ArrayBuffer(0)))) throw 2;
        \\const byteLength = core.ops.op_str_byte_length;
        \\if (byteLength("aé😀\ud800") !== 10 || byteLength(fake) !== 0 || byteLength(new String("a")) !== 0) throw 3;
        \\true
    , &exception);
    try std.testing.expect(v8.c.v8__Value__BooleanValue(result, rt.isolate()));

    try rt.executeMainModule(gpa, "file:///types-module.js",
        \\import * as namespace from 'ext:core/ops';
        \\if (!Deno.core.isModuleNamespaceObject(namespace)) throw new Error('namespace');
        \\if (!namespace.op_is_map(new Map())) throw new Error('synthetic export');
    , &exception);
}
