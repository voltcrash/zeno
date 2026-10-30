// Copyright 2018-2026 the Deno authors. MIT license.
//! Native I/O context for resource methods and async ops. Error descriptions
//! follow deno_error::JsErrorBox without carrying V8 handles to workers.
const std = @import("std");
const errors = @import("errors.zig");

pub const IoScope = struct {
    io: std.Io,
    /// Per-op arena for returned strings and error fields. It stays alive
    /// until the runtime has converted the result or error to JS.
    allocator: std.mem.Allocator,
    /// Owned chunks must be freed independently of the per-op arena, so a
    /// long-running pipe does not retain every previous chunk until EOF.
    /// The allocator must outlive its buffers and support worker-thread use.
    buffer_allocator: std.mem.Allocator = std.heap.smp_allocator,
    error_context: *errors.Context,

    pub fn fail(self: IoScope, exception: errors.JsError) error{OpError} {
        return self.error_context.fail(exception);
    }
};
