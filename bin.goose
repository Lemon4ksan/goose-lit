// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit CLI entry point: Integrated LLVM-grade testing runtime for Goose.
import std;
import os;
import cli from ".";

extern fn sys_exit(code: i32) = "exit";

const LIT_VERSION_BYTES: const u8[:] = embed_file("version.txt");

fn print_usage() {
    write_stdout("Usage: goose-lit [subcommand|path] [options]\n\n");
    write_stdout("Test runner, FileCheck matcher, real branch coverage, profiler, fuzzer, and G-CRAP gate.\n\n");
    write_stdout("Subcommands:\n");
    write_stdout("  <path|file.goose>      Run // RUN: test directives in file or directory\n");
    write_stdout("  check <path...>        Typecheck .goose files in parallel (-j N, --filter <glob>)\n");
    write_stdout("  cov <src_target>       Instrument, run tests, merge .gcrap-cov & export LCOV\n");
    write_stdout("  verify <target.goose>  Format check, typecheck, G-CRAP gate, and optional --lit\n");
    write_stdout("  filecheck <file>       Verify standard input against FileCheck directives in <file>\n");
    write_stdout("  not <command...>       Execute command and invert exit status (0 -> 1, non-zero -> 0)\n");
    write_stdout("  gate <path|file> [max] Verify G-CRAP complexity and bounds safety gate (default ceiling: 25)\n");
    write_stdout("  crap <path|file>       Run integrated G-CRAP complexity and safety risk radar\n");
    write_stdout("  profile [bench.goose]  Build and run stage profiler / testing.B benchmark suite\n");
    write_stdout("  sloc [path...]         Run cycles-vs-SLOC radar, anti-packing, smells & Pareto gate\n");
    write_stdout("  fuzz [entry.goose]     Build and run SanCov / libFuzzer coverage-guided fuzzer\n");
    write_stdout("  inspect <file|hex>     Dump byte buffer in hex/ASCII or 128-bit SIMD lanes\n");
    write_stdout("  version, -V, --version Print version\n");
    write_stdout("  help, -h, --help       Print this help message\n\n");
    write_stdout("Options:\n");
    write_stdout("  -j, --jobs <N|auto>    Parallel workers ('auto' caps by CPU & free RAM; default: 1 / .litconfig)\n");
    write_stdout("  --filter <glob>        Filter test or source paths by wildcard glob (*, ?)\n");
    write_stdout("  --fail-fast, -x        Stop scheduling new tests after first failure\n");
    write_stdout("  --json                 Emit structured JSON test summary\n");
    write_stdout("  --config <file>        Load custom configuration file (default: .litconfig)\n");
    write_stdout("  --prefix <PREF>        FileCheck match prefix (default: CHECK)\n");
    write_stdout("  --verbose, -v          Verbose output of commands and matching\n");
    write_stdout("  --list-tests           List discovered test files without executing them\n");
    write_stdout("  --allow-empty          Return exit code 0 when no test files are discovered\n");
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

struct LitWorkerCfg {
    list_path:   u8[..256] = [],
    timeout_sec: i64       = 60,
    total:       i32       = 0,
    verbose:     bool      = false,
    fail_fast:   bool      = false,
}

fn lit_status_code(st: lit::TestStatus) -> i32 {
    return match st {
        Pass => 0,
        Fail => 1,
        XFail => 2,
        XPass => 3,
        Unsupported => 4,
        Timeout => 5,
    };
}

fn lit_get_line_at(blob: const u8[:], idx: i32, out: u8[>..]&) -> bool {
    var cur:   i32 = 0;
    var start: i64 = 0;
    while start < blob.len {
        let rel_nl = crap::slice_index_of_byte(blob[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { blob.len };
        if cur == idx {
            out.append(crap::trim_ascii(blob[start..end]));
            return out.len > 0;
        }
        cur++;
        start = end + 1;
    }
    return false;
}

fn filter_test_list(raw: const u8[:], filter_glob: const u8[:], out: u8[>..]&) -> i32 {
    var total: i32 = 0;
    var start: i64 = 0;
    while start < raw.len {
        let rel_nl = crap::slice_index_of_byte(raw[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { raw.len };
        let fp = crap::trim_ascii(raw[start..end]);
        start = end + 1;
        guard fp.len > 0 else { continue; }
        if filter_glob.len > 0 {
            let last_sl = crap::slice_last_index_of_byte(fp, '/');
            let base = if last_sl >= 0 { fp[last_sl + 1..] } else { fp };
            if !crap::glob_match(filter_glob, fp) && !crap::glob_match(filter_glob, base) {
                continue;
            }
        }
        out.append(fp);
        out.push('\n');
        total++;
    }
    return total;
}

thread_fn lit_parallel_worker(cfg: LitWorkerCfg) {
    var list_blob: u8[>..] = [];
    guard read_file(cfg.list_path[..], list_blob) else { return; }

    var fpath:     u8[>..]  = [];
    var slot_path: u8[..64] = [];
    var slot_buf:  u8[>..]  = [];

    while true {
        if cfg.fail_fast && crap::native_atomic_get_stop() != 0 {
            break;
        }
        let idx = crap::native_work_claim(cfg.total);
        if idx < 0 { break; }

        fpath.clear();
        guard lit_get_line_at(list_blob[..], idx, fpath) else { continue; }

        var res = lit::TestResult { .. };
        let _ = lit::run_single_lit_test_with_timeout(fpath[..], cfg.verbose, cfg.timeout_sec, res);
        let sc = lit_status_code(res.status);
        if cfg.fail_fast && (sc == 1 || sc == 3 || sc == 5) {
            crap::native_atomic_set_stop(1);
        }

        slot_buf.clear();
        format(slot_buf, sc, " ", res.duration_us, "\n");
        slot_buf.append(res.diag[..]);

        slot_path.clear();
        slot_path.append(".lit/cache/.lit_slot_");
        format(slot_path, idx);
        slot_path.append(".res");
        let _ = write_file(slot_path[..], slot_buf[..]);
    }
}

fn run_lit_suite(
    target_path: const u8[:],
    verbose:     bool,
    list_only:   bool,
    allow_empty: bool,
    jobs:        i64,
    filter_glob: const u8[:],
    fail_fast:   bool,
    json_out:    bool,
    lit_cfg:     const crap::LitConfig&,
) -> i32 {
    if !file_exists(target_path) && !is_dir(target_path) {
        write_stdout("Error: path does not exist: ");
        write_stdout(target_path);
        write_stdout("\n");
        return 2;
    }

    if list_only {
        if file_exists(target_path) && !is_dir(target_path) {
            write_stdout(target_path);
            write_stdout("\n");
            return 0;
        }
        var raw_listed: u8[>..] = [];
        let _ = lit::discover_test_files_filtered(target_path, lit_cfg.exclude_buf[..], raw_listed);
        var filtered_list: u8[>..] = [];
        let lcount = filter_test_list(raw_listed[..], filter_glob, filtered_list);
        if lcount == 0 {
            return if allow_empty { 0 } else { 2 };
        }
        write_stdout(filtered_list[..]);
        return 0;
    }

    if !json_out {
        write_stdout("=== Goose LIT Test Runner ===\n");
    }

    if file_exists(target_path) && !is_dir(target_path) {
        var res = lit::TestResult { .. };
        let _ = lit::run_single_lit_test_with_timeout(target_path, verbose, lit_cfg.timeout_sec, res);
        let sc = lit_status_code(res.status);
        if json_out {
            var jb: u8[..256] = [];
            jb.append("{\"passed\": ");
            format(jb, if sc == 0 { 1 } else { 0 }, ", \"failed\": ");
            format(jb, if sc == 1 || sc == 3 || sc == 5 { 1 } else { 0 }, ", \"xfailed\": ");
            format(jb, if sc == 2 { 1 } else { 0 }, ", \"unsupported\": ");
            format(jb, if sc == 4 { 1 } else { 0 }, ", \"duration_ms\": ");
            format(jb, res.duration_us / 1000, "}\n");
            write_stdout(jb[..]);
            return if sc == 0 || sc == 2 || sc == 4 { 0 } else { 1 };
        }
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

    var raw_files: u8[>..] = [];
    let _ = lit::discover_test_files_filtered(target_path, lit_cfg.exclude_buf[..], raw_files);
    var test_files: u8[>..] = [];
    let total = filter_test_list(raw_files[..], filter_glob, test_files);

    if total == 0 {
        if !json_out {
            write_stdout("No test files found in ");
            write_stdout(target_path);
            write_stdout("\n");
        }
        return if allow_empty { 0 } else { 2 };
    }

    var passed_count:      i64 = 0;
    var failed_count:      i64 = 0;
    var xfail_count:       i64 = 0;
    var xpass_count:       i64 = 0;
    var unsupported_count: i64 = 0;
    var total_time_us:     i64 = 0;

    let eff_jobs = if jobs > 0 {
        jobs
    } else if jobs < 0 || lit_cfg.jobs_auto {
        crap::default_auto_jobs(2200)
    } else if lit_cfg.has_jobs && lit_cfg.jobs > 0 {
        lit_cfg.jobs
    } else {
        1
    };

    if eff_jobs > 1 && total > 1 {
        crap::ensure_lit_cache_dir();
        let list_path: const u8[:] = ".lit/cache/.lit_tests.list";
        let _ = write_file(list_path, test_files[..]);
        let n_workers = min(eff_jobs, total);

        crap::native_work_reset();
        var wcfg = LitWorkerCfg {
            timeout_sec: lit_cfg.timeout_sec,
            total:       total,
            verbose:     verbose,
            fail_fast:   fail_fast,
        };
        let _ = crap::set_bounded(wcfg.list_path, list_path);

        var tids: i64[>..] = [];
        for _ in n_workers {
            tids.push(thread_spawn(lit_parallel_worker, wcfg));
        }
        for ti in tids.len {
            var why: u8[>..] = [];
            let _ = thread_wait(tids[ti], why);
        }

        var fp_buf:    u8[>..] = [];
        var slot_path: u8[>..] = [];
        var slot_data: u8[>..] = [];

        for idx in total {
            fp_buf.clear();
            let _ = lit_get_line_at(test_files[..], idx, fp_buf);
            slot_path.clear();
            slot_path.append(".lit/cache/.lit_slot_");
            format(slot_path, idx);
            slot_path.append(".res");

            slot_data.clear();
            if read_file(slot_path[..], slot_data) {
                delete_file(slot_path[..]);
                let nl = crap::slice_index_of_byte(slot_data[..], '\n');
                let head = if nl >= 0 { slot_data[..nl] } else { slot_data[..] };
                let diag = if nl >= 0 && nl + 1 < slot_data.len { slot_data[nl + 1..] } else { "" };
                let sp = crap::slice_index_of_byte(head, ' ');
                let sc_str = if sp > 0 { head[..sp] } else { head };
                let dur_str = if sp > 0 && sp + 1 < head.len { head[sp + 1..] } else { "0" };
                let sc, _ = crap::parse_i64_slice(sc_str);
                let dur_us, _ = crap::parse_i64_slice(dur_str);
                total_time_us += dur_us;

                if sc == 0 {
                    passed_count += 1;
                    if !json_out {
                        var line: u8[>..] = [];
                        line.append("  [PASS] ");
                        line.append(fp_buf[..]);
                        format(line, " (", dur_us / 1000, " ms)\n");
                        write_stdout(line[..]);
                    }
                } else if sc == 2 {
                    xfail_count += 1;
                    if !json_out {
                        var line: u8[>..] = [];
                        line.append("  [XFAIL] ");
                        line.append(fp_buf[..]);
                        format(line, " (", dur_us / 1000, " ms)\n");
                        write_stdout(line[..]);
                    }
                } else if sc == 4 {
                    unsupported_count += 1;
                    if !json_out {
                        write_stdout("  [UNSUPPORTED] ");
                        write_stdout(fp_buf[..]);
                        write_stdout("\n");
                    }
                } else if sc == 5 {
                    failed_count += 1;
                    if !json_out {
                        write_stdout("  [TIMEOUT] ");
                        write_stdout(fp_buf[..]);
                        write_stdout("\n");
                        write_stdout(diag);
                    }
                } else if sc == 3 {
                    xpass_count += 1;
                    failed_count += 1;
                    if !json_out {
                        write_stdout("  [XPASS] ");
                        write_stdout(fp_buf[..]);
                        write_stdout("\n");
                        write_stdout(diag);
                    }
                } else {
                    failed_count += 1;
                    if !json_out {
                        write_stdout("  [FAIL] ");
                        write_stdout(fp_buf[..]);
                        write_stdout("\n");
                        write_stdout(diag);
                    }
                }
            }
        }
        if file_exists(list_path) { delete_file(list_path); }
    } else {
        var cur: i64 = 0;
        let n = test_files.len;
        while cur < n {
            let start = cur;
            while cur < n && test_files[cur] != '\n' { cur += 1; }
            let t_file = test_files[start..cur];
            cur += 1;
            guard t_file.len > 0 else { continue; }

            var res = lit::TestResult { .. };
            let _ = lit::run_single_lit_test_with_timeout(t_file, verbose, lit_cfg.timeout_sec, res);
            total_time_us += res.duration_us;

            if res.status == lit::TestStatus.Pass {
                passed_count += 1;
                if !json_out {
                    write_stdout("  [PASS] ");
                    write_stdout(t_file);
                    write_stdout(" (");
                    var ms_b: u8[..32] = [];
                    format(ms_b, res.duration_us / 1000);
                    write_stdout(ms_b[..]);
                    write_stdout(" ms)\n");
                }
            } else if res.status == lit::TestStatus.XFail {
                xfail_count += 1;
                if !json_out {
                    write_stdout("  [XFAIL] ");
                    write_stdout(t_file);
                    write_stdout(" (");
                    var ms_b: u8[..32] = [];
                    format(ms_b, res.duration_us / 1000);
                    write_stdout(ms_b[..]);
                    write_stdout(" ms)\n");
                }
            } else if res.status == lit::TestStatus.Unsupported {
                unsupported_count += 1;
                if !json_out {
                    write_stdout("  [UNSUPPORTED] ");
                    write_stdout(t_file);
                    write_stdout("\n");
                }
            } else if res.status == lit::TestStatus.Timeout {
                failed_count += 1;
                if !json_out {
                    write_stdout("  [TIMEOUT] ");
                    write_stdout(t_file);
                    write_stdout("\n");
                    write_stdout(res.diag[..]);
                }
                if fail_fast { break; }
            } else if res.status == lit::TestStatus.XPass {
                xpass_count += 1;
                failed_count += 1;
                if !json_out {
                    write_stdout("  [XPASS] ");
                    write_stdout(t_file);
                    write_stdout("\n");
                    write_stdout(res.diag[..]);
                }
                if fail_fast { break; }
            } else {
                failed_count += 1;
                if !json_out {
                    write_stdout("  [FAIL] ");
                    write_stdout(t_file);
                    write_stdout("\n");
                    write_stdout(res.diag[..]);
                }
                if fail_fast { break; }
            }
        }
    }

    if json_out {
        var jb: u8[>..] = [];
        jb.append("{\"passed\": ");
        format(jb, passed_count, ", \"failed\": ", failed_count, ", \"xfailed\": ", xfail_count);
        format(jb, ", \"unsupported\": ", unsupported_count, ", \"duration_ms\": ", total_time_us / 1000, "}\n");
        write_stdout(jb[..]);
        return if failed_count == 0 && xpass_count == 0 { 0 } else { 1 };
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
        if all_args[ci] == "--config" {
            if ci + 1 >= all_args.len {
                write_stdout("Error: --config requires a file path\n");
                sys_exit(2);
                return;
            }
            custom_config = all_args[ci + 1];
            break;
        }
    }
    var lit_cfg = crap::LitConfig { .. };
    crap::load_lit_config(custom_config, lit_cfg);

    if all_args.len <= 1 {
        let cfg_tests = lit_cfg.tests_dir_buf[..];
        if cfg_tests.len > 0 && (is_dir(cfg_tests) || file_exists(cfg_tests)) {
            let rc = run_lit_suite(cfg_tests, false, false, false, 0, "", false, false, lit_cfg);
            sys_exit(rc);
            return;
        } else if is_dir("tests") || file_exists("tests") {
            let rc = run_lit_suite("tests", false, false, false, 0, "", false, false, lit_cfg);
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

    if first == "version" || first == "--version" || first == "-V" {
        write_stdout("goose-lit version ");
        write_stdout(crap::trim_ascii(LIT_VERSION_BYTES));
        write_stdout("\n");
        return;
    }

    if first == "not" {
        guard all_args.len > 2 else {
            write_stdout("Error: not requires a command to run\n");
            sys_exit(2);
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
            if a == "--prefix" || a == "-prefix" {
                guard idx + 1 < all_args.len else {
                    write_stdout("Error: --prefix requires a prefix string\n");
                    sys_exit(2);
                    return;
                }
                crap::set_bounded(prefix_buf, all_args[idx + 1]);
                idx++;
            } else if a == "--config" {
                idx++;
            } else if crap::slice_starts_with(a, "-") {
                write_stdout("Error: unknown option for filecheck: ");
                write_stdout(a);
                write_stdout("\n");
                sys_exit(2);
                return;
            } else if file_target.len == 0 {
                file_target = a;
            } else {
                write_stdout("Error: unexpected argument for filecheck: ");
                write_stdout(a);
                write_stdout("\n");
                sys_exit(2);
                return;
            }
            idx++;
        }
        guard file_target.len > 0 else {
            write_stdout("Error: filecheck requires a test source file\n");
            sys_exit(2);
            return;
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
            } else if a == "--offset" {
                guard idx + 1 < all_args.len else {
                    write_stdout("Error: --offset requires a numeric value\n");
                    sys_exit(2);
                    return;
                }
                let num, ok = crap::parse_i64_slice(all_args[idx + 1]);
                guard ok && num >= 0 else {
                    write_stdout("Error: invalid --offset value\n");
                    sys_exit(2);
                    return;
                }
                offset = num;
                idx++;
            } else if a == "--config" {
                idx++;
            } else if crap::slice_starts_with(a, "-") {
                write_stdout("Error: unknown option for inspect: ");
                write_stdout(a);
                write_stdout("\n");
                sys_exit(2);
                return;
            } else if target.len == 0 {
                target = a;
            }
            idx++;
        }
        let rc = handle_inspect(target, is_simd, simd_byte, offset);
        sys_exit(rc);
        return;
    }

    if first == "check" {
        let rc = lit::handle_check_cli(all_args[..], lit_cfg);
        sys_exit(rc);
        return;
    }

    if first == "cov" {
        let rc = lit::handle_cov_cli(all_args[..], lit_cfg);
        sys_exit(rc);
        return;
    }

    if first == "verify" {
        let rc = lit::handle_verify_cli(all_args[..], lit_cfg);
        sys_exit(rc);
        return;
    }

    if first == "profile" {
        let rc = lit::handle_profile_cli(all_args[..], lit_cfg);
        sys_exit(rc);
        return;
    }

    if first == "sloc" {
        let rc = lit::handle_sloc_cli(all_args[..], lit_cfg);
        sys_exit(rc);
        return;
    }

    if first == "fuzz" {
        let rc = lit::handle_fuzz_cli(all_args[..], lit_cfg);
        sys_exit(rc);
        return;
    }

    // Default mode: lit test runner over path or file
    var cli_target: const u8[:] = "";
    var verbose = false;
    var list_only = false;
    var allow_empty = false;
    var fail_fast = false;
    var json_out = false;
    var jobs:        i64         = 0;
    var filter_glob: const u8[:] = "";

    var idx: i64 = 1;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--verbose" || a == "-v" {
            verbose = true;
        } else if a == "--list-tests" {
            list_only = true;
        } else if a == "--allow-empty" {
            allow_empty = true;
        } else if a == "--fail-fast" || a == "-x" {
            fail_fast = true;
        } else if a == "--json" {
            json_out = true;
        } else if a == "-j" || a == "--jobs" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --jobs requires a positive integer or 'auto'\n");
                sys_exit(2);
                return;
            }
            let j_arg = all_args[idx + 1];
            if j_arg == "auto" {
                jobs = -1;
            } else {
                let j_val, ok = crap::parse_i64_slice(j_arg);
                guard ok && j_val > 0 else {
                    write_stdout("Error: --jobs must be a positive integer or 'auto'\n");
                    sys_exit(2);
                    return;
                }
                jobs = j_val;
            }
            idx++;
        } else if a == "--filter" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --filter requires a glob pattern\n");
                sys_exit(2);
                return;
            }
            filter_glob = all_args[idx + 1];
            idx++;
        } else if a == "--timeout" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --timeout requires a positive integer in seconds\n");
                sys_exit(2);
                return;
            }
            let t_val, ok = crap::parse_i64_slice(all_args[idx + 1]);
            guard ok && t_val > 0 else {
                write_stdout("Error: --timeout must be a positive integer\n");
                sys_exit(2);
                return;
            }
            lit_cfg.timeout_sec = t_val;
            lit_cfg.has_timeout = true;
            idx++;
        } else if a == "--config" {
            idx++;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option: ");
            write_stdout(a);
            write_stdout("\n");
            sys_exit(2);
            return;
        } else if cli_target.len == 0 {
            cli_target = a;
        } else {
            write_stdout("Error: unexpected positional argument: ");
            write_stdout(a);
            write_stdout("\n");
            sys_exit(2);
            return;
        }
        idx++;
    }

    if cli_target.len > 0 {
        let rc = run_lit_suite(cli_target, verbose, list_only, allow_empty, jobs, filter_glob, fail_fast, json_out, lit_cfg);
        sys_exit(rc);
        return;
    }

    if lit_cfg.tests_dir_buf.len > 0 && (is_dir(lit_cfg.tests_dir_buf[..]) || file_exists(lit_cfg.tests_dir_buf[..])) {
        let rc = run_lit_suite(lit_cfg.tests_dir_buf[..], verbose, list_only, allow_empty, jobs, filter_glob, fail_fast, json_out, lit_cfg);
        sys_exit(rc);
        return;
    }

    if is_dir("tests") || file_exists("tests") {
        let rc = run_lit_suite("tests", verbose, list_only, allow_empty, jobs, filter_glob, fail_fast, json_out, lit_cfg);
        sys_exit(rc);
        return;
    }

    print_usage();
}
