// Copyright 2018-2026 the Deno authors. MIT license.
//! The JavaScript runtime: an isolate with one context, bootstrapped with
//! `libs/core`'s JavaScript. The start of the port of `JsRuntime` from
//! `libs/core/runtime/jsruntime.rs`; async I/O and the remaining event loop
//! phases come later.

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
    resources: @import("resources.zig").ResourceTable,
    async_driver: @import("async_ops.zig").Driver,
    event_loop_tick: ?v8.Global(v8.c.Function) = null,
    timers: @import("timers.zig").Timers,
    process_timers: ?v8.Global(v8.c.Function) = null,
    dispatched_exception: ?v8.Global(v8.Value) = null,
    exception_is_promise: bool = false,
    exceptions: @import("exceptions.zig").ExceptionState = .{},
    tick_buffer: ?v8.Global(v8.c.ArrayBuffer) = null,
    tick_info: ?*[2]u8 = null,
    drain_ticks: ?v8.Global(v8.c.Function) = null,
    immediate_buffer: ?v8.Global(v8.c.ArrayBuffer) = null,
    immediate_info: ?*[3]i32 = null,
    immediate_refed: bool = false,
    run_immediates: ?v8.Global(v8.c.Function) = null,

    pub const CreateError = error{ OutOfMemory, JsException, CoreBootstrapFailed };

    pub const Options = struct {
        /// Ops to bind in addition to the built-in ones.
        ops: []const ops.OpDecl = &.{},
    };

    /// Create a runtime. `v8.Platform.init` must have been called. The
    /// runtime must stay at a stable address, so it's heap-allocated.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: Options) CreateError!*JsRuntime {
        const self = try gpa.create(JsRuntime);
        self.* = .{
            .owned = .init(),
            .scope = undefined,
            .context = undefined,
            .gpa = gpa,
            .io = io,
            .ext_import_meta_proto = undefined,
            .modules = .init(gpa),
            .resources = .init(gpa),
            .async_driver = .init(gpa, io),
            .timers = .init(io),
        };
        const iso = self.owned.isolate;
        // Commit JS's returned timer expiry before promise continuations can
        // schedule new timers, matching Deno's explicit microtask policy.
        v8.c.v8__Isolate__SetMicrotasksPolicy(iso, .explicit);
        v8.c.v8__Isolate__SetData(iso, ops.runtime_slot, self);
        v8.c.v8__Isolate__SetHostInitializeImportMetaObjectCallback(iso, modules.ModuleMap.initializeImportMeta);
        self.scope.init(iso);
        self.context = v8.newContext(iso);
        v8.c.v8__Context__Enter(self.context);
        self.ext_import_meta_proto = .init(iso, v8.c.v8__Object__New(iso));
        errdefer self.destroy(gpa);
        try self.bootstrapCore(options.ops);
        try self.installTemporaryConsole();
        // JS owns these counters until native shared buffer access is needed.
        var exception: ?[]u8 = null;
        defer if (exception) |e| gpa.free(e);
        const callback = try self.executeScript(gpa, "ext:core/timer_setup.js",
            \\Deno.core.__setTimerInfo(new Int32Array(1));
            \\Deno.core.__processTimers
        , &exception);
        self.process_timers = .init(iso, @ptrCast(callback));
        return self;
    }

    pub fn destroy(self: *JsRuntime, gpa: std.mem.Allocator) void {
        self.async_driver.deinit();
        if (self.event_loop_tick) |f| f.deinit();
        self.resources.deinit();
        self.exceptions.deinit(gpa);
        if (self.tick_buffer) |b| b.deinit();
        if (self.immediate_buffer) |b| b.deinit();
        if (self.run_immediates) |f| f.deinit();
        if (self.drain_ticks) |f| f.deinit();
        if (self.process_timers) |f| f.deinit();
        if (self.dispatched_exception) |e| e.deinit();
        self.timers.active.deinit(gpa);
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

        const buffer = v8.c.v8__ArrayBuffer__New__with_byte_length(iso, 2);
        self.tick_buffer = .init(iso, buffer);
        self.tick_info = @ptrCast(@alignCast(v8.c.v8__ArrayBuffer__Data(buffer).?));
        self.tick_info.?.* = .{ 0, 0 };
        const view = v8.c.v8__Uint8Array__New(buffer, 0, 2) orelse return error.OutOfMemory;
        const setter = try v8.getProperty(iso, ctx, core, "__setTickInfo");
        _ = v8.c.v8__Function__Call(@ptrCast(setter), ctx, @ptrCast(v8.c.v8__Undefined(iso)), 1, &.{@ptrCast(view)}) orelse return error.JsException;
        self.event_loop_tick = .init(iso, @ptrCast(try v8.getProperty(iso, ctx, core, "__eventLoopTick")));
        self.drain_ticks = .init(iso, @ptrCast(try v8.getProperty(iso, ctx, core, "__drainNextTickAndMacrotasks")));
        v8.c.v8__Isolate__SetPromiseRejectCallback(iso, @import("exceptions.zig").ExceptionState.promiseRejectCallback);

        const immediate_buffer = v8.c.v8__ArrayBuffer__New__with_byte_length(iso, 3 * @sizeOf(i32));
        self.immediate_buffer = .init(iso, immediate_buffer);
        self.immediate_info = @ptrCast(@alignCast(v8.c.v8__ArrayBuffer__Data(immediate_buffer).?));
        self.immediate_info.?.* = .{ 0, 0, 0 };
        const immediate_view = v8.c.v8__Int32Array__New(immediate_buffer, 0, 3) orelse return error.OutOfMemory;
        const immediate_setter = try v8.getProperty(iso, ctx, core, "__setImmediateInfo");
        _ = v8.c.v8__Function__Call(@ptrCast(immediate_setter), ctx, @ptrCast(v8.c.v8__Undefined(iso)), 1, &.{@ptrCast(immediate_view)}) orelse return error.JsException;
        self.run_immediates = .init(iso, @ptrCast(try v8.getProperty(iso, ctx, core, "runImmediateCallbacks")));

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

    /// Drive timers, native op completions, nextTicks, immediates and V8
    /// tasks. Resource-backed I/O methods follow as extensions are ported.
    pub fn runEventLoop(self: *JsRuntime, main_promise: ?*const v8.c.Promise, thrown: *?*const v8.Value) v8.Error!void {
        const c = v8.c;
        const iso = self.isolate();
        const platform = v8.Platform.current();
        const event_loop_tick = if (self.event_loop_tick) |f| f.get(iso) else null;
        const drain = if (self.drain_ticks) |f| f.get(iso) else null;
        const immediates = if (self.run_immediates) |f| f.get(iso) else null;
        var carried_work = false;
        while (true) {
            var did_work = carried_work;
            carried_work = false;
            while (platform.pumpMessageLoop(iso, false)) did_work = true;
            did_work = did_work or (if (self.tick_info) |info| info[0] != 0 else false);
            try self.drainTicks(drain);
            try self.checkEventLoopException(main_promise, thrown);

            // Poll expired timers without first sleeping: check-phase work
            // must not sit behind a future timer deadline.
            if (self.timers.deadline_ms) |deadline| {
                if (deadline <= self.timers.now(self.io)) {
                    try self.dispatchTimers();
                    did_work = true;
                }
            }
            if (event_loop_tick) |f| did_work = (try self.async_driver.dispatchReady(self, f)) or did_work;
            try self.drainTicks(drain);
            try self.checkEventLoopException(main_promise, thrown);

            // Like Rust's check phase, unrefed immediates participate only
            // when actual work drove this iteration. A future refed timer
            // alone is not a reason to dispatch an unrefed immediate.
            if (self.immediate_info) |info| {
                if ((info[0] > 0 or info[2] != 0) and (self.immediate_refed or did_work)) {
                    try self.callCoreCallback(immediates.?);
                    try self.drainTicks(drain);
                    try self.checkEventLoopException(main_promise, thrown);
                }
            }
            if (self.exceptions.pending.items.len != 0 or self.exceptions.handled.items.len != 0) continue;
            if (self.immediate_refed) continue;

            const background = c.v8__Isolate__HasPendingBackgroundTasks(iso);
            const live_timer = self.timers.refed and self.timers.deadline_ms != null;
            const live_ops = self.async_driver.refed_count > 0;
            if (self.async_driver.jobs.count() != 0 and (live_ops or live_timer or background)) {
                // Unrefed ops participate in an otherwise-live loop too.
                // Worker completions wake this wait; a timeout keeps V8's
                // default platform responsive until its custom runner lands.
                const timeout: std.Io.Timeout = if (background)
                    .{ .duration = .{ .raw = .{ .nanoseconds = std.time.ns_per_ms }, .clock = .awake } }
                else if (self.timers.refed and self.timers.deadline_ms != null)
                    .{ .deadline = self.timers.start.addDuration(.{ .nanoseconds = @intFromFloat(self.timers.deadline_ms.? * std.time.ns_per_ms) }).withClock(.awake) }
                else
                    .none;
                self.async_driver.wait(timeout);
                continue;
            }
            if (background) {
                if (self.timers.refed and self.timers.deadline_ms != null) {
                    // The default platform has no timed PumpMessageLoop.
                    // Bound the wait so both timer and foreground deadlines
                    // make progress. A custom task runner will replace this
                    // bridge when async I/O adds a unified wakeup source.
                    const delay_ms = @max(0, @min(1, self.timers.deadline_ms.? - self.timers.now(self.io)));
                    std.Io.sleep(self.io, .{ .nanoseconds = @intFromFloat(delay_ms * std.time.ns_per_ms) }, .awake) catch {};
                } else {
                    carried_work = platform.pumpMessageLoop(iso, true);
                }
                continue;
            }
            if (!self.timers.refed or self.timers.deadline_ms == null) return;
            self.timers.wait(self.io);
        }
    }

    fn drainTicks(self: *JsRuntime, callback: ?*const v8.c.Function) v8.Error!void {
        try self.exceptions.dispatchHandled(self);
        if (callback) |f| {
            try self.callCoreCallback(f);
        } else {
            v8.c.v8__Isolate__PerformMicrotaskCheckpoint(self.isolate());
        }
    }

    fn checkEventLoopException(self: *JsRuntime, main_promise: ?*const v8.c.Promise, thrown: *?*const v8.Value) v8.Error!void {
        const c = v8.c;
        const iso = self.isolate();
        if (self.dispatched_exception) |e| {
            thrown.* = e.get(iso);
            e.deinit();
            self.dispatched_exception = null;
            return error.JsException;
        }
        if (main_promise) |promise| {
            if (c.v8__Promise__State(promise) == .rejected) {
                c.v8__Promise__MarkAsHandled(promise);
                self.exception_is_promise = true;
                thrown.* = c.v8__Promise__Result(promise);
                return error.JsException;
            }
        }
    }

    fn callCoreCallback(self: *JsRuntime, callback: *const v8.c.Function) v8.Error!void {
        // Bound local handles created by each iteration of a long-running
        // runtime. A caught exception remains rooted by the caller's TryCatch.
        var scope: v8.HandleScope = undefined;
        scope.init(self.isolate());
        defer scope.deinit();
        _ = v8.c.v8__Function__Call(callback, self.context, @ptrCast(v8.c.v8__Undefined(self.isolate())), 0, &.{}) orelse return error.JsException;
    }

    fn dispatchTimers(self: *JsRuntime) v8.Error!void {
        const c = v8.c;
        const iso = self.isolate();
        var scope: v8.HandleScope = undefined;
        scope.init(iso);
        defer scope.deinit();
        const now = c.v8__Number__New(iso, self.timers.now(self.io));
        const result = c.v8__Function__Call(self.process_timers.?.get(iso), self.context, @ptrCast(c.v8__Undefined(iso)), 1, &.{@ptrCast(now)}) orelse return error.JsException;
        var expiry: c.Maybe(f64) = undefined;
        c.v8__Value__NumberValue(result, self.context, &expiry);
        if (!expiry.has_value) return error.JsException;
        self.timers.setExpiry(self.io, expiry.value);
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

test "core timers drive top-level await, cancellation and microtasks" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///timers.js",
        \\const c = Deno.core;
        \\const events = [];
        \\const timer = (fn, delay, repeat = false, ref = true) => c.createTimer(fn, delay, undefined, repeat, ref, false);
        \\const cancelled = timer(() => { throw new Error("cancelled timer fired"); }, 1);
        \\c.cancelTimer(cancelled);
        \\c.cancelTimer(cancelled);
        \\timer(() => events.push("unref"), 100000, false, false);
        \\await new Promise(resolve => timer(() => {
        \\  events.push("timer");
        \\  queueMicrotask(() => events.push("microtask"));
        \\  resolve();
        \\}, 2));
        \\events.push("await");
        \\let count = 0;
        \\const interval = timer(() => {
        \\  events.push(++count);
        \\  if (count === 3) {
        \\    c.cancelTimer(interval);
        \\    timer(() => events.push("last"), 1);
        \\  }
        \\}, 1, true);
        \\globalThis.timerEvents = events;
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    const result = try rt.executeScript(gpa, "test.js", "timerEvents.join()", &exception);
    const text = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("timer,microtask,await,1,2,3,last", text);
    // Only the unreferenced timer remains tracked; it did not keep us alive.
    try std.testing.expectEqual(@as(usize, 1), rt.timers.active.count());
    try std.testing.expect(!rt.timers.refed);
}

test "timer callback and microtask errors become runtime errors" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "Deno.core.createTimer(() => { throw new Error('timer boom'); }, 1, undefined, false, true, false)",
        "Deno.core.createTimer(() => queueMicrotask(() => { throw new Error('microtask boom'); }), 1, undefined, false, true, false)",
    }, [_][]const u8{ "Error: timer boom", "Error: microtask boom" }) |source, prefix| {
        const rt = try JsRuntime.create(gpa, std.testing.io, .{});
        defer rt.destroy(gpa);
        var exception: ?[]u8 = null;
        defer if (exception) |e| gpa.free(e);
        try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///timer-error.js", source, &exception));
        try std.testing.expect(std.mem.startsWith(u8, exception.?, prefix));
    }
}

