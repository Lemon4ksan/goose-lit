// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit CLI entry point: Integrated LLVM-grade testing runtime for Goose.
import std;
import os;
import lit from ".";

extern fn sys_exit(code: i32) = "exit";

const LIT_VERSION_BYTES: const u8[:] = embed_file("version.txt");

fn print_usage() {
    write_stdout("Usage: goose-lit [subcommand|path] [options]\n\n");
    write_stdout("Test runner, FileCheck matcher, binary wire stream verifier, and G-CRAP risk analyzer for Goose.\n\n");
    write_stdout("Subcommands:\n");
    write_stdout("  <path|file.goose>      Run // RUN: test directives in file or directory\n");
    write_stdout("  filecheck <file>       Verify standard input against FileCheck directives in <file>\n");
    write_stdout("  not <command...>       Execute command and invert exit status (0 -> 1, non-zero -> 0)\n");
    write_stdout("  gate <path|file> [max] Verify G-CRAP complexity and bounds safety gate (default ceiling: 25)\n");
    write_stdout("  crap <path|file>       Run integrated G-CRAP complexity and safety risk radar\n");
    write_stdout("  inspect <file|hex>     Dump byte buffer in hex/ASCII or 128-bit SIMD lanes\n");
    write_stdout("  version, -v            Print version\n");
    write_stdout("  help, -h               Print this help message\n\n");
    write_stdout("Options:\n");
    write_stdout("  --config <file>        Load custom configuration file (default: .litconfig)\n");
    write_stdout("  --prefix <PREF>        FileCheck match prefix (default: CHECK)\n");
    write_stdout("  --verbose, -v          Verbose output of commands and matching\n");
    write_stdout("  --timeout <sec>        Per-command timeout in seconds (default: 60)\n");
    write_stdout("  --simd [byte]          SIMD lane match byte for inspect (default: '/')\n");
    write_stdout("  --offset <N>           Base address offset for inspect hexdump (default: 0)\n\n");
}

