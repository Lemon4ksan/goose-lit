// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit CLI entry point: Integrated LLVM-grade testing runtime for Goose.
import std;
import os;
import lit from ".";

extern fn sys_exit(code: i32) = "exit";

fn print_usage() {
    write_stdout("Usage: goose-lit [subcommand|path] [options]\n\n");
    write_stdout("Test runner, FileCheck matcher, binary wire stream verifier, and G-CRAP risk analyzer for Goose.\n\n");
    write_stdout("Subcommands:\n");
    write_stdout("  <path|file.goose>      Run // RUN: test directives in file or directory\n");
    write_stdout("  filecheck <file>       Verify standard input against FileCheck directives in <file>\n");
    write_stdout("  crap <path|file>       Run integrated G-CRAP complexity and safety risk radar\n");
    write_stdout("  version, -v            Print version\n");
    write_stdout("  help, -h               Print this help message\n\n");
    write_stdout("Options:\n");
    write_stdout("  --prefix <PREF>        FileCheck match prefix (default: CHECK)\n");
    write_stdout("  --verbose, -v          Verbose output of commands and matching\n\n");
}

fn handle_filecheck(file_arg: const u8[:], prefix_arg: const u8[:]) -> i32 {
    guard file_arg.len > 0 else {
        write_stdout("Error: filecheck requires a test source file\n");
        return 1;
    }

    var test_src: u8[>..] = [];
    if !read_file(file_arg, test_src) || test_src.len == 0 {
        write_stdout("Error reading test source: ");
        write_stdout(file_arg);
        write_stdout("\n");
        return 1;
    }

    // Read full standard input
    var input_buf: u8[>..] = [];
    read_stdin(input_buf);

    var diag: u8[>..] = [];
    let ok = lit::run_filecheck(input_buf[..], test_src[..], prefix_arg, diag);

    if !ok {
        write_stdout(diag[..]);
        return 1;
    }

    return 0;
}

fn main() {
    let all_args = args();
    if all_args.len <= 1 {
        print_usage();
        return;
    }

    let first = all_args[1];

    if first == "help" || first == "--help" || first == "-h" {
        print_usage();
        return;
    }

    if first == "version" || first == "--version" || first == "-v" {
        write_stdout("goose-lit version 0.1.0\n");
        return;
    }

    if first == "filecheck" {
        var prefix: const u8[:] = "CHECK";
        var file_target: const u8[:] = "";
        var idx: i64 = 2;
        while idx < all_args.len {
            let a = all_args[idx];
            if (a == "--prefix" || a == "-prefix") && idx + 1 < all_args.len {
                prefix = all_args[idx + 1];
                idx++;
            } else if !crap::slice_starts_with(a, "-") && file_target.len == 0 {
                file_target = a;
            }
            idx++;
        }
        let rc = handle_filecheck(file_target, prefix);
        sys_exit(rc);
        return;
    }

    if first == "crap" {
        let rc = crap::run_crap_cli();
        sys_exit(rc);
        return;
    }

    // Default mode: lit test runner over path or file
    var target_path = first;
    var verbose = false;

    var idx: i64 = 2;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--verbose" || a == "-v" {
            verbose = true;
        }
        idx++;
    }

    write_stdout("=== Goose LIT Test Runner ===\n");

    if file_exists(target_path) && !is_dir(target_path) {
        var res = lit::TestResult { .. };
        let ok = lit::run_single_lit_test(target_path, verbose, res);
        if ok {
            write_stdout("PASS: ");
            write_stdout(target_path);
            write_stdout(" (");
            var num_b: u8[..32] = [];
            format(num_b, res.duration_us / 1000);
            write_stdout(num_b[..]);
            write_stdout(" ms)\n");
            sys_exit(0);
        } else {
            write_stdout("FAIL: ");
            write_stdout(target_path);
            write_stdout("\n");
            write_stdout(res.diag[..]);
            sys_exit(1);
        }
        return;
    }

    var test_files: u8[>..] = [];
    let count = lit::discover_test_files(target_path, test_files);

    if count == 0 {
        write_stdout("No test files found in ");
        write_stdout(target_path);
        write_stdout("\n");
        sys_exit(0);
        return;
    }

    var passed_count: i64 = 0;
    var failed_count: i64 = 0;
    var total_time_us: i64 = 0;

    var cur: i64 = 0;
    let n = test_files.len;

    while cur < n {
        let start = cur;
        while cur < n && test_files[cur] != '\n' {
            cur += 1;
        }
        let t_file = test_files[start..cur];
        cur += 1;

        guard t_file.len > 0 else { continue; }

        var res = lit::TestResult { .. };
        let ok = lit::run_single_lit_test(t_file, verbose, res);
        total_time_us += res.duration_us;

        if ok {
            passed_count += 1;
            write_stdout("  [PASS] ");
            write_stdout(t_file);
            write_stdout(" (");
            var ms_b: u8[..32] = [];
            format(ms_b, res.duration_us / 1000);
            write_stdout(ms_b[..]);
            write_stdout(" ms)\n");
        } else {
            failed_count += 1;
            write_stdout("  [FAIL] ");
            write_stdout(t_file);
            write_stdout("\n");
            write_stdout(res.diag[..]);
        }
    }

    write_stdout("-----------------------------------------------------------------------\n");
    write_stdout("Test Summary: ");
    var p_b: u8[..32] = [];
    format(p_b, passed_count);
    write_stdout(p_b[..]);
    write_stdout(" passed, ");
    var f_b: u8[..32] = [];
    format(f_b, failed_count);
    write_stdout(f_b[..]);
    write_stdout(" failed in ");
    var tot_ms_b: u8[..32] = [];
    format(tot_ms_b, total_time_us / 1000);
    write_stdout(tot_ms_b[..]);
    write_stdout(" ms\n");

    if failed_count > 0 {
        sys_exit(1);
    } else {
        sys_exit(0);
    }
}
