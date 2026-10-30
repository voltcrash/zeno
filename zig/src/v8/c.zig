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

pub const Module = opaque {};
pub const ModuleRequest = opaque {};
pub const FixedArray = opaque {};
pub const Promise = opaque {};
pub const PromiseResolver = opaque {};
pub const Primitive = opaque {};
pub const Boolean = opaque {};
pub const Number = opaque {};
pub const Integer = opaque {};
pub const Array = opaque {};

/// `v8::Maybe<T>`, returned through out-parameters.
pub fn Maybe(comptime T: type) type {
    return extern struct { has_value: bool, value: T };
}

pub const FunctionCallback = *const fn (*const FunctionCallbackInfo) callconv(.c) void;

/// `v8::HandleScope` (three words in release builds of V8).
pub const HandleScope = extern struct { _: [3]usize };
/// `v8::TryCatch`.
pub const TryCatch = extern struct { _: [6]usize };
/// `v8::ScriptOrigin`.
pub const ScriptOrigin = extern struct { _: [5]usize };

/// `v8::ScriptCompiler::Source`, mirroring rusty_v8's `script_compiler.rs`.
pub const ScriptCompilerSource = extern struct {
    source_string: usize,
    resource_name: usize,
    resource_line_offset: c_int,
    resource_column_offset: c_int,
    resource_options: c_int,
    source_map_url: usize,
    host_defined_options: usize,
    cached_data: usize,
    consume_cache_task: usize,
    compile_hint_callback: usize,
    compile_hint_callback_data: usize,
    compilation_details: [3]usize,
};

pub const CompileOptions = enum(c_int) { no_compile_options = 0 };
pub const NoCacheReason = enum(c_int) { no_reason = 0 };
pub const ModuleStatus = enum(c_int) { uninstantiated, instantiating, instantiated, evaluating, evaluated, errored };
pub const PromiseState = enum(c_int) { pending, fulfilled, rejected };

// The callbacks below return a `MaybeLocal`, which is one pointer and
// returned in a register everywhere except the Windows x64 ABI. The port
// doesn't link V8 on Windows yet.
pub const ResolveModuleCallback = *const fn (context: *const Context, specifier: *const String, import_attributes: *const FixedArray, referrer: *const Module) callconv(.c) ?*const Module;
pub const SyntheticModuleEvaluationSteps = *const fn (context: *const Context, module: *const Module) callconv(.c) ?*const Value;
pub const HostInitializeImportMetaObjectCallback = *const fn (context: *const Context, module: *const Module, meta: *const Object) callconv(.c) void;

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
pub extern fn v8__Isolate__GetCurrent() *Isolate;
pub extern fn v8__Isolate__Enter(isolate: *Isolate) void;
pub extern fn v8__Isolate__Exit(isolate: *Isolate) void;
pub extern fn v8__Isolate__GetCurrentContext(isolate: *Isolate) *const Context;
pub const MicrotasksPolicy = enum(c_int) { explicit = 0, scoped = 1, auto = 2 };
pub extern fn v8__Isolate__SetMicrotasksPolicy(isolate: *Isolate, policy: MicrotasksPolicy) void;
pub extern fn v8__Isolate__PerformMicrotaskCheckpoint(isolate: *Isolate) void;
pub extern fn v8__Isolate__SetData(isolate: *Isolate, slot: u32, data: ?*anyopaque) void;
pub extern fn v8__Isolate__GetData(isolate: *Isolate, slot: u32) ?*anyopaque;
pub extern fn v8__Isolate__SetHostInitializeImportMetaObjectCallback(isolate: *Isolate, callback: HostInitializeImportMetaObjectCallback) void;
pub extern fn v8__Isolate__ThrowException(isolate: *Isolate, exception: *const Value) *const Value;

pub extern fn v8__ArrayBuffer__Allocator__NewDefaultAllocator() *ArrayBufferAllocator;
pub extern fn v8__ArrayBuffer__Allocator__DELETE(self: *ArrayBufferAllocator) void;

// Handles
pub extern fn v8__Global__New(isolate: *Isolate, other: *const Data) *const Data;
pub extern fn v8__Global__Reset(data: *const Data) void;
pub extern fn v8__Local__New(isolate: *Isolate, other: *const Data) *const Data;

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
pub extern fn v8__Context__GetExtrasBindingObject(self: *const Context) *const Object;

