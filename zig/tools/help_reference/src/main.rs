// Copyright 2018-2026 the Deno authors. MIT license.
//! Prints `deno --help` (no arguments) or `deno <command> --help` as rendered
//! by the Rust CLI parser.

#![allow(dead_code)]

#[path = "../../../../libs/cli_parser/src/defs.rs"]
mod defs;
#[path = "../../../../libs/cli_parser/src/env_vars.rs"]
mod env_vars;
#[path = "../../../../libs/cli_parser/src/error.rs"]
mod error;
#[path = "../../../../libs/cli_parser/src/help.rs"]
mod help;
#[path = "../../../../libs/cli_parser/src/permission_help.rs"]
mod permission_help;
#[path = "../../../../libs/cli_parser/src/types.rs"]
mod types;

pub use types::*;

fn main() {
  let root = &defs::DENO_ROOT;
  match std::env::args().nth(1) {
    None => print!("{}", help::render_help(root)),
    Some(name) => match help::render_subcommand_help(root, &name) {
      Some(text) => print!("{text}"),
      None => {
        eprintln!("unknown command: {name}");
        std::process::exit(1);
      }
    },
  }
}
