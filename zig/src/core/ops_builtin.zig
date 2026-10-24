// Copyright 2018-2026 the Deno authors. MIT license.
//! Built-in ops of every runtime, ported from `libs/core/ops_builtin.rs` and
//! `ops_builtin_v8.rs`. Only the ops the port needs so far; the rest follow
//! as their users are ported.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const ops = @import("ops.zig");
const op = ops.op;
const Scope = ops.Scope;

pub const all = [_]ops.OpDecl{
    op("op_print", opPrint),
    op("op_get_extras_binding_object", opGetExtrasBindingObject),
    op("op_get_ext_import_meta_proto", opGetExtImportMetaProto),
    op("op_set_captured_bootstrap", opSetCapturedBootstrap),
};

fn opPrint(scope: Scope, msg: []const u8, is_err: bool) !void {
    const file = if (is_err) std.Io.File.stderr() else std.Io.File.stdout();
    try file.writeStreamingAll(scope.runtime.io, msg);
}

fn opGetExtrasBindingObject(scope: Scope) *const v8.Value {
    return @ptrCast(c.v8__Context__GetExtrasBindingObject(scope.context));
}

/// The prototype of `import.meta` for `ext:` modules.
fn opGetExtImportMetaProto(scope: Scope) *const v8.Value {
    return @ptrCast(scope.runtime.ext_import_meta_proto.get(scope.isolate));
}

/// Called once by `01_core.js` after `__bootstrap.core` is populated.
fn opSetCapturedBootstrap(scope: Scope, value: *const v8.Value) void {
    const rt = scope.runtime;
    if (rt.captured_bootstrap) |old| old.deinit();
    rt.captured_bootstrap = .init(scope.isolate, value);
}