test "unreferenced timers do not resolve a pending main module" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///unref.js",
        \\await new Promise(resolve => {
        \\  const t = Deno.core.createTimer(resolve, 100000, undefined, false, false, false);
        \\  Deno.core.refTimer(t);
        \\  Deno.core.unrefTimer(t);
        \\});
    , &exception));
    try std.testing.expectEqualStrings("Top-level await promise never resolved", exception.?);
}

test "main module rejection does not wait for live timers" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///reject.js",
        \\Deno.core.createTimer(() => {}, 100000, undefined, false, true, false);
        \\await Promise.reject(new Error('early rejection'));
    , &exception));
    try std.testing.expect(std.mem.startsWith(u8, exception.?, "Error: early rejection"));
}

test "microtasks run between callbacks in the same timer bucket" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///timer-order.js",
        \\globalThis.order = [];
        \\Deno.core.createTimer(() => {
        \\  order.push('first');
        \\  queueMicrotask(() => order.push('microtask'));
        \\}, 1, undefined, false, true, false);
        \\Deno.core.createTimer((arg) => order.push(arg), 1, ['second'], false, true, false);
    , &exception);
    const result = try rt.executeScript(gpa, "test.js", "order.join()", &exception);
    const text = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("first,microtask,second", text);
    try std.testing.expectEqual(@as(usize, 0), rt.timers.active.count());
}

test "nextTicks drain before promises and between timer callbacks" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///ticks.js",
        \\const c = Deno.core;
        \\globalThis.events = [];
        \\const tick = (fn, args) => c.queueNextTick({callback: fn, args, snapshot: c.getAsyncContext()});
        \\tick((a, b) => { events.push(a+b); tick(() => events.push('nested')); }, ['tick', '1']);
        \\Promise.resolve().then(() => { events.push('promise'); tick(() => events.push('promise-tick')); });
        \\c.createTimer(() => {
        \\  events.push('timer1');
        \\  tick(() => events.push('timer-tick'));
        \\  Promise.resolve().then(() => events.push('timer-promise'));
        \\}, 1, undefined, false, true, false);
        \\c.createTimer(() => events.push('timer2'), 1, undefined, false, true, false);
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    const result = try rt.executeScript(gpa, "test.js", "events.join()", &exception);
    const text = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("tick1,nested,promise,promise-tick,timer1,timer-tick,timer-promise,timer2", text);
}

test "unhandled rejections and tick errors reach the runtime" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "Promise.reject(new TypeError('unhandled'))",
        "Promise.reject(undefined)",
        "Deno.core.queueNextTick({callback() { throw new Error('tick boom'); }})",
        "Deno.core.createTimer(() => Promise.reject('timer rejection'), 1, undefined, false, true, false)",
        "Deno.core.ops.op_error_async_deferred()",
    };
    for (sources, [_][]const u8{ "TypeError: unhandled", "undefined", "Error: tick boom", "timer rejection", "Error: error" }, [_]bool{ true, true, false, true, true }) |source, expected, is_promise| {
        const rt = try JsRuntime.create(gpa, std.testing.io, .{});
        defer rt.destroy(gpa);
        var exception: ?[]u8 = null;
        defer if (exception) |e| gpa.free(e);
        try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///unhandled.js", source, &exception));
        try std.testing.expect(std.mem.startsWith(u8, exception.?, expected));
        try std.testing.expectEqual(is_promise, rt.exception_is_promise);
    }
}