// Values
pub extern fn v8__Undefined(isolate: *Isolate) *const Primitive;
pub extern fn v8__Null(isolate: *Isolate) *const Primitive;
pub extern fn v8__Boolean__New(isolate: *Isolate, value: bool) *const Boolean;
pub extern fn v8__Number__New(isolate: *Isolate, value: f64) *const Number;
pub extern fn v8__Integer__New(isolate: *Isolate, value: i32) *const Integer;
pub extern fn v8__Integer__NewFromUnsigned(isolate: *Isolate, value: u32) *const Integer;
pub extern fn v8__Value__IsNull(self: *const Value) bool;
pub extern fn v8__Value__IsNullOrUndefined(self: *const Value) bool;
pub extern fn v8__Value__BooleanValue(self: *const Value, isolate: *Isolate) bool;
pub extern fn v8__Value__NumberValue(self: *const Value, context: *const Context, out: *Maybe(f64)) void;
pub extern fn v8__Value__Int32Value(self: *const Value, context: *const Context, out: *Maybe(i32)) void;
pub extern fn v8__Value__Uint32Value(self: *const Value, context: *const Context, out: *Maybe(u32)) void;
pub extern fn v8__Exception__Error(message: *const String) *const Value;
pub extern fn v8__Exception__TypeError(message: *const String) *const Value;
pub extern fn v8__Exception__RangeError(message: *const String) *const Value;
pub extern fn v8__Value__IsUndefined(self: *const Value) bool;
pub extern fn v8__Value__IsString(self: *const Value) bool;
pub extern fn v8__Value__IsFunction(self: *const Value) bool;
pub extern fn v8__Value__IsObject(self: *const Value) bool;
pub extern fn v8__Value__ToString(self: *const Value, context: *const Context) ?*const String;
pub extern fn v8__String__NewFromUtf8(isolate: *Isolate, data: [*]const u8, new_type: NewStringType, length: c_int) ?*const String;
pub extern fn v8__String__Utf8Length(self: *const String, isolate: *Isolate) c_int;
pub extern fn v8__String__WriteUtf8_v2(self: *const String, isolate: *Isolate, buffer: [*]u8, capacity: usize, flags: c_int, processed_characters_return: ?*usize) usize;
pub extern fn v8__Object__Set(self: *const Object, context: *const Context, key: *const Value, value: *const Value) MaybeBool;
pub extern fn v8__Object__New(isolate: *Isolate) *const Object;
pub extern fn v8__Object__SetPrototype(self: *const Object, context: *const Context, prototype: *const Value) MaybeBool;
pub extern fn v8__Object__Get(self: *const Object, context: *const Context, key: *const Value) ?*const Value;

// Functions
pub extern fn v8__Function__New(context: *const Context, callback: FunctionCallback, data_or_null: ?*const Value, length: c_int, constructor_behavior: ConstructorBehavior, side_effect_type: SideEffectType) ?*const Function;
pub extern fn v8__Function__Call(self: *const Function, context: *const Context, recv: *const Value, argc: c_int, argv: [*]const *const Value) ?*const Value;
pub extern fn v8__FunctionCallbackInfo__GetIsolate(self: *const FunctionCallbackInfo) *Isolate;
pub extern fn v8__FunctionCallbackInfo__Length(self: *const FunctionCallbackInfo) c_int;
pub extern fn v8__FunctionCallbackInfo__Get(self: *const FunctionCallbackInfo, index: c_int) *const Value;
pub extern fn v8__FunctionCallbackInfo__GetReturnValue(self: *const FunctionCallbackInfo) usize;
/// `self` points at a `v8::ReturnValue<Value>`, which is one word: the value
/// returned by `v8__FunctionCallbackInfo__GetReturnValue`.
pub extern fn v8__ReturnValue__Value__Set(self: *usize, value: *const Value) void;

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

// Modules
pub extern fn v8__ScriptCompiler__Source__CONSTRUCT(buf: *ScriptCompilerSource, source_string: *const String, origin: ?*const ScriptOrigin, cached_data: ?*anyopaque) void;
pub extern fn v8__ScriptCompiler__Source__DESTRUCT(self: *ScriptCompilerSource) void;
pub extern fn v8__ScriptCompiler__CompileModule(isolate: *Isolate, source: *ScriptCompilerSource, options: CompileOptions, no_cache_reason: NoCacheReason) ?*const Module;
pub extern fn v8__Module__GetStatus(self: *const Module) ModuleStatus;
pub extern fn v8__Module__GetException(self: *const Module) *const Value;
pub extern fn v8__Module__GetModuleRequests(self: *const Module) *const FixedArray;
pub extern fn v8__Module__GetModuleNamespace(self: *const Module) *const Value;
pub extern fn v8__Module__GetIdentityHash(self: *const Module) c_int;
pub extern fn v8__Module__InstantiateModule(self: *const Module, context: *const Context, cb: ResolveModuleCallback, source_callback: ?*const anyopaque) MaybeBool;
pub extern fn v8__Module__Evaluate(self: *const Module, context: *const Context) ?*const Value;
pub extern fn v8__Module__CreateSyntheticModule(isolate: *Isolate, module_name: *const String, export_names_len: usize, export_names_raw: [*]const *const String, evaluation_steps: SyntheticModuleEvaluationSteps) *const Module;
pub extern fn v8__Module__SetSyntheticModuleExport(self: *const Module, isolate: *Isolate, export_name: *const String, export_value: *const Value) MaybeBool;
pub extern fn v8__ModuleRequest__GetSpecifier(self: *const ModuleRequest) *const String;
pub extern fn v8__FixedArray__Length(self: *const FixedArray) c_int;
pub extern fn v8__FixedArray__Get(self: *const FixedArray, index: c_int) *const Data;

