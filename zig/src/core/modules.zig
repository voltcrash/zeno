// Copyright 2018-2026 the Deno authors. MIT license.
//! ES module loading, ported from `libs/core/modules` (`ModuleMap`,
//! `RecursiveModuleLoad`).
//!
//! Module graphs are loaded synchronously for now: each module is compiled,
//! its static imports resolved and loaded depth-first, then the graph is
//! instantiated and evaluated. Dynamic `import()` and async loading come
//! with the event loop.

const std = @import("std");
const v8 = @import("../v8/v8.zig");
const c = v8.c;
const url = @import("url.zig");
const JsRuntime = @import("runtime.zig").JsRuntime;

/// Where module sources come from.
pub const Source = union(enum) {
    /// JavaScript source text.
    code: []const u8,
    /// A synthetic module exporting the given values (`ext:core/ops`).
    synthetic: []const Export,

    pub const Export = struct { name: []const u8, value: v8.Global(v8.Value) };
};

pub const LoadError = error{ OutOfMemory, JsException, ModuleNotFound, ResolutionFailed };

const ModuleInfo = struct {
    specifier: []const u8,
    module: v8.Global(c.Module),
    identity_hash: c_int,
    is_main: bool,
    /// For synthetic modules, the exports set when they're evaluated.
    synthetic_exports: []const Source.Export = &.{},
    /// Resolved specifiers of the module's static imports, by request.
    imports: std.StringHashMapUnmanaged([]const u8) = .empty,
};