test "handlers attached before yielding suppress unhandled rejections" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///handled.js",
        \\const c = Deno.core;
        \\c.setUnhandledPromiseRejectionHandler(() => { throw new Error('unexpected unhandled'); });
        \\c.setHandledPromiseRejectionHandler(() => { throw new Error('unexpected late handler'); });
        \\try {
        \\  c.setHandledPromiseRejectionHandler(1);
        \\  throw new Error('invalid handler accepted');
        \\} catch (e) {
        \\  if (!(e instanceof TypeError) || e.message !== 'expected Function') throw e;
        \\}
        \\Promise.reject('sync').catch(() => {});
        \\const p = Promise.reject('microtask');
        \\queueMicrotask(() => p.catch(() => {}));
        \\const q = Promise.reject('tick');
        \\c.queueNextTick({callback() { q.catch(() => {}); }});
        \\new Promise((resolve, reject) => { resolve(); reject('already resolved'); });
        \\await Promise.reject('caught await').catch(() => {});
    , &exception);
    try std.testing.expectEqual(@as(usize, 0), rt.exceptions.pending.items.len);
}

test "rejections restore async context and notify late handlers once" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///rejection-handlers.js",
        \\const c = Deno.core;
        \\globalThis.rejections = [];
        \\const ctx = { value: 42 };
        \\c.setHandledPromiseRejectionHandler((promise, reason) => {
        \\  if (reason !== 'late') throw new Error('wrong reason');
        \\  rejections.push('handled');
        \\});
        \\c.setUnhandledPromiseRejectionHandler((promise, reason) => {
        \\  if (c.getAsyncContext() !== ctx) throw new Error('lost context');
        \\  rejections.push(reason);
        \\  c.createTimer(() => promise.catch(() => {}), 1, undefined, false, true, false);
        \\  return true;
        \\});
        \\c.setAsyncContext(ctx);
        \\Promise.reject('late');
        \\c.setAsyncContext(undefined);
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    const result = try rt.executeScript(gpa, "test.js", "rejections.join()", &exception);
    const text = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("late,handled", text);
    try std.testing.expectEqual(@as(usize, 0), rt.exceptions.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), rt.exceptions.handled.items.len);
}

test "main module rejection is observed once without a user rejection event" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///main-rejection.js",
        \\Deno.core.setUnhandledPromiseRejectionHandler(() => { throw new Error('duplicate event'); });
        \\await Promise.resolve();
        \\throw new Error('main rejection');
    , &exception));
    try std.testing.expect(std.mem.startsWith(u8, exception.?, "Error: main rejection"));
}

test "immediates drain in batches with ticks and promises between callbacks" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///immediates.js",
        \\const c = Deno.core;
        \\globalThis.order = [];
        \\const immediate = (fn, args) => {
        \\  const item = { _onImmediate: fn, _argv: args, _destroyed: false,
        \\    _idlePrev: null, _idleNext: null, [c.kRefed]: true };
        \\  c.immediateRefCount(true);
        \\  c.queueImmediate(item);
        \\  return item;
        \\};
        \\const cancelled = immediate(() => { throw new Error('cancelled immediate fired'); });
        \\c.clearImmediate(cancelled); c.clearImmediate(cancelled);
        \\immediate(() => {
        \\  order.push('first');
        \\  c.queueNextTick({callback() { order.push('tick'); }});
        \\  Promise.resolve().then(() => order.push('promise'));
        \\  immediate(() => order.push('nested'));
        \\});
        \\immediate((arg) => order.push(arg), ['second']);
        \\await new Promise(resolve => immediate(resolve));
        \\order.push('await');
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    const result = try rt.executeScript(gpa, "test.js", "order.join()", &exception);
    const text = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("first,tick,promise,second,await,nested", text);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, rt.immediate_info.?.*);
    try std.testing.expect(!rt.immediate_refed);
}

test "unrefed immediates require actual work, not a future timer" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///unref-immediate.js",
        \\const c = Deno.core;
        \\globalThis.order = [];
        \\const item = { _onImmediate() { order.push('unref'); }, _destroyed: false,
        \\  _idlePrev: null, _idleNext: null, [c.kRefed]: false };
        \\c.queueImmediate(item);
    , &exception);
    // The unrefed item alone did not drive a check phase.
    try std.testing.expectEqual(@as(i32, 1), rt.immediate_info.?[0]);
    try rt.executeMainModule(gpa, "file:///ref-timer.js",
        \\Deno.core.createTimer(() => order.push('timer'), 5, undefined, false, true, false);
    , &exception);
    const result = try rt.executeScript(gpa, "test.js", "order.join()", &exception);
    const text = try v8.toUtf8(gpa, rt.isolate(), rt.context, result);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("timer,unref", text);
}

test "immediates run before waiting for future timers and errors propagate" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///immediate-error.js",
        \\const c = Deno.core;
        \\c.createTimer(() => {}, 100000, undefined, false, true, false);
        \\c.immediateRefCount(true);
        \\c.queueImmediate({ _onImmediate() { throw new Error('immediate boom'); },
        \\  _destroyed: false, _idlePrev: null, _idleNext: null, [c.kRefed]: true });
    , &exception));
    try std.testing.expect(std.mem.startsWith(u8, exception.?, "Error: immediate boom"));
}

test "V8 background compilation settles awaited WebAssembly promises" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///wasm.js",
        \\// A wasm function exporting answer() -> i32, compiled by V8.
        \\globalThis.wasmBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 3,2,1,0,
        \\  7,10,1,6,97,110,115,119,101,114,0,0, 10,6,1,4,0,65,42,11
        \\]);
        \\const bytes = wasmBytes;
        \\const modules = await Promise.all(Array.from({length: 8}, () => WebAssembly.compile(bytes)));
        \\if (!modules.every(m => m instanceof WebAssembly.Module)) throw new Error('compile');
        \\const instance = await WebAssembly.instantiate(modules[0]);
        \\if (instance.exports.answer() !== 42) throw new Error('wasm result');
        \\// Exercise V8 completion while a referenced JS timer is active.
        \\const timer = Deno.core.createTimer(() => { throw new Error('completion blocked behind timer'); }, 100000, undefined, false, true, false);
        \\await WebAssembly.compile(bytes);
        \\Deno.core.cancelTimer(timer);
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try rt.executeMainModule(gpa, "file:///wasm-detached.js",
        \\WebAssembly.compile(wasmBytes).then(() => { globalThis.detachedWasmDone = true; });
    , &exception);
    const done = try rt.executeScript(gpa, "test.js", "globalThis.detachedWasmDone === true", &exception);
    try std.testing.expect(v8.c.v8__Value__BooleanValue(done, rt.isolate()));
    try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///wasm-error.js",
        \\await WebAssembly.compile(new Uint8Array([1, 2, 3]));
    , &exception));
    try std.testing.expect(std.mem.startsWith(u8, exception.?, "CompileError:"));
}

test "resource close preserves retained native file ownership" {
    v8.initForTesting();
    const resources = @import("resources.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "retained.txt", .data = "retained" });
    const FileResource = struct {
        file: std.Io.File,
        io: std.Io,
        closes: *usize,
        drops: *usize,
        pub fn name(_: *const @This()) []const u8 {
            return "testFile";
        }
        pub fn close(self: *@This()) void {
            self.closes.* += 1;
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.file.close(self.io);
            self.drops.* += 1;
        }
    };
    var closes: usize = 0;
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, io, .{});
    defer rt.destroy(gpa);
    const file = try tmp.dir.openFile(io, "retained.txt", .{});
    const rid = try rt.resources.add(try resources.Resource.create(gpa, FileResource, .{ .file = file, .io = io, .closes = &closes, .drops = &drops }));
    try std.testing.expectEqual(@as(u32, 0), rid);
    var held: ?resources.ResourceRef(FileResource) = try rt.resources.get(FileResource, rid);
    defer if (held) |r| r.deinit();
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    _ = try rt.executeScript(gpa, "resources.js",
        \\const c = Deno.core;
        \\if (c.resources()[0] !== 'testFile') throw new Error('resource name');
        \\c.cancelRead(0); // default hook leaves this file intact
        \\c.tryClose(999); c.cancelRead(999);
        \\c.close(0);
        \\if (Object.keys(c.resources()).length !== 0) throw new Error('resource remained');
        \\c.tryClose(0);
        \\try { c.close(0); throw new Error('missing resource accepted'); }
        \\catch (e) {
        \\  if (!(e instanceof c.BadResource) || e.name !== 'BadResource' || e.message !== 'Bad resource ID') throw e;
        \\}
    , &exception);
    try std.testing.expectEqual(@as(usize, 1), closes);
    try std.testing.expectEqual(@as(usize, 0), drops);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try held.?.ptr().file.readPositionalAll(io, &buf, 0));
    try std.testing.expectEqualStrings("retained", &buf);
    held.?.deinit();
    held = null;
    try std.testing.expectEqual(@as(usize, 1), drops);
}

