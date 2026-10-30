// Copyright 2018-2026 the Deno authors. MIT license.
//! Value predicates from `libs/core/ops_builtin_types.rs`.

const v8 = @import("../v8/v8.zig");
const ops = @import("ops.zig");

pub const all = [_]ops.OpDecl{
    ops.op("op_is_any_array_buffer", isAnyArrayBuffer),
    ops.op("op_is_arguments_object", isArgumentsObject),
    ops.op("op_is_array_buffer", isArrayBuffer),
    ops.op("op_is_array_buffer_view", isArrayBufferView),
    ops.op("op_is_async_function", isAsyncFunction),
    ops.op("op_is_big_int_object", isBigIntObject),
    ops.op("op_is_boolean_object", isBooleanObject),
    ops.op("op_is_boxed_primitive", isBoxedPrimitive),
    ops.op("op_is_data_view", isDataView),
    ops.op("op_is_date", isDate),
    ops.op("op_is_generator_function", isGeneratorFunction),
    ops.op("op_is_generator_object", isGeneratorObject),
    ops.op("op_is_map", isMap),
    ops.op("op_is_map_iterator", isMapIterator),
    ops.op("op_is_module_namespace_object", isModuleNamespaceObject),
    ops.op("op_is_native_error", isNativeError),
    ops.op("op_is_number_object", isNumberObject),
    ops.op("op_is_promise", isPromise),
    ops.op("op_is_proxy", isProxy),
    ops.op("op_is_reg_exp", isRegExp),
    ops.op("op_is_set", isSet),
    ops.op("op_is_set_iterator", isSetIterator),
    ops.op("op_is_shared_array_buffer", isSharedArrayBuffer),
    ops.op("op_is_string_object", isStringObject),
    ops.op("op_is_symbol_object", isSymbolObject),
    ops.op("op_is_typed_array", isTypedArray),
    ops.op("op_is_weak_map", isWeakMap),
    ops.op("op_is_weak_set", isWeakSet),
};

fn isAnyArrayBuffer(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsArrayBuffer(value) or v8.c.v8__Value__IsSharedArrayBuffer(value);
}

fn isArgumentsObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsArgumentsObject(value);
}

fn isArrayBuffer(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsArrayBuffer(value);
}

fn isArrayBufferView(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsArrayBufferView(value);
}

fn isAsyncFunction(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsAsyncFunction(value);
}

fn isBigIntObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsBigIntObject(value);
}

fn isBooleanObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsBooleanObject(value);
}

fn isBoxedPrimitive(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsBooleanObject(value) or v8.c.v8__Value__IsStringObject(value) or v8.c.v8__Value__IsNumberObject(value) or v8.c.v8__Value__IsSymbolObject(value) or v8.c.v8__Value__IsBigIntObject(value);
}

fn isDataView(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsDataView(value);
}

fn isDate(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsDate(value);
}

fn isGeneratorFunction(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsGeneratorFunction(value);
}

fn isGeneratorObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsGeneratorObject(value);
}

fn isMap(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsMap(value);
}

fn isMapIterator(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsMapIterator(value);
}

fn isModuleNamespaceObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsModuleNamespaceObject(value);
}

fn isNativeError(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsNativeError(value);
}

fn isNumberObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsNumberObject(value);
}

fn isPromise(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsPromise(value);
}

fn isProxy(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsProxy(value);
}

fn isRegExp(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsRegExp(value);
}

fn isSet(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsSet(value);
}

fn isSetIterator(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsSetIterator(value);
}

fn isSharedArrayBuffer(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsSharedArrayBuffer(value);
}

fn isStringObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsStringObject(value);
}

fn isSymbolObject(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsSymbolObject(value);
}

fn isTypedArray(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsTypedArray(value);
}

fn isWeakMap(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsWeakMap(value);
}

fn isWeakSet(value: *const v8.Value) bool {
    return v8.c.v8__Value__IsWeakSet(value);
}