pub const ModuleMap = struct {
    /// Owns the specifiers, sources and import maps.
    arena: std.heap.ArenaAllocator,
    modules: std.ArrayList(ModuleInfo) = .empty,
    by_specifier: std.StringHashMapUnmanaged(usize) = .empty,
    /// Built-in (`ext:`) module sources, by specifier.
    builtin: std.StringHashMapUnmanaged(Source) = .empty,
    /// Error message for the last failed load or resolution.
    last_error: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator) ModuleMap {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *ModuleMap) void {
        for (self.modules.items) |info| {
            info.module.deinit();
            for (info.synthetic_exports) |e| e.value.deinit();
        }
        self.arena.deinit();
    }

    /// Provide the source of a built-in module, e.g. `ext:core/mod.js`.
    pub fn addBuiltin(self: *ModuleMap, specifier: []const u8, source: Source) !void {
        try self.builtin.put(self.arena.allocator(), specifier, source);
    }

    fn find(self: *ModuleMap, specifier: []const u8) ?*ModuleInfo {
        const i = self.by_specifier.get(specifier) orelse return null;
        return &self.modules.items[i];
    }

    fn findByModule(self: *ModuleMap, module: *const c.Module) ?*ModuleInfo {
        const hash = c.v8__Module__GetIdentityHash(module);
        for (self.modules.items) |*info| {
            if (info.identity_hash == hash) return info;
        }
        return null;
    }

    fn fail(self: *ModuleMap, comptime fmt: []const u8, args: anytype, err: LoadError) LoadError {
        self.last_error = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch null;
        return err;
    }

    /// Load `specifier` and its static imports. `code` is the source of
    /// `specifier` itself if it's in memory (e.g. `deno eval`); otherwise it
    /// is read from its URL.
    pub fn load(self: *ModuleMap, rt: *JsRuntime, specifier: []const u8, code: ?[]const u8, is_main: bool) LoadError!*const c.Module {
        if (self.find(specifier)) |info| return info.module.get(rt.isolate());
        const a = self.arena.allocator();
        const spec = try a.dupe(u8, specifier);
        const source: Source = if (code) |s| .{ .code = try a.dupe(u8, s) } else try self.fetch(rt, spec);

        const iso = rt.isolate();
        const module = switch (source) {
            .code => |text| try compile(iso, spec, text),
            .synthetic => |exports| try createSynthetic(iso, spec, exports),
        };
        try self.by_specifier.put(a, spec, self.modules.items.len);
        try self.modules.append(a, .{
            .specifier = spec,
            .module = .init(iso, module),
            .identity_hash = c.v8__Module__GetIdentityHash(module),
            .is_main = is_main,
            .synthetic_exports = if (source == .synthetic) source.synthetic else &.{},
        });
        const index = self.modules.items.len - 1;

        // Load the static imports, depth first.
        const requests = c.v8__Module__GetModuleRequests(module);
        const n: usize = @intCast(c.v8__FixedArray__Length(requests));
        for (0..n) |i| {
            const request: *const c.ModuleRequest = @ptrCast(c.v8__FixedArray__Get(requests, @intCast(i)));
            const request_spec = try v8.toUtf8(a, iso, rt.context, @ptrCast(c.v8__ModuleRequest__GetSpecifier(request)));
            const resolved = url.resolveImport(a, request_spec, spec) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ImportPrefixMissing => return self.fail(
                    "Relative import path \"{s}\" not prefixed with / or ./ or ../ from \"{s}\"",
                    .{ request_spec, spec },
                    error.ResolutionFailed,
                ),
                error.InvalidBaseUrl => return self.fail(
                    "Invalid URL: relative URL with a cannot-be-a-base base: \"{s}\" from \"{s}\"",
                    .{ request_spec, spec },
                    error.ResolutionFailed,
                ),
            };
            try self.modules.items[index].imports.put(a, request_spec, resolved);
            _ = try self.load(rt, resolved, null, false);
        }
        return module;
    }

    fn fetch(self: *ModuleMap, rt: *JsRuntime, specifier: []const u8) LoadError!Source {
        if (self.builtin.get(specifier)) |source| return source;
        const a = self.arena.allocator();
        if (try url.toFilePath(a, specifier)) |path| {
            const text = std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .unlimited) catch {
                return self.fail("Module not found \"{s}\".", .{specifier}, error.ModuleNotFound);
            };
            return .{ .code = text };
        }
        return self.fail("Module not found \"{s}\".", .{specifier}, error.ModuleNotFound);
    }

    /// Instantiate and evaluate a loaded module graph. Microtasks are run;
    /// an exception (or a rejected top-level await) is left in `exception`.
    pub fn evaluate(self: *ModuleMap, rt: *JsRuntime, module: *const c.Module, exception: *?*const v8.Value) LoadError!void {
        _ = self;
        const ctx = rt.context;
        if (c.v8__Module__InstantiateModule(module, ctx, resolveCallback, null) != .just_true) {
            return error.JsException;
        }
        const result = c.v8__Module__Evaluate(module, ctx) orelse return error.JsException;
        if (c.v8__Value__IsPromise(result)) {
            // The embedder observes this promise directly. It must not also
            // produce a user-facing unhandled rejection notification.
            const promise: *const c.Promise = @ptrCast(result);
            c.v8__Promise__MarkAsHandled(promise);
            _ = rt.exceptions.removePending(rt.isolate(), promise);
        }
        try rt.runEventLoop(if (c.v8__Value__IsPromise(result)) @ptrCast(result) else null, exception);
        if (c.v8__Module__GetStatus(module) == .errored) {
            exception.* = c.v8__Module__GetException(module);
            return error.JsException;
        }
        if (c.v8__Value__IsPromise(result)) {
            const promise: *const c.Promise = @ptrCast(result);
            switch (c.v8__Promise__State(promise)) {
                .fulfilled => {},
                .rejected => {
                    c.v8__Promise__MarkAsHandled(promise);
                    exception.* = c.v8__Promise__Result(promise);
                    return error.JsException;
                },
                // No referenced timer remains that could settle it.
                .pending => return error.JsException,
            }
        }
    }

    fn resolveCallback(context: *const v8.Context, specifier: *const v8.String, import_attributes: *const c.FixedArray, referrer: *const c.Module) callconv(.c) ?*const c.Module {
        _ = import_attributes;
        const iso = c.v8__Isolate__GetCurrent();
        const rt = JsRuntime.fromIsolate(iso);
        const self = &rt.modules;
        const info = self.findByModule(referrer) orelse return null;
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const spec = v8.toUtf8(fba.allocator(), iso, context, @ptrCast(specifier)) catch return null;
        const resolved = info.imports.get(spec) orelse return null;
        const target = self.find(resolved) orelse return null;
        return target.module.get(iso);
    }

    /// `import.meta`: `url` and `main`, and for `ext:` modules the shared
    /// prototype that `01_core.js` puts `log` on.
    pub fn initializeImportMeta(context: *const v8.Context, module: *const c.Module, meta: *const v8.Object) callconv(.c) void {
        const iso = c.v8__Isolate__GetCurrent();
        const rt = JsRuntime.fromIsolate(iso);
        const info = rt.modules.findByModule(module) orelse return;
        const url_value = v8.newString(iso, info.specifier) catch return;
        v8.setProperty(iso, context, meta, "url", @ptrCast(url_value)) catch return;
        v8.setProperty(iso, context, meta, "main", @ptrCast(c.v8__Boolean__New(iso, info.is_main))) catch return;
        if (std.mem.startsWith(u8, info.specifier, "ext:")) {
            _ = c.v8__Object__SetPrototype(meta, context, @ptrCast(rt.ext_import_meta_proto.get(iso)));
        }
    }

    fn syntheticEvaluationSteps(context: *const v8.Context, module: *const c.Module) callconv(.c) ?*const v8.Value {
        const iso = c.v8__Isolate__GetCurrent();
        const rt = JsRuntime.fromIsolate(iso);
        const info = rt.modules.findByModule(module) orelse return null;
        for (info.synthetic_exports) |e| {
            const name = v8.newString(iso, e.name) catch return null;
            if (c.v8__Module__SetSyntheticModuleExport(module, iso, name, e.value.get(iso)) != .just_true) return null;
        }
        // Evaluation steps return a promise, as for top-level await.
        const resolver = c.v8__Promise__Resolver__New(context) orelse return null;
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(c.v8__Undefined(iso)));
        return @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver));
    }
};

fn compile(iso: *v8.Isolate, specifier: []const u8, code: []const u8) v8.Error!*const c.Module {
    var origin: c.ScriptOrigin = undefined;
    const name = try v8.newString(iso, specifier);
    c.v8__ScriptOrigin__CONSTRUCT(&origin, @ptrCast(name), 0, 0, false, -1, null, false, false, true, null);
    var source: c.ScriptCompilerSource = undefined;
    c.v8__ScriptCompiler__Source__CONSTRUCT(&source, try v8.newString(iso, code), &origin, null);
    defer c.v8__ScriptCompiler__Source__DESTRUCT(&source);
    return c.v8__ScriptCompiler__CompileModule(iso, &source, .no_compile_options, .no_reason) orelse error.JsException;
}

fn createSynthetic(iso: *v8.Isolate, specifier: []const u8, exports: []const Source.Export) LoadError!*const c.Module {
    var names: std.ArrayList(*const v8.String) = .empty;
    defer names.deinit(std.heap.smp_allocator);
    for (exports) |e| try names.append(std.heap.smp_allocator, try v8.newString(iso, e.name));
    return c.v8__Module__CreateSyntheticModule(iso, try v8.newString(iso, specifier), names.items.len, names.items.ptr, ModuleMap.syntheticEvaluationSteps);
}