test "resource close hooks can re-enter the resource table" {
    v8.initForTesting();
    const resources = @import("resources.zig");
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var removed_before_close = false;
    var cancellations: usize = 0;
    const ReentrantResource = struct {
        table: *resources.ResourceTable,
        removed: *bool,
        cancellations: *usize,
        const Replacement = struct {
            pub fn name(_: *const @This()) []const u8 {
                return "replacement";
            }
        };
        pub fn close(self: *@This()) void {
            self.removed.* = !self.table.has(0);
            _ = self.table.add(resources.Resource.create(self.table.gpa, Replacement, .{}) catch unreachable) catch unreachable;
        }
        pub fn cancelReadOps(self: *@This()) void {
            self.cancellations.* += 1;
        }
    };
    _ = try rt.resources.add(try resources.Resource.create(gpa, ReentrantResource, .{ .table = &rt.resources, .removed = &removed_before_close, .cancellations = &cancellations }));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///resource-hooks.js",
        \\import { op_cancel_read, op_close, op_resources } from 'ext:core/ops';
        \\op_cancel_read(0);
        \\if (op_resources().length !== 1) throw new Error('cancel removed resource');
        \\op_close(0);
        \\if (Deno.core.resources()[1] !== 'replacement') throw new Error('reentrant add failed');
        \\Deno.core.tryClose(1);
    , &exception);
    try std.testing.expect(removed_before_close);
    try std.testing.expectEqual(@as(usize, 1), cancellations);
    try std.testing.expectEqual(@as(usize, 0), rt.resources.len());
}

test "resource snapshots preserve Rust's RID ordering through replacement" {
    v8.initForTesting();
    const resources = @import("resources.zig");
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    const Named = struct {
        label: []const u8,
        pub fn name(self: *const @This()) []const u8 {
            return self.label;
        }
    };
    for (0..8) |_| _ = try rt.resources.add(try resources.Resource.create(gpa, Named, .{ .label = "original" }));
    (try rt.resources.takeAny(1)).deinit();
    try rt.resources.replace(2, try resources.Resource.create(gpa, Named, .{ .label = "replacement" }));
    _ = try rt.resources.add(try resources.Resource.create(gpa, Named, .{ .label = "last" }));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    _ = try rt.executeScript(gpa, "resource-order.js",
        \\const rows = Deno.core.ops.op_resources();
        \\if (rows.map(row => row[0]).join() !== '0,2,3,4,5,6,7,8') throw new Error('RID order');
        \\if (Deno.core.resources()[2] !== 'replacement') throw new Error('replacement name');
    , &exception);
}

test "async ops preserve eager, deferred and lazy promise semantics" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const F = struct {
        var calls: usize = 0;
        fn lazy(value: i32) i32 {
            calls += 1;
            return value * 2;
        }
    };
    F.calls = 0;
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{a.decl("op_test_lazy", F.lazy, .{ .execution = .inline_ready, .scheduling = .lazy })} });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    _ = try rt.executeScript(gpa, "async-start.js",
        \\const c = Deno.core, o = c.ops, id = c.promiseIdSymbol;
        \\globalThis.trace = [];
        \\const eager = o.op_add_async(20, 22);
        \\if (id in eager || o.op_add_async.length !== 2) throw new Error('eager protocol');
        \\eager.then(() => trace.push('eager'));
        \\Promise.resolve().then(() => trace.push('microtask'));
        \\const deferred = o.op_void_async_deferred();
        \\if (!c.hasPromise(deferred[id])) throw new Error('deferred promise missing');
        \\deferred.then(() => trace.push('deferred'));
        \\const lazy = o.op_test_lazy(21);
        \\lazy.then(() => trace.push('lazy'));
        \\globalThis.allOps = Promise.all([eager, deferred, lazy, o.op_void_async(),
        \\  o.op_error_async().catch(e => e.message), o.op_error_async_deferred().catch(e => e.message),
        \\  o.op_add_async(0x7fffffff, 1)]);
    , &exception);
    try std.testing.expectEqual(@as(usize, 0), F.calls);
    rt.executeMainModule(gpa, "file:///async-finish.js",
        \\const values = await allOps;
        \\if (JSON.stringify(values) !== '[42,null,42,null,"error","error",-2147483648]') throw new Error('async results');
        \\if (trace.join() !== 'eager,microtask,deferred,lazy') throw new Error('async ordering: ' + trace);
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), F.calls);
    try std.testing.expectEqual(@as(usize, 0), rt.async_driver.jobs.count());
}

test "async op promise IDs wrap and spill beyond the JS ring" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///async-ids.js",
        \\const c = Deno.core;
        \\c.__setNextPromiseId(0x7fffffff);
        \\const promises = Array.from({length: 4200}, () => c.ops.op_void_async_deferred());
        \\if (promises[0][c.promiseIdSymbol] !== 0x7fffffff || promises[1][c.promiseIdSymbol] !== 0) throw new Error('ID wrap');
        \\const values = await Promise.all(promises);
        \\if (!values.every(v => v === null)) throw new Error('ring spill');
        \\if (promises.some(p => c.hasPromise(p[c.promiseIdSymbol]))) throw new Error('promise retained');
    , &exception);
    try std.testing.expectEqual(@as(usize, 0), rt.async_driver.refed_count);
    try std.testing.expectEqual(@as(usize, 0), rt.async_driver.jobs.count());
}

const AsyncGateTest = struct {
    var gate: std.Io.Event = .unset;
    var entered: std.Io.Event = .unset;
    var canceled: std.atomic.Value(bool) = .init(false);
    fn wait(scope: @import("async_ops.zig").AsyncScope, text: []const u8) ![]const u8 {
        entered.set(scope.io);
        gate.wait(scope.io) catch |err| {
            canceled.store(true, .release);
            return err;
        };
        return std.fmt.allocPrint(scope.allocator, "{s} returned", .{text});
    }
    fn release(scope: ops.Scope) void {
        gate.set(scope.runtime.io);
    }
};

test "concurrent op completion wakes the loop without blocking JS timers" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    AsyncGateTest.gate.reset();
    AsyncGateTest.entered.reset();
    AsyncGateTest.canceled.store(false, .release);
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        a.decl("op_test_wait", AsyncGateTest.wait, .{}), ops.op("op_test_release", AsyncGateTest.release),
    } });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///async-gate.js",
        \\const c = Deno.core;
        \\let source = 'copied';
        \\const pending = c.ops.op_test_wait({toString() { return source; }});
        \\source = 'changed';
        \\c.unrefOpPromise(pending); c.refOpPromise(pending);
        \\let timerRan = false;
        \\c.createTimer(() => { timerRan = true; c.ops.op_test_release(); }, 1, undefined, false, true, false);
        \\const result = await pending;
        \\if (!timerRan || result !== 'copied returned') throw new Error('worker completion');
        \\await new Promise(resolve => c.createTimer(resolve, 1, undefined, false, true, false));
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expect(!AsyncGateTest.canceled.load(.acquire));
}

test "unrefed worker ops are canceled and joined during shutdown" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    AsyncGateTest.gate.reset();
    AsyncGateTest.entered.reset();
    AsyncGateTest.canceled.store(false, .release);
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{a.decl("op_test_wait", AsyncGateTest.wait, .{})} });
    var alive = true;
    defer if (alive) rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try std.testing.expectError(error.JsException, rt.executeMainModule(gpa, "file:///async-unref.js",
        \\const pending = Array.from({length: 4}, () => Deno.core.ops.op_test_wait('never released'));
        \\pending.forEach(p => Deno.core.unrefOpPromise(p));
        \\await Promise.all(pending);
    , &exception));
    try std.testing.expectEqualStrings("Top-level await promise never resolved", exception.?);
    try AsyncGateTest.entered.wait(std.testing.io);
    rt.destroy(gpa);
    alive = false;
    try std.testing.expect(AsyncGateTest.canceled.load(.acquire));
}

