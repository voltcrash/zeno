// Copyright 2018-2026 the Deno authors. MIT license.
//! Retained byte ranges from op2's to_v8_slice/to_v8_slice_buffer/any.
//! These contain native shared backing-store ownership, never V8 local handles.
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const ops = @import("ops.zig");

pub const Mode = enum { typed_u8, array_buffer, any };
pub const JsBuffer = Buffer(.typed_u8);
pub const ArrayBuffer = Buffer(.array_buffer);
pub const AnyBuffer = Buffer(.any);

/// Op arguments are borrowed by the body. Clone to keep/return a new owner;
/// the binding releases argument owners and owned results after conversion.
pub fn Buffer(comptime mode: Mode) type {
    return struct {
        pub const is_op_buffer = true;
        const Self = @This();
        store: c.SharedBackingStore,
        offset: usize,
        len: usize,

        pub fn fromV8(scope: ops.Scope, value: *const v8.Value) ops.ConvertError!Self {
            var buffer: *const c.ArrayBuffer = undefined;
            var offset: usize = 0;
            var len: usize = 0;
            if (mode == .typed_u8 and !c.v8__Value__IsUint8Array(value)) return fail(scope, "expected typed ArrayBufferView");
            if (mode != .array_buffer and c.v8__Value__IsArrayBufferView(value)) {
                const view: *const c.ArrayBufferView = @ptrCast(value);
                buffer = c.v8__ArrayBufferView__Buffer(view) orelse return fail(scope, "buffer missing");
                offset = c.v8__ArrayBufferView__ByteOffset(view);
                len = c.v8__ArrayBufferView__ByteLength(view);
            } else if (c.v8__Value__IsArrayBuffer(value)) {
                buffer = @ptrCast(value);
                len = c.v8__ArrayBuffer__ByteLength(buffer);
            } else {
                return fail(scope, if (mode == .array_buffer) "expected ArrayBuffer" else "expected ArrayBuffer or ArrayBufferView");
            }
            var result: Self = .{ .store = c.v8__ArrayBuffer__GetBackingStore(buffer), .offset = offset, .len = len };
            errdefer result.deinit();
            _ = result.bytes() catch return fail(scope, "buffer range is out of bounds");
            return result;
        }

        pub fn clone(self: Self) Self {
            return .{ .store = c.std__shared_ptr__v8__BackingStore__COPY(&self.store), .offset = self.offset, .len = self.len };
        }

        pub fn deinit(self: *Self) void {
            c.std__shared_ptr__v8__BackingStore__reset(&self.store);
        }

        pub fn bytes(self: Self) error{ BufferClosed, BufferOutOfBounds }![]u8 {
            const store = c.std__shared_ptr__v8__BackingStore__get(&self.store) orelse return error.BufferClosed;
            const size = c.v8__BackingStore__ByteLength(store);
            if (self.offset > size or self.len > size - self.offset) return error.BufferOutOfBounds;
            if (self.len == 0) return &.{};
            const ptr: [*]u8 = @ptrCast(c.v8__BackingStore__Data(store) orelse return error.BufferOutOfBounds);
            return ptr[self.offset..][0..self.len];
        }

        /// Recreate a Uint8Array over the retained range. A new JS owner keeps
        /// storage alive after the native arguments/results are released.
        pub fn toV8(self: Self, scope: ops.Scope) ops.ConvertError!*const v8.Value {
            _ = self.bytes() catch return fail(scope, "buffer range is out of bounds");
            const store = c.std__shared_ptr__v8__BackingStore__get(&self.store).?;
            if (!c.v8__BackingStore__IsShared(store)) {
                const buffer = c.v8__ArrayBuffer__New__with_backing_store(scope.isolate, &self.store);
                return @ptrCast(c.v8__Uint8Array__New(buffer, self.offset, self.len) orelse return error.JsException);
            }
            // The C ABI's typed-array New takes an ArrayBuffer. Use the
            // captured primordial constructor for a SharedArrayBuffer instead.
            const buffer = c.v8__SharedArrayBuffer__New__with_backing_store(scope.isolate, &self.store);
            const captured = scope.runtime.captured_bootstrap.?.get(scope.isolate);
            const primordials = try v8.getProperty(scope.isolate, scope.context, @ptrCast(captured), "primordials");
            const ctor = try v8.getProperty(scope.isolate, scope.context, @ptrCast(primordials), "Uint8Array");
            const args = [_]*const v8.Value{
                @ptrCast(buffer),                                                    @ptrCast(c.v8__Number__New(scope.isolate, @floatFromInt(self.offset))),
                @ptrCast(c.v8__Number__New(scope.isolate, @floatFromInt(self.len))),
            };
            return @ptrCast(c.v8__Function__NewInstance(@ptrCast(ctor), scope.context, 3, &args) orelse return error.JsException);
        }
    };
}

fn fail(scope: ops.Scope, message: []const u8) ops.ConvertError {
    const text = v8.newString(scope.isolate, message) catch return error.OutOfMemory;
    _ = c.v8__Isolate__ThrowException(scope.isolate, c.v8__Exception__TypeError(text));
    return error.JsException;
}
