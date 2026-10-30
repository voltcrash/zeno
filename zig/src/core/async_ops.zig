// Copyright 2018-2026 the Deno authors. MIT license.
//! Async-op submission and completion, ported from runtime/op_driver.
//! Worker bodies receive only native arguments; V8 stays on the runtime thread.
const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const ops = @import("ops.zig");
const JsRuntime = @import("runtime.zig").JsRuntime;
const errors = @import("errors.zig");

pub const Scheduling = enum { eager, deferred, lazy };
/// inline_ready bodies must be nonblocking; they model already-ready Rust
/// futures. Concurrent bodies use std.Io and never receive V8 handles.
pub const Execution = enum { inline_ready, concurrent };
pub const Options = struct { scheduling: Scheduling = .eager, execution: Execution = .concurrent };
pub const AsyncScope = @import("io_scope.zig").IoScope;
const Mapped = struct { value: *const v8.Value, is_ok: bool };
const Job = struct {
    driver: *Driver,
    promise_id: i32,
    execution: Execution,
    started: bool = false,
    refed: bool = true,
    next: ?*Job = null,
    start_error: ?anyerror = null,
    future: ?std.Io.Future(void) = null,
    run: *const fn (*Job) void,
    complete: *const fn (*Job) void,
    map: *const fn (*Job, *JsRuntime) v8.Error!Mapped,
    destroy: *const fn (*Job) void,
};

pub const Driver = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    jobs: std.AutoHashMapUnmanaged(i32, *Job) = .empty,
    refed_count: usize = 0,
    unstarted_count: usize = 0,
    mutex: std.Io.Mutex = .init,
    ready_head: ?*Job = null,
    ready_tail: ?*Job = null,
    wake: std.Io.Event = .unset,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Driver {
        return .{ .gpa = gpa, .io = io };
    }

    /// Join/cancel every worker before freeing any queued node: late worker
    /// completions may still link through the queue's tail during cancellation.
    pub fn deinit(self: *Driver) void {
        var running = self.jobs.valueIterator();
        while (running.next()) |job| if (job.*.future) |*future| future.cancel(self.io);
        self.ready_head = null;
        self.ready_tail = null;
        var it = self.jobs.valueIterator();
        while (it.next()) |job| job.*.destroy(job.*);
        self.jobs.deinit(self.gpa);
    }

    fn enqueue(self: *Driver, job: *Job) void {
        self.mutex.lockUncancelable(self.io);
        if (self.ready_tail) |tail| tail.next = job else self.ready_head = job;
        self.ready_tail = job;
        self.mutex.unlock(self.io);
        self.wake.set(self.io);
    }

    fn worker(job: *Job) void {
        const driver = job.driver;
        job.run(job);
        // Results are published before the future returns. The consumer joins
        // the future before freeing this node, including during cancellation.
        driver.enqueue(job);
    }

    fn start(self: *Driver, job: *Job) void {
        std.debug.assert(!job.started);
        job.started = true;
        self.unstarted_count -= 1;
        if (job.execution == .inline_ready) {
            worker(job);
        } else {
            job.future = self.io.concurrent(worker, .{job}) catch |err| {
                job.start_error = err;
                self.enqueue(job);
                return;
            };
        }
    }

    /// Consumes job, including on insertion failure. Lazy work starts at the
    /// first event-loop poll; deferred inline work runs now but delivers later.
    fn submit(self: *Driver, job: *Job, scheduling: Scheduling) !void {
        errdefer job.destroy(job);
        if (self.jobs.contains(job.promise_id)) return error.DuplicatePromiseId;
        try self.jobs.put(self.gpa, job.promise_id, job);
        self.refed_count += 1;
        self.unstarted_count += 1;
        if (scheduling != .lazy) self.start(job);
    }

    pub fn setRef(self: *Driver, id: i32, refed: bool) void {
        const job = self.jobs.get(id) orelse return;
        if (job.refed == refed) return;
        job.refed = refed;
        if (refed) self.refed_count += 1 else self.refed_count -= 1;
    }

    /// Runtime-thread cancellation for resource-specific shutdown. The
    /// completion still travels through the normal promise/error mapping.
    pub fn cancel(self: *Driver, id: i32) void {
        const job = self.jobs.get(id) orelse return;
        if (job.future) |*future| future.cancel(self.io);
    }

    fn pop(self: *Driver) ?*Job {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = self.ready_head orelse return null;
        self.ready_head = job.next;
        if (self.ready_head == null) self.ready_tail = null;
        job.next = null;
        return job;
    }

    pub fn dispatchReady(self: *Driver, rt: *JsRuntime, callback: *const c.Function) v8.Error!bool {
        var it = self.jobs.valueIterator();
        while (it.next()) |job| if (!job.*.started) self.start(job.*);
        var did_work = false;
        while (self.pop()) |job| {
            did_work = true;
            if (job.future) |*future| future.await(self.io);
            _ = self.jobs.remove(job.promise_id);
            if (job.refed) self.refed_count -= 1;
            defer job.destroy(job);
            var scope: v8.HandleScope = undefined;
            scope.init(rt.isolate());
            defer scope.deinit();
            job.complete(job);
            const mapped = if (job.start_error) |err| Mapped{
                .is_ok = false,
                .value = try ops.errorValue(.{ .runtime = rt, .isolate = rt.isolate(), .context = rt.context, .arena = rt.gpa }, err),
            } else try job.map(job, rt);
            const args = [_]*const v8.Value{
                @ptrCast(c.v8__Integer__New(rt.isolate(), job.promise_id)),
                @ptrCast(c.v8__Boolean__New(rt.isolate(), mapped.is_ok)),
                mapped.value,
            };
            _ = c.v8__Function__Call(callback, rt.context, @ptrCast(c.v8__Undefined(rt.isolate())), 3, &args) orelse return error.JsException;
        }
        return did_work;
    }

    pub fn wait(self: *Driver, timeout: std.Io.Timeout) void {
        self.wake.reset();
        self.mutex.lockUncancelable(self.io);
        const ready = self.ready_head != null;
        self.mutex.unlock(self.io);
        // Microtasks may submit lazy jobs after dispatchReady. Return to the
        // next poll before waiting for a worker that has not been started.
        if (!ready and self.unstarted_count == 0) self.wake.waitTimeout(self.io, timeout) catch {};
    }
};