test "native async ops read real files with owned string arguments" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const F = struct {
        fn read(scope: a.AsyncScope, path: []const u8) ![]const u8 {
            return std.Io.Dir.cwd().readFileAlloc(scope.io, path, scope.allocator, .unlimited);
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "async.txt", .data = "asynchronous file contents" });
    const path = try tmp.dir.realPathFileAlloc(io, "async.txt", gpa);
    defer gpa.free(path);
    const rt = try JsRuntime.create(gpa, io, .{ .ops = &.{a.decl("op_test_read_file", F.read, .{})} });
    defer rt.destroy(gpa);
    try v8.setProperty(rt.isolate(), rt.context, v8.c.v8__Context__Global(rt.context), "filePath", @ptrCast(try v8.newString(rt.isolate(), path)));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///async-file.js",
        \\const text = await Deno.core.ops.op_test_read_file(filePath);
        \\if (text !== 'asynchronous file contents') throw new Error('file read');
        \\try {
        \\  await Deno.core.ops.op_test_read_file(filePath + '.missing');
        \\  throw new Error('missing file accepted');
        \\} catch (e) { if (e.message !== 'FileNotFound') throw e; }
    , &exception);
}

test "canceling one native op leaves other workers and promises live" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const F = struct {
        fn cancel(scope: ops.Scope, id: i32) void {
            scope.runtime.async_driver.cancel(id);
        }
    };
    AsyncGateTest.gate.reset();
    AsyncGateTest.entered.reset();
    AsyncGateTest.canceled.store(false, .release);
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        a.decl("op_test_wait", AsyncGateTest.wait, .{}),
        ops.op("op_test_release", AsyncGateTest.release),
        ops.op("op_test_cancel", F.cancel),
    } });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///async-cancel.js",
        \\const c = Deno.core;
        \\const first = c.ops.op_test_wait('first');
        \\const caught = first.catch(e => e.message);
        \\const second = c.ops.op_test_wait('second');
        \\c.ops.op_test_cancel(first[c.promiseIdSymbol]);
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\const values = await Promise.all([caught, second]);
        \\if (values.join() !== 'Canceled,second returned') throw new Error('cancellation isolation');
    , &exception);
    try std.testing.expectEqual(@as(usize, 0), rt.async_driver.jobs.count());
}

test "unrefed op completion still wakes a loop kept alive by a timer" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const F = struct {
        fn delayed(scope: a.AsyncScope, text: []const u8) ![]const u8 {
            const result = try AsyncGateTest.wait(scope, text);
            // Release from a JS timer, then finish in a later I/O turn.
            try std.Io.sleep(scope.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
            return result;
        }
    };
    AsyncGateTest.gate.reset();
    AsyncGateTest.entered.reset();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        a.decl("op_test_delayed", F.delayed, .{}), ops.op("op_test_release", AsyncGateTest.release),
    } });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///async-unref-wake.js",
        \\const c = Deno.core;
        \\const pending = c.ops.op_test_delayed('unrefed');
        \\c.unrefOpPromise(pending);
        \\let blockerRan = false;
        \\const blocker = c.createTimer(() => { blockerRan = true; }, 5000, undefined, false, true, false);
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\const value = await pending;
        \\if (blockerRan || value !== 'unrefed returned') throw new Error('completion slept behind refed timer');
        \\c.cancelTimer(blocker);
    , &exception);
}

const BufferBindingTest = struct {
    const B = @import("buffers.zig");
    fn echo(buffer: B.JsBuffer) B.JsBuffer {
        return buffer.clone();
    }
    fn any(buffer: B.AnyBuffer) B.AnyBuffer {
        return buffer.clone();
    }
    fn length(buffer: B.ArrayBuffer) u32 {
        return @intCast(buffer.len);
    }
    fn count(buffer: B.JsBuffer) f64 {
        return @floatFromInt(v8.c.std__shared_ptr__v8__BackingStore__use_count(&buffer.store));
    }
    fn failAfterBuffer(_: B.JsBuffer, _: i32) void {}
    fn failAsync(_: B.JsBuffer) error{BufferFailure}!B.JsBuffer {
        return error.BufferFailure;
    }
    fn detach(_: ops.Scope, value: *const v8.Value) void {
        _ = v8.c.v8__ArrayBuffer__Detach(@ptrCast(value), null);
    }
};

test "buffer op bindings preserve byte ranges and typed input contracts" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        ops.op("op_echo_buffer", BufferBindingTest.echo),           ops.op("op_any_buffer", BufferBindingTest.any),
        ops.op("op_array_buffer_length", BufferBindingTest.length), ops.op("op_detach_buffer", BufferBindingTest.detach),
    } });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///buffer-types.js",
        \\const o = Deno.core.ops;
        \\const full = new Uint8Array([1,2,3,4,5,6,7,8]);
        \\const part = o.op_echo_buffer(full.subarray(2,5));
        \\if (!(part instanceof Uint8Array) || part.byteOffset !== 2 || part.join() !== '3,4,5') throw new Error('range');
        \\part[0] = 42;
        \\if (full[2] !== 42) throw new Error('backing storage copied');
        \\if (o.op_array_buffer_length(full.buffer) !== 8) throw new Error('ArrayBuffer');
        \\if (o.op_any_buffer(new DataView(full.buffer,1,2)).join() !== '2,42') throw new Error('DataView range');
        \\if (o.op_any_buffer(new Uint16Array(full.buffer,4,2)).join() !== '5,6,7,8') throw new Error('typed byte range');
        \\if (o.op_any_buffer(full.buffer).length !== 8) throw new Error('any buffer');
        \\for (const invalid of [[], {}, 'bytes', full.buffer, new Uint16Array(1), new Uint8ClampedArray(1), new DataView(full.buffer)]) {
        \\  try { o.op_echo_buffer(invalid); throw new Error('accepted invalid'); }
        \\  catch (e) { if (!(e instanceof TypeError) || e.message !== 'expected typed ArrayBufferView') throw e; }
        \\}
        \\try { o.op_array_buffer_length(full); throw new Error('accepted view'); }
        \\catch (e) { if (!(e instanceof TypeError) || e.message !== 'expected ArrayBuffer') throw e; }
        \\const empty = o.op_echo_buffer(new Uint8Array(0));
        \\if (empty.length !== 0) throw new Error('empty');
        \\const detached = new Uint8Array(4);
        \\o.op_detach_buffer(detached.buffer);
        \\if (o.op_echo_buffer(detached).length !== 0) throw new Error('detached range');
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
}

test "shared and resizable backing stores retain their native op ranges" {
    v8.initForTesting();
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{ops.op("op_echo_buffer", BufferBindingTest.echo)} });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///buffer-stores.js",
        \\const shared = new Uint8Array(new SharedArrayBuffer(8));
        \\shared.set([1,2,3,4]);
        \\const OriginalUint8Array = Uint8Array;
        \\globalThis.Uint8Array = function() { throw new Error('poisoned constructor'); };
        \\const result = Deno.core.ops.op_echo_buffer(shared.subarray(1,3));
        \\globalThis.Uint8Array = OriginalUint8Array;
        \\if (!(result.buffer instanceof SharedArrayBuffer) || result.byteOffset !== 1 || result.join() !== '2,3') throw new Error('shared output');
        \\result[0] = 99;
        \\if (shared[1] !== 99) throw new Error('shared storage copied');
        \\const rab = new ArrayBuffer(8, {maxByteLength:16});
        \\const view = new Uint8Array(rab,2,3);
        \\view.set([5,6,7]);
        \\const retained = Deno.core.ops.op_echo_buffer(view);
        \\if (retained.byteOffset !== 2 || retained.join() !== '5,6,7') throw new Error('resizable range');
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
}

test "buffer argument owners are released on conversion and async errors" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        ops.op("op_buffer_count", BufferBindingTest.count),               ops.op("op_buffer_fail_conversion", BufferBindingTest.failAfterBuffer),
        a.decl("op_buffer_fail_async", BufferBindingTest.failAsync, .{}),
    } });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///buffer-cleanup.js",
        \\const o = Deno.core.ops, data = new Uint8Array(8);
        \\const before = o.op_buffer_count(data);
        \\try { o.op_buffer_fail_conversion(data, {valueOf() { throw new Error('conversion'); }}); }
        \\catch (e) { if (e.message !== 'conversion') throw e; }
        \\if (o.op_buffer_count(data) !== before) throw new Error('partial conversion leaked');
        \\await Promise.all(Array.from({length:32}, () => o.op_buffer_fail_async(data).catch(e => {
        \\  if (e.message !== 'BufferFailure') throw e;
        \\})));
        \\if (o.op_buffer_count(data) !== before) throw new Error('async failure leaked');
    , &exception);
}

