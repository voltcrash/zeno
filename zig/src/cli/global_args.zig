// Copyright 2018-2026 the Deno authors. MIT license.
//! Arguments accepted at the root and by every subcommand, ported from
//! `GLOBAL_ARGS` in `libs/cli_parser/src/defs.rs`.

const Arg = @import("types.zig").Arg;

pub const all = [_]Arg{
    .{
        .name = "env-file",
        .long = "env-file",
        .long_aliases = &.{"env"},
        .action = .append,
        .num_args = .optional,
        .require_equals = true,
        .global = true,
        .help = "Load environment variables from local file\n  Only the first environment variable with a given key is used.\n  Existing process environment variables are not overwritten, so if variables with the same names already exist in the environment, their values will be preserved.\n  Where multiple declarations for the same environment variable exist in your .env file, the first one encountered is applied. This is determined by the order of the files you pass as arguments.",
    },
    .{
        .name = "help",
        .short = 'h',
        .long = "help",
        .action = .append,
        .num_args = .optional,
        .require_equals = true,
        .global = true,
    },
    .{
        .name = "version",
        .short = 'V',
        .long = "version",
        .action = .set_true,
        .num_args = .{ .exact = 0 },
        .short_aliases = &.{'v'},
        .global = true,
        .help = "Print version",
    },
    .{
        .name = "log-level",
        .short = 'L',
        .long = "log-level",
        .action = .set,
        .num_args = .{ .exact = 1 },
        .choices = &.{ "trace", "debug", "info" },
        .global = true,
        .help = "Set log level",
    },
    .{
        .name = "quiet",
        .short = 'q',
        .long = "quiet",
        .action = .set_true,
        .num_args = .{ .exact = 0 },
        .global = true,
        .help = "Suppress diagnostic output",
    },
};