// Promises
pub extern fn v8__Promise__Resolver__New(context: *const Context) ?*const PromiseResolver;
pub extern fn v8__Promise__Resolver__GetPromise(self: *const PromiseResolver) *const Promise;
pub extern fn v8__Promise__Resolver__Resolve(self: *const PromiseResolver, context: *const Context, value: *const Value) MaybeBool;
pub extern fn v8__Promise__State(self: *const Promise) PromiseState;
pub extern fn v8__Promise__Result(self: *const Promise) *const Value;
pub extern fn v8__Promise__MarkAsHandled(self: *const Promise) void;
pub extern fn v8__Value__IsPromise(self: *const Value) bool;

pub extern fn v8__Value__IsArrayBuffer(self: *const Value) bool;

pub extern fn v8__Value__IsSharedArrayBuffer(self: *const Value) bool;

pub extern fn v8__Value__IsArgumentsObject(self: *const Value) bool;

pub extern fn v8__Value__IsArrayBufferView(self: *const Value) bool;

pub extern fn v8__Value__IsAsyncFunction(self: *const Value) bool;

pub extern fn v8__Value__IsBigIntObject(self: *const Value) bool;

pub extern fn v8__Value__IsBooleanObject(self: *const Value) bool;

pub extern fn v8__Value__IsStringObject(self: *const Value) bool;

pub extern fn v8__Value__IsNumberObject(self: *const Value) bool;

pub extern fn v8__Value__IsSymbolObject(self: *const Value) bool;

pub extern fn v8__Value__IsDataView(self: *const Value) bool;

pub extern fn v8__Value__IsDate(self: *const Value) bool;

pub extern fn v8__Value__IsGeneratorFunction(self: *const Value) bool;

pub extern fn v8__Value__IsGeneratorObject(self: *const Value) bool;

pub extern fn v8__Value__IsMap(self: *const Value) bool;

pub extern fn v8__Value__IsMapIterator(self: *const Value) bool;

pub extern fn v8__Value__IsModuleNamespaceObject(self: *const Value) bool;

pub extern fn v8__Value__IsNativeError(self: *const Value) bool;

pub extern fn v8__Value__IsProxy(self: *const Value) bool;

pub extern fn v8__Value__IsRegExp(self: *const Value) bool;

pub extern fn v8__Value__IsSet(self: *const Value) bool;

pub extern fn v8__Value__IsSetIterator(self: *const Value) bool;

pub extern fn v8__Value__IsTypedArray(self: *const Value) bool;

pub extern fn v8__Value__IsWeakMap(self: *const Value) bool;

pub extern fn v8__Value__IsWeakSet(self: *const Value) bool;

// Rejection tracking and core's shared tick counters.
pub const PromiseRejectEvent = enum(c_int) {
    reject_with_no_handler = 0,
    handler_added_after_reject = 1,
    reject_after_resolved = 2,
    resolve_after_resolved = 3,
};
pub const PromiseRejectMessage = extern struct { words: [3]usize };
pub const ArrayBuffer = opaque {};
pub const Uint8Array = opaque {};
pub extern fn v8__Isolate__SetPromiseRejectCallback(isolate: *Isolate, callback: *const fn (PromiseRejectMessage) callconv(.c) void) void;
pub extern fn v8__PromiseRejectMessage__GetEvent(self: *const PromiseRejectMessage) PromiseRejectEvent;
pub extern fn v8__PromiseRejectMessage__GetPromise(self: *const PromiseRejectMessage) *const Promise;
pub extern fn v8__PromiseRejectMessage__GetValue(self: *const PromiseRejectMessage) ?*const Value;
pub extern fn v8__Context__GetContinuationPreservedEmbedderData(isolate: *Isolate) *const Value;
pub extern fn v8__Value__StrictEquals(self: *const Value, that: *const Value) bool;
pub extern fn v8__Array__New(isolate: *Isolate, length: c_int) *const Array;
pub extern fn v8__Object__SetIndex(self: *const Object, context: *const Context, index: u32, value: *const Value) MaybeBool;
pub extern fn v8__ArrayBuffer__New__with_byte_length(isolate: *Isolate, byte_length: usize) *const ArrayBuffer;
pub extern fn v8__ArrayBuffer__Data(self: *const ArrayBuffer) ?*anyopaque;
pub extern fn v8__Uint8Array__New(buffer: *const ArrayBuffer, byte_offset: usize, length: usize) ?*const Uint8Array;

pub extern fn v8__Isolate__HasPendingBackgroundTasks(isolate: *Isolate) bool;
pub const Int32Array = opaque {};
pub extern fn v8__Int32Array__New(buffer: *const ArrayBuffer, byte_offset: usize, length: usize) ?*const Int32Array;

pub extern fn v8__Array__New_with_elements(isolate: *Isolate, elements: [*]const *const Value, length: usize) *const Array;
