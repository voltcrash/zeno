// Copyright 2018-2026 the Deno authors. MIT license.

const std = @import("std");

/// Prebuilt rusty_v8 archives (with the `simdutf` feature, like the Rust
/// build) and the SHA-256 of each gzipped download.
const rusty_v8_version = "150.4.0";
const rusty_v8_archives = [_]struct { triple: []const u8, sha256: []const u8 }{
    .{ .triple = "aarch64-unknown-linux-gnu", .sha256 = "539e283815a396a5796f32858b42e517b858ebaaeaaad05d03290ee8c864a527" },
    .{ .triple = "x86_64-unknown-linux-gnu", .sha256 = "f48762ca10d1f1fc605a441c5ae430ec8ce1e9e80f14d78fbc42cb878c30b476" },
    .{ .triple = "aarch64-apple-darwin", .sha256 = "5aeffd8d5a0c1b79ac1d70af83d5b19099655fd9c645a794dc43f101f779838c" },
    .{ .triple = "x86_64-apple-darwin", .sha256 = "a750271fec6b211457ed0a5cf7d2eab1924b265621a82da86ab959d6ff0823e4" },
};

/// JavaScript sources of `libs/core`, embedded as `ext:core/<name>`.
const core_js = [_][]const u8{
    "00_primordials.js",
    "00_infra.js",
    "01_core.js",
    "02_timers.js",
    "mod.js",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const v8_archive_path = b.option(
        []const u8,
        "v8-archive",
        "Path to an uncompressed librusty_v8 archive to link instead of downloading one",
    );

    const v8_archive = v8Archive(b, target.result, v8_archive_path);
    const options = b.addOptions();
    options.addOption(bool, "have_v8", v8_archive != null);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = v8_archive != null,
    });
    root_module.addOptions("build_options", options);
    if (v8_archive) |archive| linkV8(root_module, target.result, archive);
    // The runtime's JavaScript sources live in the Rust tree and are shared
    // with it; embed them from there.
    for (core_js) |name| {
        root_module.addAnonymousImport(b.fmt("ext:core/{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("../libs/core/{s}", .{name})),
        });
    }

    const exe = b.addExecutable(.{ .name = "deno", .root_module = root_module });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the Zig port of deno");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

/// The rusty_v8 archive to link for `target`: the local one passed with
/// `-Dv8-archive`, or a download. Null if there is no prebuilt archive the
/// port can link for this target yet.
fn v8Archive(b: *std.Build, target: std.Target, local: ?[]const u8) ?std.Build.LazyPath {
    if (local) |path| return .{ .cwd_relative = path };

    const triple = rustTriple(target) orelse return null;
    const archive = for (rusty_v8_archives) |a| {
        if (std.mem.eql(u8, a.triple, triple)) break a;
    } else return null;

    // A build-time tool downloads the archive, checks its SHA-256 and
    // decompresses it. The build cache keys on the URL and hash, so it only
    // runs once.
    const fetch = b.addExecutable(.{
        .name = "fetch_v8",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_v8.zig"),
            .target = b.graph.host,
            .optimize = .fast,
        }),
    });
    const run = b.addRunArtifact(fetch);
    run.addArg(b.fmt(
        "https://github.com/denoland/rusty_v8/releases/download/v{s}/librusty_v8_simdutf_release_{s}.a.gz",
        .{ rusty_v8_version, triple },
    ));
    run.addArg(archive.sha256);
    return run.addOutputFileArg("librusty_v8.a");
}

fn linkV8(module: *std.Build.Module, target: std.Target, archive: std.Build.LazyPath) void {
    module.addObjectFile(archive);
    // The archive bundles its own libc++ (in the `std::__Cr` namespace), but
    // needs an unwinder. On Linux that's libgcc_s, as for the Rust build; on
    // macOS libSystem provides it.
    switch (target.os.tag) {
        .linux => module.linkSystemLibrary("gcc_s", .{}),
        // Abseil's time zone lookup (used by V8) needs CoreFoundation.
        .macos => module.linkFramework("CoreFoundation", .{}),
        else => {},
    }
}

fn rustTriple(target: std.Target) ?[]const u8 {
    const arch = switch (target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    return switch (target.os.tag) {
        .linux => if (target.abi == .gnu)
            (if (target.cpu.arch == .x86_64) "x86_64-unknown-linux-gnu" else "aarch64-unknown-linux-gnu")
        else
            null,
        .macos => if (std.mem.eql(u8, arch, "x86_64")) "x86_64-apple-darwin" else "aarch64-apple-darwin",
        else => null,
    };
}
