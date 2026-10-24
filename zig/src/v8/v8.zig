// Copyright 2018-2026 the Deno authors. MIT license.
//! A thin Zig layer over V8, through the C ABI of the prebuilt rusty_v8
//! archive (see `c.zig`). The equivalent of the `v8` crate that the Rust
//! implementation uses.

const std = @import("std");
pub const c = @import("c.zig");

comptime {
    _ = @import("rust_symbols.zig");
}

pub const Isolate = c.Isolate;
pub const Context = c.Context;
pub const Value = c.Value;
pub const String = c.String;
pub const Object = c.Object;
pub const FunctionCallbackInfo = c.FunctionCallbackInfo;
pub const FunctionCallback = c.FunctionCallback;

/// V8 flags always set, from `v8_init` in `libs/core/runtime/setup.rs`.
///
/// The one difference: Deno enables Temporal (`--harmony-temporal`), but V8
/// implements it on top of `temporal_rs`, a Rust crate that the prebuilt
/// archive expects the embedder to link. It stays off until the port
/// provides that API (see `rust_symbols.zig`).
const default_flags = "--no-validate-asm" ++
    " --turbo_fast_api_calls" ++
    " --no-harmony-temporal" ++
    " --js-float16array" ++
    " --js-explicit-resource-management" ++
    " --js-source-phase-imports" ++
    " --js-defer-import-eval" ++
    // Installs a native `queueMicrotask` on the global object, used by
    // `queueMicrotask` in `01_core.js`.
    " --enable-queue-microtask";

pub fn version() []const u8 {
    return std.mem.span(c.v8__V8__GetVersion());
}

/// Process-wide V8 state: the platform. Initialize once, before creating
/// any isolate.
pub const Platform = struct {
    raw: *c.Platform,

    pub fn init(extra_flags: []const u8) Platform {
        c.v8__V8__SetFlagsFromString(default_flags, default_flags.len);
        if (extra_flags.len > 0) c.v8__V8__SetFlagsFromString(extra_flags.ptr, extra_flags.len);
        const raw = c.v8__Platform__NewDefaultPlatform(0, false);
        c.v8__V8__InitializePlatform(raw);
        c.v8__V8__Initialize();
        return .{ .raw = raw };
    }

    pub fn deinit(self: Platform) void {
        _ = c.v8__V8__Dispose();
        c.v8__V8__DisposePlatform();
        c.v8__Platform__DELETE(self.raw);
    }

    /// Run pending platform tasks for `isolate`. Returns whether any ran.
    pub fn pumpMessageLoop(self: Platform, isolate: *Isolate, wait_for_work: bool) bool {
        return c.v8__Platform__PumpMessageLoop(self.raw, isolate, wait_for_work);
    }
};

var testing_platform: ?Platform = null;

/// Initialize V8 for unit tests, once per process. Never torn down.
pub fn initForTesting() void {
    if (testing_platform == null) testing_platform = .init("");
}

/// `v8::Isolate::CreateParams`, mirroring the layout in rusty_v8's
/// `isolate_create_params.rs`.
const CreateParams = extern struct {
    code_event_handler: ?*const anyopaque,
    constraints: [7]usize,
    snapshot_blob: ?*const anyopaque,
    counter_lookup_callback: ?*const anyopaque,
    create_histogram_callback: ?*const anyopaque,
    add_histogram_sample_callback: ?*const anyopaque,
    array_buffer_allocator: ?*c.ArrayBufferAllocator,
    array_buffer_allocator_shared: [2]usize,
    external_references: ?*const isize,
    allow_atomics_wait: bool,
    fatal_error_handler: ?*const anyopaque,
    oom_error_handler: ?*const anyopaque,
    cpp_heap: ?*const anyopaque,
};

/// An isolate together with its array buffer allocator. Entered on
/// creation; `deinit` exits and disposes it.
pub const OwnedIsolate = struct {
    isolate: *Isolate,
    allocator: *c.ArrayBufferAllocator,

    pub fn init() OwnedIsolate {
        std.debug.assert(c.v8__Isolate__CreateParams__SIZEOF() == @sizeOf(CreateParams));
        var params: CreateParams = undefined;
        c.v8__Isolate__CreateParams__CONSTRUCT(&params);
        const allocator = c.v8__ArrayBuffer__Allocator__NewDefaultAllocator();
        params.array_buffer_allocator = allocator;
        const isolate = c.v8__Isolate__New(&params);
        c.v8__Isolate__Enter(isolate);
        return .{ .isolate = isolate, .allocator = allocator };
    }

    pub fn deinit(self: OwnedIsolate) void {
        c.v8__Isolate__Exit(self.isolate);
        c.v8__Isolate__Dispose(self.isolate);
        c.v8__ArrayBuffer__Allocator__DELETE(self.allocator);
    }
};