const PipeTestOps = struct {
    const declarations = [_]ops.OpDecl{
        ops.op("op_test_make_cancel", makeCancel),
        ops.op("op_test_wait_entered", waitEntered),
        ops.op("op_test_rewind", rewind),
        ops.op("op_test_release", AsyncGateTest.release),
    };
    fn makeCancel(scope: ops.Scope, canceled: bool) !u32 {
        const R = @import("resources.zig");
        const C = @import("async_cancel.zig").CancelHandle;
        var handle: C = .init(scope.runtime.gpa);
        if (canceled) handle.cancel();
        return scope.runtime.resources.add(try R.Resource.create(scope.runtime.gpa, C, handle));
    }
    fn waitEntered(scope: ops.Scope) !void {
        try AsyncGateTest.entered.wait(scope.runtime.io);
    }
    fn rewind(resource: @import("resources.zig").ResourceRef(ResourceIoTest)) void {
        resource.ptr().read_offset = 0;
    }
};

const PipeBlockingResource = struct {
    mode: enum { ready, block_read, block_write },
    produced: bool = false,
    drops: *usize,
    pub fn read(self: *@This(), io: std.Io, data: []u8) !usize {
        if (self.mode == .block_read) {
            AsyncGateTest.entered.set(io);
            try AsyncGateTest.gate.wait(io);
            return 0;
        }
        if (self.produced or data.len == 0) return 0;
        data[0] = 42;
        self.produced = true;
        return 1;
    }
    pub fn write(self: *@This(), io: std.Io, data: []const u8) !usize {
        if (self.mode == .block_write) {
            AsyncGateTest.entered.set(io);
            try AsyncGateTest.gate.wait(io);
        }
        return data.len;
    }
    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.drops.* += 1;
    }
};

const ResourceIoTest = struct {
    file: std.Io.File,
    io: std.Io,
    drops: *usize,
    mutex: std.Io.Mutex = .init,
    read_offset: u64 = 0,
    write_offset: u64 = 0,
    write_shutdown: bool = false,

    pub fn read(self: *@This(), io: std.Io, data: []u8) !usize {
        AsyncGateTest.entered.set(io);
        try AsyncGateTest.gate.wait(io);
        return self.readSync(io, data);
    }
    pub fn readSync(self: *@This(), io: std.Io, data: []u8) !usize {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const n = try self.file.readPositional(io, &.{data}, self.read_offset);
        self.read_offset += n;
        return n;
    }
    pub fn write(self: *@This(), io: std.Io, data: []const u8) !usize {
        return self.writeSync(io, data);
    }
    pub fn writeSync(self: *@This(), io: std.Io, data: []const u8) !usize {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.write_shutdown) return error.WriteAfterShutdown;
        const n = try self.file.writePositional(io, &.{data[0..@min(data.len, 3)]}, self.write_offset);
        self.write_offset += n;
        return n;
    }
    pub fn shutdown(self: *@This(), io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.write_shutdown = true;
    }
    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.file.close(self.io);
        self.drops.* += 1;
    }
};

test "core resource I/O handles files, partial writes, EOF and retained pending reads" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var drops: usize = 0;
    AsyncGateTest.gate.reset();
    const rt = try JsRuntime.create(gpa, io, .{ .ops = &.{
        ops.op("op_test_release", AsyncGateTest.release),
        ops.op("op_buffer_echo", BufferBindingTest.echo),
        ops.op("op_detach_buffer", BufferBindingTest.detach),
    } });
    defer rt.destroy(gpa);
    const file = try tmp.dir.createFile(io, "core-io", .{ .read = true });
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = file, .io = io, .drops = &drops }));
    const eof_file = try tmp.dir.openFile(io, "core-io", .{});
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = eof_file, .io = io, .drops = &drops, .read_offset = 9 }));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///core-resource-io.js",
        \\import { op_read, op_write_sync } from 'ext:core/ops';
        \\const c = Deno.core;
        \\const written = await c.write(0, new Uint8Array([99,1,2,3,99]).subarray(1,4));
        \\if (written !== 3) throw new Error('async write');
        \\if (await c.writeAll(0, new Uint8Array([4,5,6,7])) !== null) throw new Error('writeAll');
        \\if (op_write_sync(0, new Uint8Array([8,9])) !== 2) throw new Error('sync write');
        \\await c.shutdown(0);
        \\try { await c.write(0, new Uint8Array([10])); throw new Error('shutdown ignored'); }
        \\catch (e) { if (e.message !== 'WriteAfterShutdown') throw e; }
        \\const first = new Uint8Array(2);
        \\if (c.readSync(0, first) !== 2 || first.join() !== '1,2') throw new Error('sync read');
        \\const storage = new ArrayBuffer(12), view = new Uint8Array(storage,2,8);
        \\const retained = c.ops.op_buffer_echo(view);
        \\const pending = op_read(0, view);
        \\c.close(0);
        \\c.ops.op_detach_buffer(storage);
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\if (await pending !== 7 || retained.join() !== '3,4,5,6,7,8,9,0') throw new Error('pending read');
        \\if (c.readSync(1, retained) !== 0 || await c.read(1, retained) !== 0) throw new Error('EOF');
        \\if (await c.read(1, new Uint8Array(0)) !== 0) throw new Error('empty read');
        \\c.close(1);
        \\try { await c.read(0, retained); throw new Error('closed RID accepted'); }
        \\catch (e) { if (!(e instanceof c.BadResource)) throw e; }
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), drops);
    // The persisted bytes verify write-all retried every partial native write.
    const output = try tmp.dir.readFileAlloc(io, "core-io", gpa, .unlimited);
    defer gpa.free(output);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, output);
}

test "native pipe copies files and consumes cancellation RIDs before callbacks and error builders" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const content = "chunks travel through native resources";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = content });
    AsyncGateTest.gate.reset();
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, io, .{ .ops = &PipeTestOps.declarations });
    defer rt.destroy(gpa);
    const source = try tmp.dir.openFile(io, "source", .{});
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = source, .io = io, .drops = &drops }));
    const sink = try tmp.dir.createFile(io, "sink", .{ .read = true });
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = sink, .io = io, .drops = &drops }));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///native-file-pipe.js",
        \\import { op_pipe } from 'ext:core/ops';
        \\const c = Deno.core, make = c.ops.op_test_make_cancel;
        \\const cancel = make(false), pending = op_pipe(0,1,cancel);
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\await pending.then(value => {
        \\  if (value !== null || c.resources()[cancel] !== undefined) throw new Error('cancel RID survived resolution');
        \\  if (!c.resources()[0] || !c.resources()[1]) throw new Error('pipe closed source/sink');
        \\});
        \\if (String.fromCharCode(...await c.readAll(1)) !== 'chunks travel through native resources') throw new Error('file copy');
        \\await op_pipe(0,1);
        \\await op_pipe(0,1,null);
        \\await op_pipe(0,1,999);
        \\const invalidSourceCancel = make(false);
        \\try { await op_pipe(99,1,invalidSourceCancel); throw new Error('missing source accepted'); }
        \\catch (e) { if (!(e instanceof c.BadResource)) throw e; }
        \\if (!c.resources()[invalidSourceCancel]) throw new Error('setup error consumed cancel RID');
        \\c.close(invalidSourceCancel);
        \\const badSink = make(false), errorCancel = make(false);
        \\class Unsupported extends Error {
        \\  constructor(message) {
        \\    super(message);
        \\    if (c.resources()[errorCancel] !== undefined) throw new Error('cleanup after error builder');
        \\  }
        \\}
        \\c.registerErrorClass('NotSupported', Unsupported);
        \\c.ops.op_test_rewind(0);
        \\try { await op_pipe(0,badSink,errorCancel); throw new Error('unsupported sink accepted'); }
        \\catch (e) { if (!(e instanceof Unsupported) || e.message !== 'The operation is not supported') throw e; }
        \\if (!c.resources()[badSink]) throw new Error('pipe closed unsupported sink');
        \\c.close(badSink);
        \\// Rust consumes an optional RID even when it names a different type.
        \\await op_pipe(0,1,0);
        \\if (c.resources()[0] !== undefined || !c.resources()[1]) throw new Error('wrong-type cancel RID');
        \\c.close(1);
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), drops);
    const copied = try tmp.dir.readFileAlloc(io, "sink", gpa, .unlimited);
    defer gpa.free(copied);
    try std.testing.expectEqualStrings(content, copied);
}

