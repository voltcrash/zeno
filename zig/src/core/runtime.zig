// Copyright 2018-2026 the Deno authors. MIT license.
//! The JavaScript runtime: an isolate with one context. This is the start
//! of the port of `JsRuntime` from `libs/core`; ops, modules and the event
//! loop come later.

const std = @import("std");
const v8 = @import("../v8/v8.zig");

pub const JsRuntime = struct {
    owned: v8.OwnedIsolate,
    /// Keeps the context handle alive for the runtime's lifetime.
    scope: v8.HandleScope,
    context: *const v8.Context,
    io: std.Io,

    /// Create a runtime. `v8.Platform.init` must have been called. The
    /// runtime must stay at a stable address, so it's heap-allocated.
    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*JsRuntime {
        const self = try gpa.create(JsRuntime);
        self.owned = .init();
        self.io = io;
        self.scope.init(self.owned.isolate);
        self.context = v8.newContext(self.owned.isolate);
        v8.c.v8__Context__Enter(self.context);
        try self.installTemporaryConsole();
        return self;
    }

    pub fn destroy(self: *JsRuntime, gpa: std.mem.Allocator) void {
        v8.c.v8__Context__Exit(self.context);
        self.scope.deinit();
        self.owned.deinit();
        gpa.destroy(self);
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
    const rt = try JsRuntime.create(gpa, std.testing.io);
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
