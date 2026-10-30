// Copyright 2018-2026 the Deno authors. MIT license.
//! Native error descriptions from deno_error::JsErrorBox and JsErrorClass.
//! No V8 handles: workers publish these before the runtime builds JS values.
pub const PropertyValue = union(enum) { string: []const u8, number: f64 };
pub const Property = struct { name: []const u8, value: PropertyValue };

/// All slices are borrowed. Keep them static, in input arguments or in the
/// op's arena until conversion; a resource retaining an error must copy it.
pub const JsError = struct {
    class_name: []const u8,
    message: []const u8,
    properties: []const Property = &.{},

    pub fn typeError(message: []const u8) JsError {
        return .{ .class_name = "TypeError", .message = message };
    }
};

pub const Context = struct {
    exception: ?JsError = null,

    pub fn fail(self: *Context, exception: JsError) error{OpError} {
        self.exception = exception;
        return error.OpError;
    }
};