test "closing a shared cancel handle interrupts blocked pipe reads and writes" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |block_write| {
        AsyncGateTest.gate.reset();
        AsyncGateTest.entered.reset();
        var drops: usize = 0;
        const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &PipeTestOps.declarations });
        defer rt.destroy(gpa);
        for (0..2) |_| {
            _ = try rt.resources.add(try R.Resource.create(gpa, PipeBlockingResource, .{ .mode = if (block_write) .ready else .block_read, .drops = &drops }));
            _ = try rt.resources.add(try R.Resource.create(gpa, PipeBlockingResource, .{ .mode = if (block_write) .block_write else .ready, .drops = &drops }));
        }
        var exception: ?[]u8 = null;
        defer if (exception) |e| gpa.free(e);
        rt.executeMainModule(gpa, "file:///cancel-pipe.js",
            \\const c = Deno.core, pipe = c.ops.op_pipe, make = c.ops.op_test_make_cancel;
            \\const cancel = make(false);
            \\const first = pipe(0,1,cancel), second = pipe(2,3,cancel);
            \\function interrupted(e) {
            \\  if (!(e instanceof c.Interrupted) || e.message !== 'operation canceled') throw e;
            \\  if (c.resources()[cancel] !== undefined) throw new Error('cancel RID survived rejection');
            \\}
            \\const caught = Promise.all([first.catch(interrupted), second.catch(interrupted), c.ops.op_void_async_deferred()]);
            \\c.ops.op_test_wait_entered();
            \\c.close(cancel);
            \\await caught;
            \\if (Object.keys(c.resources()).length !== 4) throw new Error('pipe closed resources');
            \\const before = make(true);
            \\try { await pipe(0,1,before); throw new Error('already-canceled pipe ran'); }
            \\catch (e) { if (!(e instanceof c.Interrupted)) throw e; }
            \\if (c.resources()[before] !== undefined) throw new Error('already-canceled RID survived');
            \\for (let rid=0; rid<4; ++rid) c.close(rid);
        , &exception) catch |err| {
            std.debug.print("{s}\n", .{exception orelse @errorName(err)});
            return err;
        };
        try std.testing.expectEqual(@as(usize, 4), drops);
        try std.testing.expectEqual(@as(usize, 0), rt.async_driver.jobs.count());
    }
}

test "runtime shutdown joins all pipes before releasing shared cancel registrations" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    AsyncGateTest.gate.reset();
    AsyncGateTest.entered.reset();
    var drops: usize = 0;
    {
        const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &PipeTestOps.declarations });
        defer rt.destroy(gpa);
        for (0..2) |_| {
            _ = try rt.resources.add(try R.Resource.create(gpa, PipeBlockingResource, .{ .mode = .block_read, .drops = &drops }));
            _ = try rt.resources.add(try R.Resource.create(gpa, PipeBlockingResource, .{ .mode = .ready, .drops = &drops }));
        }
        var exception: ?[]u8 = null;
        defer if (exception) |e| gpa.free(e);
        _ = try rt.executeScript(gpa, "pending-pipes.js",
            \\const cancel = Deno.core.ops.op_test_make_cancel(false);
            \\Deno.core.ops.op_pipe(0,1,cancel);
            \\Deno.core.ops.op_pipe(2,3,cancel);
            \\Deno.core.ops.op_test_wait_entered();
        , &exception);
    }
    try std.testing.expectEqual(@as(usize, 4), drops);
}

test "resource I/O uses registered errors and validates erased arguments" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    _ = try rt.resources.add(try R.Resource.create(gpa, struct {}, .{}));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///core-io-errors.js",
        \\const c = Deno.core, b = new Uint8Array(2);
        \\class Unsupported extends Error {}
        \\c.registerErrorClass('NotSupported', Unsupported);
        \\for (const operation of [() => c.readSync(0,b), () => c.writeSync(0,b),
        \\  () => c.read(0,b), () => c.readAll(0), () => c.write(0,b), () => c.writeAll(0,b), () => c.shutdown(0)]) {
        \\  let caught = false;
        \\  try { await operation(); } catch (e) {
        \\    caught = e instanceof Unsupported && e.message === 'The operation is not supported';
        \\  }
        \\  if (!caught) throw new Error('unsupported I/O did not use registered class');
        \\}
        \\for (const operation of [() => c.readSync(99,b), () => c.writeSync(99,b),
        \\  () => c.read(99,b), () => c.readAll(99), () => c.write(99,b), () => c.writeAll(99,b), () => c.shutdown(99)]) {
        \\  let caught = false;
        \\  try { await operation(); } catch (e) { caught = e instanceof c.BadResource; }
        \\  if (!caught) throw new Error('bad RID');
        \\}
        \\try { await c.read(0,new Uint16Array(2)); throw new Error('wrong buffer accepted'); }
        \\catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\await c.writeAll(0,new Uint8Array(0));
    , &exception);
}

test "destroying a runtime cancels blocked resource I/O before final release" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    AsyncGateTest.gate.reset();
    AsyncGateTest.entered.reset();
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, io, .{});
    errdefer rt.destroy(gpa);
    const file = try tmp.dir.createFile(io, "blocked", .{ .read = true });
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = file, .io = io, .drops = &drops }));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    _ = try rt.executeScript(gpa, "blocked-resource.js",
        \\Deno.core.read(0, new Uint8Array(8));
        \\Deno.core.readAll(0);
        \\Deno.core.close(0);
    , &exception);
    try AsyncGateTest.entered.wait(io);
    try std.testing.expectEqual(@as(usize, 0), drops);
    rt.destroy(gpa);
    try std.testing.expectEqual(@as(usize, 1), drops);
}

test "core read-all returns large and empty owned buffers after RID closure" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, 200123);
    defer gpa.free(data);
    for (data, 0..) |*byte, i| byte.* = @intCast(i % 251);
    try tmp.dir.writeFile(io, .{ .sub_path = "read-all", .data = data });
    AsyncGateTest.gate.reset();
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, io, .{ .ops = &.{ops.op("op_test_release", AsyncGateTest.release)} });
    defer rt.destroy(gpa);
    const file = try tmp.dir.openFile(io, "read-all", .{});
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = file, .io = io, .drops = &drops }));
    const empty = try tmp.dir.openFile(io, "read-all", .{});
    _ = try rt.resources.add(try R.Resource.create(gpa, ResourceIoTest, .{ .file = empty, .io = io, .drops = &drops, .read_offset = data.len }));
    const Failure = struct {
        offset: usize = 0,
        pub fn read(self: *@This(), _: std.Io, bytes: []u8) !usize {
            if (self.offset > 0) return error.ReadFailure;
            bytes[0] = 42;
            self.offset += 1;
            return 1;
        }
    };
    _ = try rt.resources.add(try R.Resource.create(gpa, Failure, .{}));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///core-read-all.js",
        \\import { op_read_all } from 'ext:core/ops';
        \\const c = Deno.core, U8 = Uint8Array;
        \\const pending = op_read_all(0), emptyPending = c.readAll(1);
        \\c.close(0); c.close(1);
        \\globalThis.Uint8Array = () => { throw new Error('poisoned constructor'); };
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\const result = await pending, empty = await emptyPending;
        \\globalThis.Uint8Array = U8;
        \\if (!(result instanceof U8) || result.length !== 200123 || result.byteOffset !== 0 || result.buffer.byteLength !== result.length) throw new Error('result shape');
        \\for (let i=0; i<result.length; ++i) if (result[i] !== i%251) throw new Error(`byte ${i}`);
        \\if (!(empty instanceof U8) || empty.length !== 0 || empty.buffer.byteLength !== 0) throw new Error('empty result');
        \\try { await c.readAll(2); throw new Error('partial failure ignored'); }
        \\catch (e) { if (e.message !== 'ReadFailure') throw e; }
        \\c.close(2);
        \\// Job arenas and native result owners have been released; JS still owns data.
        \\await c.ops.op_void_async_deferred();
        \\if (result[200122] !== 200122%251) throw new Error('result lifetime');
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), drops);
    try std.testing.expectEqual(@as(usize, 0), rt.resources.len());
}

test "core read and read-all consume chunk-owned resources without a BYOB method" {
    v8.initForTesting();
    const R = @import("resources.zig");
    const ChunkSource = struct {
        pending: R.ByteView,
        mutex: std.Io.Mutex = .init,
        drops: *usize,
        pub fn readChunk(self: *@This(), io: std.Io, _: std.mem.Allocator, limit: usize) !R.ByteView {
            try AsyncGateTest.gate.wait(io);
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.pending.splitTo(@min(limit, self.pending.len(), 3));
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.pending.deinit();
            self.drops.* += 1;
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    AsyncGateTest.gate.reset();
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, io, .{ .ops = &.{ops.op("op_test_release", AsyncGateTest.release)} });
    defer rt.destroy(gpa);
    const resource = owned: {
        var source = try R.ByteView.copy(gpa, "source-owned bytes");
        errdefer source.deinit();
        break :owned try R.Resource.create(gpa, ChunkSource, .{ .pending = source, .drops = &drops });
    };
    _ = try rt.resources.add(resource);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///chunk-owned-reader.js",
        \\const c = Deno.core, data = new Uint8Array(8);
        \\const pending = c.read(0, data.subarray(2,6));
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\if (await pending !== 3 || data.join() !== '0,0,115,111,117,0,0,0') throw new Error('chunk BYOB range');
        \\const rest = c.readAll(0);
        \\c.close(0);
        \\if (String.fromCharCode(...await rest) !== 'rce-owned bytes') throw new Error('chunk read-all');
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), drops);
}

