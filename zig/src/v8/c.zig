// Copyright 2018-2026 the Deno authors. MIT license.
//! Raw declarations for the C ABI exported by rusty_v8's `src/binding.cc`,
//! which is compiled into the prebuilt `librusty_v8.a`. Signatures follow
//! binding.cc. `Local<T>` handles are passed as `*const T`, and C++
//! references as pointers.
//!
//! Only what the port uses so far is declared; add more as needed.

pub const Platform = opaque {};
pub const Isolate = opaque {};
pub const ArrayBufferAllocator = opaque {};
pub const Context = opaque {};
pub const ObjectTemplate = opaque {};
pub const Data = opaque {};
pub const Value = opaque {};
pub const Object = opaque {};
pub const String = opaque {};
pub const Function = opaque {};
pub const Script = opaque {};
pub const Message = opaque {};
pub const MicrotaskQueue = opaque {};
pub const FunctionCallbackInfo = opaque {};

pub const FunctionCallback = *const fn (*const FunctionCallbackInfo) callconv(.c) void;

/// `v8::HandleScope` (three words in release builds of V8).
pub const HandleScope = extern struct { _: [3]usize };
/// `v8::TryCatch`.
pub const TryCatch = extern struct { _: [6]usize };
/// `v8::ScriptOrigin`.
pub const ScriptOrigin = extern struct { _: [5]usize };

/// rusty_v8's `MaybeBool`.
pub const MaybeBool = enum(u8) { just_false = 0, just_true = 1, nothing = 2 };

pub const NewStringType = enum(c_int) { normal = 0, internalized = 1 };
pub const ConstructorBehavior = enum(c_int) { throw = 0, allow = 1 };
pub const SideEffectType = enum(c_int) { has_side_effect = 0, has_no_side_effect = 1, has_side_effect_to_receiver = 2 };

// V8
pub extern fn v8__V8__SetFlagsFromString(flags: [*]const u8, length: usize) void;
pub extern fn v8__V8__GetVersion() [*:0]const u8;
pub extern fn v8__V8__InitializePlatform(platform: *Platform) void;
pub extern fn v8__V8__Initialize() void;
pub extern fn v8__V8__Dispose() bool;
pub extern fn v8__V8__DisposePlatform() void;

// Platform
pub extern fn v8__Platform__NewDefaultPlatform(thread_pool_size: c_int, idle_task_support: bool) *Platform;
pub extern fn v8__Platform__DELETE(self: *Platform) void;
pub extern fn v8__Platform__PumpMessageLoop(platform: *Platform, isolate: *Isolate, wait_for_work: bool) bool;

// Isolate
pub extern fn v8__Isolate__CreateParams__SIZEOF() usize;
pub extern fn v8__Isolate__CreateParams__CONSTRUCT(buf: *anyopaque) void;
pub extern fn v8__Isolate__New(params: *const anyopaque) *Isolate;
pub extern fn v8__Isolate__Dispose(isolate: *Isolate) void;
pub extern fn v8__Isolate__Enter(isolate: *Isolate) void;
pub extern fn v8__Isolate__Exit(isolate: *Isolate) void;
pub extern fn v8__Isolate__GetCurrentContext(isolate: *Isolate) *const Context;
pub extern fn v8__Isolate__PerformMicrotaskCheckpoint(isolate: *Isolate) void;
pub extern fn v8__Isolate__ThrowException(isolate: *Isolate, exception: *const Value) *const Value;

pub extern fn v8__ArrayBuffer__Allocator__NewDefaultAllocator() *ArrayBufferAllocator;
pub extern fn v8__ArrayBuffer__Allocator__DELETE(self: *ArrayBufferAllocator) void;

// Scopes
pub extern fn v8__HandleScope__CONSTRUCT(buf: *HandleScope, isolate: *Isolate) void;
pub extern fn v8__HandleScope__DESTRUCT(self: *HandleScope) void;
pub extern fn v8__TryCatch__CONSTRUCT(buf: *TryCatch, isolate: *Isolate) void;
pub extern fn v8__TryCatch__DESTRUCT(self: *TryCatch) void;
pub extern fn v8__TryCatch__HasCaught(self: *const TryCatch) bool;
pub extern fn v8__TryCatch__Exception(self: *const TryCatch) ?*const Value;
pub extern fn v8__TryCatch__StackTrace(self: *const TryCatch, context: *const Context) ?*const Value;
pub extern fn v8__TryCatch__Message(self: *const TryCatch) ?*const Message;

// Context
pub extern fn v8__Context__New(isolate: *Isolate, templ: ?*const ObjectTemplate, global_object: ?*const Value, microtask_queue: ?*MicrotaskQueue) *const Context;
pub extern fn v8__Context__Enter(self: *const Context) void;
pub extern fn v8__Context__Exit(self: *const Context) void;
pub extern fn v8__Context__Global(self: *const Context) *const Object;

// Values
pub extern fn v8__Value__IsUndefined(self: *const Value) bool;
pub extern fn v8__Value__IsString(self: *const Value) bool;
pub extern fn v8__Value__ToString(self: *const Value, context: *const Context) ?*const String;
pub extern fn v8__String__NewFromUtf8(isolate: *Isolate, data: [*]const u8, new_type: NewStringType, length: c_int) ?*const String;
pub extern fn v8__String__Utf8Length(self: *const String, isolate: *Isolate) c_int;
pub extern fn v8__String__WriteUtf8_v2(self: *const String, isolate: *Isolate, buffer: [*]u8, capacity: usize, flags: c_int, processed_characters_return: ?*usize) usize;
pub extern fn v8__Object__Set(self: *const Object, context: *const Context, key: *const Value, value: *const Value) MaybeBool;
pub extern fn v8__Object__New(isolate: *Isolate) *const Object;

// Functions
pub extern fn v8__Function__New(context: *const Context, callback: FunctionCallback, data_or_null: ?*const Value, length: c_int, constructor_behavior: ConstructorBehavior, side_effect_type: SideEffectType) ?*const Function;
pub extern fn v8__FunctionCallbackInfo__GetIsolate(self: *const FunctionCallbackInfo) *Isolate;
pub extern fn v8__FunctionCallbackInfo__Length(self: *const FunctionCallbackInfo) c_int;
pub extern fn v8__FunctionCallbackInfo__Get(self: *const FunctionCallbackInfo, index: c_int) *const Value;

// Scripts
pub extern fn v8__ScriptOrigin__CONSTRUCT(
    buf: *ScriptOrigin,
    resource_name: *const Value,
    resource_line_offset: c_int,
    resource_column_offset: c_int,
    resource_is_shared_cross_origin: bool,
    script_id: c_int,
    source_map_url: ?*const Value,
    resource_is_opaque: bool,
    is_wasm: bool,
    is_module: bool,
    host_defined_options: ?*const Data,
) void;
pub extern fn v8__Script__Compile(context: *const Context, source: *const String, origin: ?*const ScriptOrigin) ?*const Script;
pub extern fn v8__Script__Run(script: *const Script, context: *const Context) ?*const Value;
