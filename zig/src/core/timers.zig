// Copyright 2018-2026 the Deno authors. MIT license.
//! Native half of `02_timers.js`, ported from core's user_timer.
//! JS owns the priority queue; Zig owns one monotonic wakeup and timer stats.
const std = @import("std");

pub const Timers = struct {
    start: std.Io.Timestamp,
    deadline_ms: ?f64 = null,
    refed: bool = false,
    active: std.AutoHashMapUnmanaged(i32, struct { repeat: bool, system: bool }) = .empty,

    pub fn init(io: std.Io) Timers {
        return .{ .start = std.Io.Clock.awake.now(io) };
    }

    pub fn now(self: *const Timers, io: std.Io) f64 {
        const ns = self.start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    }

    pub fn schedule(self: *Timers, io: std.Io, delay_ms: f64) void {
        if (delay_ms == -1) {
            self.refed = true;
        } else if (delay_ms == -2) {
            self.refed = false;
        } else {
            // JS normally supplies small nonnegative delays. Match Rust's
            // saturating float-to-u64 duration conversion for direct op calls.
            const delay = if (std.math.isNan(delay_ms) or delay_ms < 0) 0 else @min(delay_ms, @as(f64, @floatFromInt(std.math.maxInt(u64))));
            self.deadline_ms = self.now(io) + @trunc(delay);
        }
    }

    pub fn setExpiry(self: *Timers, io: std.Io, expiry: f64) void {
        if (expiry == 0) {
            self.deadline_ms = null;
            self.refed = false;
        } else {
            self.deadline_ms = self.now(io) + @max(1, @trunc(@abs(expiry) - self.now(io)));
            self.refed = expiry > 0;
        }
    }

    pub fn wait(self: *const Timers, io: std.Io) void {
        const ms = self.deadline_ms orelse return;
        const ns: i96 = @intFromFloat(ms * std.time.ns_per_ms);
        const deadline = self.start.addDuration(.{ .nanoseconds = ns });
        deadline.withClock(.awake).wait(io) catch {};
    }
};