pub fn decl(comptime name: []const u8, comptime function: anytype, comptime options: Options) ops.OpDecl {
    const C = Callback(function, options);
    return .{ .name = name, .callback = C.call, .arg_count = C.js_params.len + 1, .is_async = true };
}

fn Callback(comptime function: anytype, comptime options: Options) type {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    const takes_scope = info.param_types.len > 0 and info.param_types[0].? == AsyncScope;
    const Ret = info.return_type.?;
    const Value = if (@typeInfo(Ret) == .error_union) @typeInfo(Ret).error_union.payload else Ret;
    if (comptime Value != void and Value != bool and Value != i32 and Value != u32 and Value != f64 and Value != []const u8 and Value != []u8 and !ops.isBuffer(Value))
        @compileError("async op results must be native scalar/string/buffer/void values");
    return struct {
        pub const js_params = info.param_types[@intFromBool(takes_scope)..];
        const Data = struct {
            header: Job,
            arena: std.heap.ArenaAllocator,
            args: std.meta.ArgsTuple(@TypeOf(function)),
            result: Ret = undefined,
            initialized: usize = 0,
            result_ready: bool = false,
            error_context: errors.Context = .{},
        };
        fn data(job: *Job) *Data {
            return @alignCast(@fieldParentPtr("header", job));
        }
        fn run(job: *Job) void {
            const d = data(job);
            d.result = @call(.auto, function, d.args);
            d.result_ready = true;
        }
        fn complete(job: *Job) void {
            const d = data(job);
            inline for (js_params, 0..) |T, i| {
                if (comptime ops.isAsyncArg(T.?)) {
                    if (@hasDecl(T.?, "beforeResolve")) {
                        if (i < d.initialized) d.args[i + @intFromBool(takes_scope)].beforeResolve();
                    }
                }
            }
        }
        fn destroy(job: *Job) void {
            const d = data(job);
            const gpa = job.driver.gpa;
            if (d.result_ready) {
                if (@typeInfo(Ret) == .error_union) {
                    if (d.result) |value| ops.releaseArg(@TypeOf(value), value) else |_| {}
                } else ops.releaseArg(Ret, d.result);
            }
            inline for (js_params, 0..) |T, i| {
                if (i < d.initialized) ops.releaseArg(T.?, d.args[i + @intFromBool(takes_scope)]);
            }
            d.arena.deinit();
            gpa.destroy(d);
        }
        fn map(job: *Job, rt: *JsRuntime) v8.Error!Mapped {
            const d = data(job);
            const scope: ops.Scope = .{ .runtime = rt, .isolate = rt.isolate(), .context = rt.context, .arena = d.arena.allocator(), .error_context = &d.error_context };
            const value = if (@typeInfo(Ret) == .error_union) d.result catch |err| return .{
                .is_ok = false,
                .value = try ops.errorValue(scope, err),
            } else d.result;
            // Rust's unit mapping is null, leaving undefined as the pending sentinel.
            return .{ .is_ok = true, .value = if (@TypeOf(value) == void) @ptrCast(c.v8__Null(rt.isolate())) else (try ops.toV8(scope, value)).? };
        }
        fn prepare(rt: *JsRuntime, cb: *const v8.FunctionCallbackInfo) !?*const v8.Value {
            const driver = &rt.async_driver;
            const d = try rt.gpa.create(Data);
            d.* = .{
                .header = .{ .driver = driver, .promise_id = 0, .execution = options.execution, .run = run, .complete = complete, .map = map, .destroy = destroy },
                // Workers never allocate through the runtime's potentially
                // single-threaded allocator. Each arena changes owners once.
                .arena = .init(std.heap.smp_allocator),
                .args = undefined,
            };
            var transferred = false;
            defer if (!transferred) destroy(&d.header);
            var scope: ops.Scope = .{ .runtime = rt, .isolate = rt.isolate(), .context = rt.context, .arena = d.arena.allocator(), .error_context = &d.error_context };
            d.header.promise_id = try ops.fromV8(i32, scope, c.v8__FunctionCallbackInfo__Get(cb, 0));
            // Reject active IDs before argument setup can replace a cancel
            // registration belonging to an existing operation.
            if (driver.jobs.contains(d.header.promise_id)) return error.DuplicatePromiseId;
            scope.promise_id = d.header.promise_id;
            if (takes_scope) d.args[0] = .{ .io = rt.io, .allocator = d.arena.allocator(), .error_context = &d.error_context };
            inline for (js_params, 0..) |T, i| {
                if (comptime T.? != bool and T.? != i32 and T.? != u32 and T.? != f64 and T.? != []const u8 and !ops.isBuffer(T.?) and !ops.isResource(T.?) and !ops.isAsyncArg(T.?))
                    @compileError("async op arguments must be native scalars, strings, buffers, resources or async arguments");
                d.args[i + @intFromBool(takes_scope)] = try ops.fromV8(T.?, scope, c.v8__FunctionCallbackInfo__Get(cb, @intCast(i + 1)));
                d.initialized += 1;
            }
            if (options.execution == .inline_ready and options.scheduling == .eager) {
                run(&d.header);
                complete(&d.header);
                const mapped = try map(&d.header, rt);
                if (!mapped.is_ok) {
                    _ = c.v8__Isolate__ThrowException(rt.isolate(), mapped.value);
                    return error.JsException;
                }
                return mapped.value;
            }
            transferred = true;
            try driver.submit(&d.header, options.scheduling);
            return null;
        }
        fn call(cb: *const v8.FunctionCallbackInfo) callconv(.c) void {
            const rt = JsRuntime.fromIsolate(c.v8__FunctionCallbackInfo__GetIsolate(cb));
            const value = prepare(rt, cb) catch |err| {
                const scope: ops.Scope = .{ .runtime = rt, .isolate = rt.isolate(), .context = rt.context, .arena = rt.gpa };
                ops.throwError(scope, err);
                return;
            };
            if (value) |v| {
                var rv = c.v8__FunctionCallbackInfo__GetReturnValue(cb);
                c.v8__ReturnValue__Value__Set(&rv, v);
            }
        }
    };
}
