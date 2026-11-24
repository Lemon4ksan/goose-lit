// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// runner/verify_cli.goose - Unified verification gate: format check, typecheck, G-CRAP gate, optional LIT test.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.config;

struct VerifyCliArgs {
    target:    const u8[:] = "",
    max_gcrap: const u8[:] = "25",
    lit_test:  const u8[:] = "",
    cov_arg:   const u8[:] = "",
}

fn parse_verify_cli_args(all_args: const (u8[:])[:], cfg: VerifyCliArgs&) -> bool {
    var idx: i64 = 2;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--help" || a == "-h" {
            write_stdout("Usage: goose-lit verify <target.goose> [--max-gcrap <val>] [--lit <test.goose>] [--cov <val|file>]\n");
            return false;
        } else if a == "--max-gcrap" && idx + 1 < all_args.len {
            idx++;
            cfg.max_gcrap = all_args[idx];
        } else if a == "--lit" && idx + 1 < all_args.len {
            idx++;
            cfg.lit_test = all_args[idx];
        } else if a == "--cov" && idx + 1 < all_args.len {
            idx++;
            cfg.cov_arg = all_args[idx];
        } else if a == "--config" && idx + 1 < all_args.len {
            idx++;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option for verify: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        } else if cfg.target.len == 0 {
            cfg.target = a;
        } else {
            write_stdout("Error: unexpected positional argument for verify: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        }
        idx++;
    }
    if cfg.target.len == 0 {
        write_stdout("Usage: goose-lit verify <target.goose> [--max-gcrap <val>] [--lit <test.goose>] [--cov <val|file>]\n");
        return false;
    }
    return true;
}

fn handle_verify_cli(all_args: const (u8[:])[:], lit_cfg: const crap::LitConfig&) -> i32 {
    var cfg = VerifyCliArgs { .. };
    guard parse_verify_cli_args(all_args, cfg) else { return 2; }
    guard file_exists(cfg.target) || is_dir(cfg.target) else {
        write_stdout("Error: verify target not found: ");
        write_stdout(cfg.target);
        write_stdout("\n");
        return 1;
    }

    var prog: u8[>..] = [];
    arg(0, prog);
    if prog.len == 0 { prog.append("goose-lit"); }

    var out: u8[>..] = [];

    // 1. goose format --check
    write_stdout("[1/4] Checking Goose formatting...\n");
    if crap::exec_argv_capture("goose", "format", "--check", cfg.target, 0, out) != 0 {
        write_stdout("  [FAIL] Formatting check failed:\n");
        write_stdout(out[..]);
        return 1;
    }
    write_stdout("  [OK] Formatting check passed.\n");

    // 2. goose check
    write_stdout("[2/4] Typechecking target...\n");
    out.clear();
    if crap::exec_argv_capture("goose", "check", cfg.target, "", 0, out) != 0 {
        write_stdout("  [FAIL] Typecheck failed:\n");
        write_stdout(out[..]);
        return 1;
    }
    write_stdout("  [OK] Typecheck passed.\n");

    // 3. goose-lit gate
    write_stdout("[3/4] Running G-CRAP complexity & BCE gate...\n");
    var gate_cmd: u8[>..] = [];
    gate_cmd.push('"');
    gate_cmd.append(prog[..]);
    gate_cmd.append("\" gate \"");
    gate_cmd.append(cfg.target);
    gate_cmd.append("\" ");
    gate_cmd.append(cfg.max_gcrap);
    if cfg.cov_arg.len > 0 {
        gate_cmd.append(" --cov \"");
        gate_cmd.append(cfg.cov_arg);
        gate_cmd.push('"');
    } else if lit_cfg.cov_profile_buf.len == 0 || !file_exists(lit_cfg.cov_profile_buf[..]) {
        gate_cmd.append(" --cov 0.85");
    }
    out.clear();
    let gate_rc = crap::exec_capture(gate_cmd[..], out);
    write_stdout(out[..]);
    if gate_rc != 0 {
        return gate_rc;
    }

    // 4. Optional LIT test execution
    if cfg.lit_test.len > 0 {
        write_stdout("[4/4] Running LIT verification suite...\n");
        var lit_cmd: u8[>..] = [];
        lit_cmd.push('"');
        lit_cmd.append(prog[..]);
        lit_cmd.append("\" \"");
        lit_cmd.append(cfg.lit_test);
        lit_cmd.push('"');
        out.clear();
        let lit_rc = crap::exec_capture(lit_cmd[..], out);
        write_stdout(out[..]);
        if lit_rc != 0 { return lit_rc; }
    } else {
        write_stdout("[4/4] No --lit suite specified; skipping.\n");
    }

    write_stdout("VERIFY PASSED.\n");
    return 0;
}
