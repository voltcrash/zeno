// Copyright 2018-2026 the Deno authors. MIT license.
//! Minimal URL handling for module specifiers, standing in for the `url`
//! crate (`resolve_import` in `libs/core/module_specifier.rs`) until a full
//! WHATWG URL parser is ported along with `ext/url`.
//!
//! Supports absolute URLs, and resolving relative specifiers against
//! hierarchical bases (`file:///...`, `https://host/...`), including dot
//! segments, queries and fragments.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ResolveError = error{ OutOfMemory, ImportPrefixMissing, InvalidBaseUrl };

/// Whether `s` starts with a URL scheme followed by `:`, e.g. `file:` or
/// `ext:`. Single letters are treated as Windows drive letters, not schemes.
pub fn hasScheme(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon < 2) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

/// Resolve `specifier` against `base`, like `resolve_import`.
pub fn resolveImport(arena: Allocator, specifier: []const u8, base: []const u8) ResolveError![]const u8 {
    if (hasScheme(specifier)) return specifier;
    if (!(std.mem.startsWith(u8, specifier, "/") or
        std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../")))
    {
        return error.ImportPrefixMissing;
    }
    return join(arena, base, specifier);
}

/// Resolve the relative reference `rel` against the absolute `base`
/// (RFC 3986, section 5.2).
pub fn join(arena: Allocator, base: []const u8, rel: []const u8) ResolveError![]const u8 {
    if (!hasScheme(base)) return error.InvalidBaseUrl;
    const scheme_end = std.mem.indexOfScalar(u8, base, ':').? + 1;
    // Only hierarchical URLs (`scheme://authority/path`) can be a base.
    if (!std.mem.startsWith(u8, base[scheme_end..], "//")) return error.InvalidBaseUrl;
    const authority_start = scheme_end + 2;
    const path_start = std.mem.indexOfAnyPos(u8, base, authority_start, "/?#") orelse base.len;
    const prefix = base[0..path_start];
    const base_path = base[path_start .. std.mem.indexOfAnyPos(u8, base, path_start, "?#") orelse base.len];

    const rel_path_end = std.mem.indexOfAny(u8, rel, "?#") orelse rel.len;
    const rel_path = rel[0..rel_path_end];
    const rel_rest = rel[rel_path_end..];

    var merged: std.ArrayList(u8) = .empty;
    if (std.mem.startsWith(u8, rel_path, "/")) {
        try merged.appendSlice(arena, rel_path);
    } else {
        const dir_end = if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |i| i + 1 else 0;
        if (dir_end == 0) try merged.append(arena, '/');
        try merged.appendSlice(arena, base_path[0..dir_end]);
        try merged.appendSlice(arena, rel_path);
    }
    const path = try removeDotSegments(arena, merged.items);
    return std.mem.concat(arena, u8, &.{ prefix, path, rel_rest });
}

fn removeDotSegments(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    var last_was_dot = false;
    while (it.next()) |seg| {
        last_was_dot = false;
        if (std.mem.eql(u8, seg, ".")) {
            last_was_dot = true;
        } else if (std.mem.eql(u8, seg, "..")) {
            _ = segments.pop();
            last_was_dot = true;
        } else {
            try segments.append(arena, seg);
        }
    }
    // A trailing `.` or `..` leaves a directory path (`/a/b/..` is `/a/`).
    if (last_was_dot) try segments.append(arena, "");
    var out: std.ArrayList(u8) = .empty;
    for (segments.items) |seg| {
        try out.append(arena, '/');
        try out.appendSlice(arena, seg);
    }
    if (out.items.len == 0) try out.append(arena, '/');
    return out.items;
}

/// The percent-decoded path of a `file:` URL, or null if `url` isn't one.
pub fn toFilePath(arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const path_end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    const encoded = rest[path_start..path_end];
    var out = try arena.alloc(u8, encoded.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            if (std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = encoded[i];
        n += 1;
    }
    return out[0..n];
}

/// A `file:` URL for an absolute path, percent-encoding what needs it.
pub fn fromFilePath(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "file://");
    for (path) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~!$&'()*+,;=:@", ch) != null;
        if (keep) {
            try out.append(arena, ch);
        } else {
            try out.print(arena, "%{X:0>2}", .{ch});
        }
    }
    return out.items;
}

test "resolveImport" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = "file:///home/user/project/src/main.js";
    const cases = [_][2][]const u8{
        .{ "./util.js", "file:///home/user/project/src/util.js" },
        .{ "../lib/x.js", "file:///home/user/project/lib/x.js" },
        .{ "../../../../../x.js", "file:///x.js" },
        .{ "/abs.js", "file:///abs.js" },
        .{ "./a/./b/../c.js?q=1#h", "file:///home/user/project/src/a/c.js?q=1#h" },
        .{ "./", "file:///home/user/project/src/" },
        .{ "..", "file:///home/user/project/" },
        .{ "https://deno.land/x/mod.ts", "https://deno.land/x/mod.ts" },
        .{ "ext:core/ops", "ext:core/ops" },
    };
    for (cases) |case| {
        const spec = if (std.mem.eql(u8, case[0], "..")) "../" else case[0];
        try std.testing.expectEqualStrings(case[1], try resolveImport(a, spec, base));
    }
    try std.testing.expectEqualStrings("https://deno.land/std/fs.ts", try resolveImport(a, "/std/fs.ts", "https://deno.land/x/a/mod.ts"));
    try std.testing.expectEqualStrings("https://deno.land/x/b.ts", try resolveImport(a, "./b.ts", "https://deno.land/x/a.ts?x=1"));
    try std.testing.expectError(error.ImportPrefixMissing, resolveImport(a, "lodash", base));
    try std.testing.expectError(error.InvalidBaseUrl, resolveImport(a, "./x.js", "ext:core/mod.js"));
}

test "file paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const u = try fromFilePath(a, "/tmp/my dir/$deno$eval.mts");
    try std.testing.expectEqualStrings("file:///tmp/my%20dir/$deno$eval.mts", u);
    try std.testing.expectEqualStrings("/tmp/my dir/$deno$eval.mts", (try toFilePath(a, u)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try toFilePath(a, "https://x/y"));
    try std.testing.expect(!hasScheme("C:/x"));
    try std.testing.expect(hasScheme("node:fs"));
}