/// `v8::HandleScope`. Must not be moved after `init`.
pub const HandleScope = struct {
    raw: c.HandleScope,

    pub fn init(self: *HandleScope, isolate: *Isolate) void {
        c.v8__HandleScope__CONSTRUCT(&self.raw, isolate);
    }

    pub fn deinit(self: *HandleScope) void {
        c.v8__HandleScope__DESTRUCT(&self.raw);
    }
};

/// `v8::TryCatch`. Must not be moved after `init`.
pub const TryCatch = struct {
    raw: c.TryCatch,

    pub fn init(self: *TryCatch, isolate: *Isolate) void {
        c.v8__TryCatch__CONSTRUCT(&self.raw, isolate);
    }

    pub fn deinit(self: *TryCatch) void {
        c.v8__TryCatch__DESTRUCT(&self.raw);
    }

    pub fn hasCaught(self: *const TryCatch) bool {
        return c.v8__TryCatch__HasCaught(&self.raw);
    }

    pub fn exception(self: *const TryCatch) ?*const Value {
        return c.v8__TryCatch__Exception(&self.raw);
    }

    pub fn stackTrace(self: *const TryCatch, context: *const Context) ?*const Value {
        return c.v8__TryCatch__StackTrace(&self.raw, context);
    }
};

/// A `v8::Global`: a handle that outlives handle scopes. Call `deinit` to
/// release it.
pub fn Global(comptime T: type) type {
    return struct {
        const Self = @This();
        data: *const c.Data,

        pub fn init(isolate: *Isolate, value: *const T) Self {
            return .{ .data = c.v8__Global__New(isolate, @ptrCast(value)) };
        }

        /// A local handle to the value, in the current handle scope.
        pub fn get(self: Self, isolate: *Isolate) *const T {
            return @ptrCast(c.v8__Local__New(isolate, self.data));
        }

        pub fn deinit(self: Self) void {
            c.v8__Global__Reset(self.data);
        }
    };
}

pub fn newContext(isolate: *Isolate) *const Context {
    return c.v8__Context__New(isolate, null, null, null);
}

pub const Error = error{ OutOfMemory, JsException };

/// Create a V8 string from UTF-8.
pub fn newString(isolate: *Isolate, s: []const u8) Error!*const String {
    const len = std.math.cast(c_int, s.len) orelse return error.OutOfMemory;
    return c.v8__String__NewFromUtf8(isolate, s.ptr, .normal, len) orelse error.OutOfMemory;
}

/// Convert a value to a string (like `String(value)`) and copy it out as
/// UTF-8. Fails with `error.JsException` if the conversion throws.
pub fn toUtf8(gpa: std.mem.Allocator, isolate: *Isolate, context: *const Context, value: *const Value) Error![]u8 {
    const s = c.v8__Value__ToString(value, context) orelse return error.JsException;
    const len: usize = @intCast(c.v8__String__Utf8Length(s, isolate));
    const buf = try gpa.alloc(u8, len);
    const written = c.v8__String__WriteUtf8_v2(s, isolate, buf.ptr, buf.len, 0, null);
    std.debug.assert(written == len);
    return buf;
}

/// Set `object[name] = value`.
pub fn setProperty(isolate: *Isolate, context: *const Context, object: *const Object, name: []const u8, value: *const Value) Error!void {
    const key = try newString(isolate, name);
    if (c.v8__Object__Set(object, context, @ptrCast(key), value) != .just_true) return error.JsException;
}

/// Get `object[name]`.
pub fn getProperty(isolate: *Isolate, context: *const Context, object: *const Object, name: []const u8) Error!*const Value {
    const key = try newString(isolate, name);
    return c.v8__Object__Get(object, context, @ptrCast(key)) orelse error.JsException;
}

/// Create a function backed by a native callback.
pub fn newFunction(context: *const Context, callback: FunctionCallback) Error!*const c.Function {
    return c.v8__Function__New(context, callback, null, 0, .throw, .has_side_effect) orelse error.JsException;
}

/// Compile and run a classic script. On an exception, returns
/// `error.JsException` with the exception left in `try_catch`.
pub fn runScript(isolate: *Isolate, context: *const Context, name: []const u8, source: []const u8) Error!*const Value {
    var origin: c.ScriptOrigin = undefined;
    const resource_name = try newString(isolate, name);
    c.v8__ScriptOrigin__CONSTRUCT(&origin, @ptrCast(resource_name), 0, 0, false, -1, null, false, false, false, null);
    const src = try newString(isolate, source);
    const script = c.v8__Script__Compile(context, src, &origin) orelse return error.JsException;
    return c.v8__Script__Run(script, context) orelse error.JsException;
}

test "the version printed by `deno --version` is the linked V8" {
    try std.testing.expectEqualStrings(@import("../version.zig").v8, version());
}