test "worker-owned native byte results keep their original allocation in V8" {
    v8.initForTesting();
    const B = @import("buffers.zig");
    const a = @import("async_ops.zig");
    const F = struct {
        var address: usize = 0;
        fn allocate() !B.JsBuffer {
            const bytes = try std.heap.smp_allocator.dupe(u8, "native owned bytes");
            address = @intFromPtr(bytes.ptr);
            return B.JsBuffer.fromOwnedSlice(bytes);
        }
        fn sameAllocation(buffer: B.JsBuffer) !bool {
            return @intFromPtr((try buffer.bytes()).ptr) == address;
        }
    };
    const gpa = std.testing.allocator;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        a.decl("op_allocate_bytes", F.allocate, .{}), ops.op("op_same_allocation", F.sameAllocation),
    } });
    defer rt.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///owned-native-bytes.js",
        \\const c = Deno.core, result = await c.ops.op_allocate_bytes();
        \\if (!c.ops.op_same_allocation(result) || result.length !== 18) throw new Error('copied bytes');
        \\await c.ops.op_void_async_deferred();
        \\if (String.fromCharCode(...result) !== 'native owned bytes') throw new Error('released result');
    , &exception);
}

test "native-owned buffer storage survives isolate disposal and rewrapping" {
    v8.initForTesting();
    const B = @import("buffers.zig");
    const gpa = std.testing.allocator;
    const bytes = try std.heap.smp_allocator.dupe(u8, "owned across isolates");
    var buffer = B.JsBuffer.fromOwnedSlice(bytes);
    defer buffer.deinit();
    try std.testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr((try buffer.bytes()).ptr));
    {
        const rt = try JsRuntime.create(gpa, std.testing.io, .{});
        defer rt.destroy(gpa);
        const scope: ops.Scope = .{ .runtime = rt, .isolate = rt.isolate(), .context = rt.context, .arena = gpa };
        try v8.setProperty(rt.isolate(), rt.context, v8.c.v8__Context__Global(rt.context), "nativeBytes", try buffer.toV8(scope));
    }
    try std.testing.expectEqualStrings("owned across isolates", try buffer.bytes());
    const rt = try JsRuntime.create(gpa, std.testing.io, .{});
    defer rt.destroy(gpa);
    const scope: ops.Scope = .{ .runtime = rt, .isolate = rt.isolate(), .context = rt.context, .arena = gpa };
    try v8.setProperty(rt.isolate(), rt.context, v8.c.v8__Context__Global(rt.context), "nativeBytes", try buffer.toV8(scope));
    buffer.deinit();
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    _ = try rt.executeScript(gpa, "owned-second-isolate.js",
        \\if (String.fromCharCode(...nativeBytes) !== 'owned across isolates') throw new Error('lost native owner');
    , &exception);
}

test "async I/O retains resource and detached buffer until completion" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const B = @import("buffers.zig");
    const R = @import("resources.zig");
    const FileResource = struct {
        file: std.Io.File,
        io: std.Io,
        drops: *usize,
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.file.close(self.io);
            self.drops.* += 1;
        }
    };
    const F = struct {
        fn read(scope: a.AsyncScope, resource: R.ResourceRef(FileResource), buffer: B.JsBuffer) !B.JsBuffer {
            try AsyncGateTest.gate.wait(scope.io);
            const bytes = try buffer.bytes();
            _ = try resource.ptr().file.readPositionalAll(scope.io, bytes, 0);
            return buffer.clone();
        }
    };
    AsyncGateTest.gate.reset();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "retained.txt", .data = "retained" });
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, io, .{ .ops = &.{
        a.decl("op_read_retained", F.read, .{}), ops.op("op_test_release", AsyncGateTest.release), ops.op("op_detach_buffer", BufferBindingTest.detach),
    } });
    defer rt.destroy(gpa);
    const file = try tmp.dir.openFile(io, "retained.txt", .{});
    _ = try rt.resources.add(try R.Resource.create(gpa, FileResource, .{ .file = file, .io = io, .drops = &drops }));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    rt.executeMainModule(gpa, "file:///buffer-retained-io.js",
        \\const c = Deno.core;
        \\const storage = new ArrayBuffer(12), view = new Uint8Array(storage,2,8);
        \\const pending = c.ops.op_read_retained(0, view);
        \\c.close(0);
        \\c.ops.op_detach_buffer(storage);
        \\if (view.length !== 0) throw new Error('detach failed');
        \\c.createTimer(() => c.ops.op_test_release(), 1, undefined, false, true, false);
        \\const result = await pending;
        \\if (result.byteOffset !== 2 || result.length !== 8 || result.join() !== '114,101,116,97,105,110,101,100') throw new Error('retained I/O bytes');
    , &exception) catch |err| {
        std.debug.print("{s}\n", .{exception orelse @errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), drops);
    try std.testing.expectEqual(@as(usize, 0), rt.resources.len());
}

test "managed resource arguments clean up partial conversion failures" {
    v8.initForTesting();
    const a = @import("async_ops.zig");
    const B = @import("buffers.zig");
    const R = @import("resources.zig");
    const Tracked = struct {
        drops: *usize,
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.drops.* += 1;
        }
    };
    const F = struct {
        fn use(_: R.ResourceRef(Tracked), buffer: B.JsBuffer) u32 {
            return @intCast(buffer.len);
        }
    };
    const gpa = std.testing.allocator;
    var drops: usize = 0;
    const rt = try JsRuntime.create(gpa, std.testing.io, .{ .ops = &.{
        ops.op("op_use_resource_sync", F.use), a.decl("op_use_resource_async", F.use, .{}),
    } });
    defer rt.destroy(gpa);
    _ = try rt.resources.add(try R.Resource.create(gpa, Tracked, .{ .drops = &drops }));
    _ = try rt.resources.add(try R.Resource.create(gpa, struct {}, .{}));
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    try rt.executeMainModule(gpa, "file:///resource-binding-errors.js",
        \\const c = Deno.core;
        \\for (const op of [c.ops.op_use_resource_sync, c.ops.op_use_resource_async]) {
        \\  try { await op(0, new Uint16Array(1)); throw new Error('invalid buffer accepted'); }
        \\  catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\  for (const rid of [1, 999]) {
        \\    try { await op(rid, new Uint8Array(0)); throw new Error('wrong resource accepted'); }
        \\    catch (e) { if (!(e instanceof c.BadResource) || e.message !== 'Bad resource ID') throw e; }
        \\  }
        \\}
        \\c.close(0); c.close(1);
    , &exception);
    try std.testing.expectEqual(@as(usize, 1), drops);
    try std.testing.expectEqual(@as(usize, 0), rt.async_driver.jobs.count());
}

test "retained backing stores and their allocator survive isolate disposal" {
    v8.initForTesting();
    const B = @import("buffers.zig");
    const gpa = std.testing.allocator;
    const first = try JsRuntime.create(gpa, std.testing.io, .{});
    var first_alive = true;
    defer if (first_alive) first.destroy(gpa);
    var exception: ?[]u8 = null;
    defer if (exception) |e| gpa.free(e);
    const value = try first.executeScript(gpa, "retain.js", "new Uint8Array([1,2,3,4]).subarray(1,3)", &exception);
    var retained = try B.JsBuffer.fromV8(.{ .runtime = first, .isolate = first.isolate(), .context = first.context, .arena = gpa }, value);
    defer retained.deinit();
    first.destroy(gpa);
    first_alive = false;
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, try retained.bytes());
    const second = try JsRuntime.create(gpa, std.testing.io, .{});
    defer second.destroy(gpa);
    const restored = try retained.toV8(.{ .runtime = second, .isolate = second.isolate(), .context = second.context, .arena = gpa });
    try v8.setProperty(second.isolate(), second.context, v8.c.v8__Context__Global(second.context), "restoredBuffer", restored);
    retained.deinit();
    _ = try second.executeScript(gpa, "restore.js",
        \\if (restoredBuffer.byteOffset !== 1 || restoredBuffer.join() !== '2,3') throw new Error('cross-isolate backing store');
        \\restoredBuffer[0] = 42;
    , &exception);
}