fn handle_inspect(target: const u8[:], is_simd: bool, simd_byte: u8, offset: i64) -> i32 {
    guard target.len > 0 else {
        write_stdout("Error: inspect requires a file path, hex string, or quoted payload\n");
        return 1;
    }

    var payload: u8[>..] = [];
    if file_exists(target) {
        if !read_file(target, payload) {
            write_stdout("Error: failed to read file: ");
            write_stdout(target);
            write_stdout("\n");
            return 1;
        }
    } else {
        if !lit::parse_packet_payload(target, payload) || payload.len == 0 {
            write_stdout("Error: failed to parse hex or ASCII payload: ");
            write_stdout(target);
            write_stdout("\n");
            return 1;
        }
    }

    var out_diag: u8[>..] = [];
    if is_simd {
        lit::format_simd_lanes(payload[..], simd_byte, offset, out_diag);
    } else {
        lit::format_hexdump(payload[..], offset, out_diag);
    }

    write_stdout(out_diag[..]);
    return 0;
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

fn run_lit_suite(target_path: const u8[:], verbose: bool, lit_cfg: const crap::LitConfig&) -> i32 {
    write_stdout("=== Goose LIT Test Runner ===\n");

    if file_exists(target_path) && !is_dir(target_path) {
        var res = lit::TestResult { .. };
        let ok = lit::run_single_lit_test_with_timeout(target_path, verbose, lit_cfg.timeout_sec, res);
        if res.status == lit::TestStatus.Pass {
            write_stdout("PASS: ");
            write_stdout(target_path);
            write_stdout(" (");
            var num_b: u8[..32] = [];
            format(num_b, res.duration_us / 1000);
            write_stdout(num_b[..]);
            write_stdout(" ms)\n");
            return 0;
        } else if res.status == lit::TestStatus.XFail {
            write_stdout("XFAIL: ");
            write_stdout(target_path);
            write_stdout(" (");
            var num_b: u8[..32] = [];
            format(num_b, res.duration_us / 1000);
            write_stdout(num_b[..]);
            write_stdout(" ms)\n");
            return 0;
        } else if res.status == lit::TestStatus.Unsupported {
            write_stdout("UNSUPPORTED: ");
            write_stdout(target_path);
            write_stdout("\n");
            return 0;
        } else if res.status == lit::TestStatus.Timeout {
            write_stdout("TIMEOUT: ");
            write_stdout(target_path);
            write_stdout("\n");
            write_stdout(res.diag[..]);
            return 1;
        } else if res.status == lit::TestStatus.XPass {
            write_stdout("XPASS: ");
            write_stdout(target_path);
            write_stdout("\n");
            write_stdout(res.diag[..]);
            return 1;
        } else {
            write_stdout("FAIL: ");
            write_stdout(target_path);
            write_stdout("\n");
            write_stdout(res.diag[..]);
            return 1;
        }
    }

    var test_files: u8[>..] = [];
    let count = lit::discover_test_files_filtered(target_path, lit_cfg.exclude_buf[..], test_files);

    if count == 0 {
        write_stdout("No test files found in ");
        write_stdout(target_path);
        write_stdout("\n");
        return 0;
    }

    var passed_count:      i64 = 0;
    var failed_count:      i64 = 0;
    var xfail_count:       i64 = 0;
    var xpass_count:       i64 = 0;
    var unsupported_count: i64 = 0;
    var total_time_us:     i64 = 0;

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
        let ok = lit::run_single_lit_test_with_timeout(t_file, verbose, lit_cfg.timeout_sec, res);
        total_time_us += res.duration_us;

        if res.status == lit::TestStatus.Pass {
            passed_count += 1;
            write_stdout("  [PASS] ");
            write_stdout(t_file);
            write_stdout(" (");
            var ms_b: u8[..32] = [];
            format(ms_b, res.duration_us / 1000);
            write_stdout(ms_b[..]);
            write_stdout(" ms)\n");
        } else if res.status == lit::TestStatus.XFail {
            xfail_count += 1;
            write_stdout("  [XFAIL] ");
            write_stdout(t_file);
            write_stdout(" (");
            var ms_b: u8[..32] = [];
            format(ms_b, res.duration_us / 1000);
            write_stdout(ms_b[..]);
            write_stdout(" ms)\n");
        } else if res.status == lit::TestStatus.Unsupported {
            unsupported_count += 1;
            write_stdout("  [UNSUPPORTED] ");
            write_stdout(t_file);
            write_stdout("\n");
        } else if res.status == lit::TestStatus.Timeout {
            failed_count += 1;
            write_stdout("  [TIMEOUT] ");
            write_stdout(t_file);
            write_stdout("\n");
            write_stdout(res.diag[..]);
        } else if res.status == lit::TestStatus.XPass {
            xpass_count += 1;
            failed_count += 1;
            write_stdout("  [XPASS] ");
            write_stdout(t_file);
            write_stdout("\n");
            write_stdout(res.diag[..]);
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
    write_stdout(" failed, ");
    var x_b: u8[..32] = [];
    format(x_b, xfail_count);
    write_stdout(x_b[..]);
    write_stdout(" xfailed, ");
    var u_b: u8[..32] = [];
    format(u_b, unsupported_count);
    write_stdout(u_b[..]);
    write_stdout(" unsupported in ");
    var tot_ms_b: u8[..32] = [];
    format(tot_ms_b, total_time_us / 1000);
    write_stdout(tot_ms_b[..]);
    write_stdout(" ms\n");

    if failed_count == 0 && xpass_count == 0 {
        return 0;
    } else {
        return 1;
    }
}

fn main() {
    let all_args = args();

    var custom_config: const u8[:] = "";
    for ci in all_args.len {
        if all_args[ci] == "--config" && ci + 1 < all_args.len {
            custom_config = all_args[ci + 1];
            break;
        }
    }
    var lit_cfg = crap::LitConfig { .. };
    crap::load_lit_config(custom_config, lit_cfg);

    if all_args.len <= 1 {
        let cfg_tests = lit_cfg.tests_dir_buf[..];
        if cfg_tests.len > 0 && (is_dir(cfg_tests) || file_exists(cfg_tests)) {
            let rc = run_lit_suite(cfg_tests, false, lit_cfg);
            sys_exit(rc);
            return;
        } else if is_dir("tests") || file_exists("tests") {
            let rc = run_lit_suite("tests", false, lit_cfg);
            sys_exit(rc);
            return;
        }
        print_usage();
        return;
    }

    let first = all_args[1];

    if first == "help" || first == "--help" || first == "-h" {
        print_usage();
        return;
    }

    if first == "version" || first == "--version" || first == "-v" {
        write_stdout("goose-lit version ");
        write_stdout(crap::trim_ascii(LIT_VERSION_BYTES));
        write_stdout("\n");
        return;
    }

    if first == "not" {
        guard all_args.len > 2 else {
            write_stdout("Error: not requires a command to run\n");
            sys_exit(1);
            return;
        }
        var cmd_str: u8[>..] = [];
        var idx:     i64     = 2;
        while idx < all_args.len {
            if idx > 2 { cmd_str.push(' '); }
            cmd_str.append(all_args[idx]);
            idx++;
        }
        var run_out: u8[>..] = [];
        let rc = crap::exec_capture(cmd_str[..], run_out);
        write_stdout(run_out[..]);
        if rc == 0 {
            sys_exit(1);
        } else {
            sys_exit(0);
        }
        return;
    }

    if first == "filecheck" {
        var prefix_buf: u8[..32] = [];
        if lit_cfg.prefix_buf.len > 0 {
            prefix_buf.append(lit_cfg.prefix_buf[..]);
        } else {
            prefix_buf.append("CHECK");
        }
        var file_target: const u8[:] = "";
        var idx:         i64         = 2;
        while idx < all_args.len {
            let a = all_args[idx];
            if (a == "--prefix" || a == "-prefix") && idx + 1 < all_args.len {
                crap::set_bounded(prefix_buf, all_args[idx + 1]);
                idx++;
            } else if a == "--config" && idx + 1 < all_args.len {
                idx++;
            } else if !crap::slice_starts_with(a, "-") && file_target.len == 0 {
                file_target = a;
            }
            idx++;
        }
        let rc = handle_filecheck(file_target, prefix_buf[..]);
        sys_exit(rc);
        return;
    }

    if first == "gate" || first == "crap" {
        let rc = crap::run_crap_cli();
        sys_exit(rc);
        return;
    }

    if first == "inspect" {
        var target: const u8[:] = "";
        var is_simd = false;
        var simd_byte: u8  = 47; // '/'
        var offset:    i64 = 0;

        var idx: i64 = 2;
        while idx < all_args.len {
            let a = all_args[idx];
            if a == "--simd" {
                is_simd = true;
                if idx + 1 < all_args.len && !crap::slice_starts_with(all_args[idx + 1], "-") {
                    let sb = all_args[idx + 1];
                    let num, ok = crap::parse_i64_slice(sb);
                    if ok {
                        simd_byte = (num & 0xFF) as! u8;
                    } else if sb.len == 1 {
                        simd_byte = sb[0];
                    }
                    idx++;
                }
            } else if a == "--offset" && idx + 1 < all_args.len {
                let num, ok = crap::parse_i64_slice(all_args[idx + 1]);
                if ok { offset = num; }
                idx++;
            } else if !crap::slice_starts_with(a, "-") && target.len == 0 {
                target = a;
            }
            idx++;
        }
        let rc = handle_inspect(target, is_simd, simd_byte, offset);
        sys_exit(rc);
        return;
    }

    // Default mode: lit test runner over path or file
    var cli_target: const u8[:] = "";
    var verbose = false;

    var idx: i64 = 1;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--verbose" || a == "-v" {
            verbose = true;
        } else if a == "--timeout" && idx + 1 < all_args.len {
            let t_val, ok = crap::parse_i64_slice(all_args[idx + 1]);
            if ok && t_val > 0 {
                lit_cfg.timeout_sec = t_val;
                lit_cfg.has_timeout = true;
            }
            idx++;
        } else if a == "--config" && idx + 1 < all_args.len {
            idx++;
        } else if !crap::slice_starts_with(a, "-") && cli_target.len == 0 {
            cli_target = a;
        }
        idx++;
    }

    if cli_target.len > 0 {
        let rc = run_lit_suite(cli_target, verbose, lit_cfg);
        sys_exit(rc);
        return;
    }

    if lit_cfg.tests_dir_buf.len > 0 && (is_dir(lit_cfg.tests_dir_buf[..]) || file_exists(lit_cfg.tests_dir_buf[..])) {
        let rc = run_lit_suite(lit_cfg.tests_dir_buf[..], verbose, lit_cfg);
        sys_exit(rc);
        return;
    }

    if is_dir("tests") || file_exists("tests") {
        let rc = run_lit_suite("tests", verbose, lit_cfg);
        sys_exit(rc);
        return;
    }

    print_usage();
}
