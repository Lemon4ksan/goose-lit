// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// fuzz/cli.goose - Coverage-guided SanCov & libFuzzer build/run CLI for goose-lit.
//
// Compiles a Goose fuzz entrypoint exporting the 3-function contract:
//   export fn lit_fuzz_target_count() -> i32
//   export fn lit_fuzz_target_name(target_id: i32, dst: u8[:]) -> i32
//   export fn lit_fuzz_test_one(target_id: i32, raw: const u8[:]) -> u64
// links it against `shim/fuzz_driver.c` with `-fsanitize-coverage=trace-pc`
// (or `-fsanitize=fuzzer,address,undefined`), and runs the fuzzing campaign.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.config;
import runner.lit_runner;

root struct FuzzCliArgs {
    entry:            const u8[:] = "",
    cc:               const u8[:] = "gcc",
    opt:              const u8[:] = "-O2",
    target:           const u8[:] = "",
    runs:             const u8[:] = "10000",
    seconds:          const u8[:] = "",
    seed:             const u8[:] = "",
    evolved_dir:      const u8[:] = "",
    max_rss_kb:       const u8[:] = "",
    max_ms:           const u8[:] = "",
    use_libfuzzer:    bool        = false,
    debug_no_bce:     bool        = false,
    check_complexity: bool        = false,
    build_only:       bool        = false,
    extra_c:          u8[>..]     = [],
    extra_libs:       u8[>..]     = [],
    corpora:          u8[>..]     = [],
}

fn append_quoted(dst: u8[>..]&, s: const u8[:]) {
    dst.push('"');
    dst.append(s);
    dst.push('"');
}

fn append_nl_list_quoted(dst: u8[>..]&, list: const u8[:], prefix: const u8[:]) {
    var start: i64 = 0;
    for i in list.len {
        guard list[i] == '\n' else { continue; }
        let item = crap::trim_ascii(list[start..i]);
        start = i + 1;
        if item.len > 0 {
            dst.push(' ');
            if prefix.len > 0 {
                dst.append(prefix);
            }
            append_quoted(dst, item);
        }
    }
}

fn append_nl_list_raw(dst: u8[>..]&, list: const u8[:], flag_prefix: const u8[:]) {
    var start: i64 = 0;
    for i in list.len {
        guard list[i] == '\n' else { continue; }
        let item = crap::trim_ascii(list[start..i]);
        start = i + 1;
        if item.len > 0 {
            dst.push(' ');
            dst.append(flag_prefix);
            dst.append(item);
        }
    }
}

fn is_win_gcc(cc: const u8[:]) -> bool {
    guard crap::native_host_os() == 1 else { return false; }
    return crap::slice_index_of(cc, "gcc") >= 0 || crap::slice_index_of(cc, "GCC") >= 0;
}

fn parse_fuzz_cli_args(all_args: const (u8[:])[:], cfg: FuzzCliArgs&) -> bool {
    var idx: i64 = 2;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--libfuzzer" {
            cfg.use_libfuzzer = true;
        } else if a == "--debug" {
            cfg.debug_no_bce = true;
        } else if a == "--check-complexity" {
            cfg.check_complexity = true;
        } else if a == "--build-only" {
            cfg.build_only = true;
        } else if a == "--cc" && idx + 1 < all_args.len {
            idx++;
            cfg.cc = all_args[idx];
        } else if a == "--opt" && idx + 1 < all_args.len {
            idx++;
            cfg.opt = all_args[idx];
        } else if a == "--target" && idx + 1 < all_args.len {
            idx++;
            cfg.target = all_args[idx];
        } else if (a == "--runs" || a == "--execs") && idx + 1 < all_args.len {
            idx++;
            cfg.runs = all_args[idx];
        } else if a == "--seconds" && idx + 1 < all_args.len {
            idx++;
            cfg.seconds = all_args[idx];
        } else if a == "--seed" && idx + 1 < all_args.len {
            idx++;
            cfg.seed = all_args[idx];
        } else if (a == "--evolved" || a == "--corpus-out") && idx + 1 < all_args.len {
            idx++;
            cfg.evolved_dir = all_args[idx];
        } else if (a == "--max-rss-kb" || a == "--max-rss-drift-kb") && idx + 1 < all_args.len {
            idx++;
            cfg.max_rss_kb = all_args[idx];
        } else if (a == "--max-ms" || a == "--max-input-ms") && idx + 1 < all_args.len {
            idx++;
            cfg.max_ms = all_args[idx];
        } else if a == "--extra-c" && idx + 1 < all_args.len {
            idx++;
            cfg.extra_c.append(all_args[idx]);
            cfg.extra_c.push('\n');
        } else if a == "--extra-lib" && idx + 1 < all_args.len {
            idx++;
            cfg.extra_libs.append(all_args[idx]);
            cfg.extra_libs.push('\n');
        } else if a == "--corpus" && idx + 1 < all_args.len {
            idx++;
            cfg.corpora.append(all_args[idx]);
            cfg.corpora.push('\n');
        } else if a == "--config" && idx + 1 < all_args.len {
            idx++;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option for fuzz: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        } else if cfg.entry.len == 0 {
            cfg.entry = a;
        } else {
            write_stdout("Error: unexpected positional argument for fuzz: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        }
        idx++;
    }
    return true;
}

fn build_fuzz_binary(cfg: const FuzzCliArgs&, exe_out: u8[>..]&) -> bool {
    crap::ensure_lit_cache_dir();
    if !is_dir(".lit/cache/fuzz") {
        make_dir(".lit/cache/fuzz");
    }

    let is_win = crap::native_host_os() == 1;
    let c_out:   const u8[:] = ".lit/cache/fuzz/lit_fuzz_entry.c";
    let h_out:   const u8[:] = ".lit/cache/fuzz/lit_fuzz_entry.h";
    let drv_obj: const u8[:] = ".lit/cache/fuzz/fuzz_driver.o";
    exe_out.append(".lit/cache/fuzz/sancov_fuzzer");
    if is_win {
        exe_out.append(".exe");
    }

    var prog: u8[>..] = [];
    arg(0, prog);
    var drv_c: u8[>..] = [];
    resolve_lit_shim_path(prog[..], "fuzz_driver.c", drv_c);
    guard file_exists(drv_c[..]) else {
        write_stdout("Error: fuzz_driver.c not found at ");
        write_stdout(drv_c[..]);
        write_stdout("\n");
        return false;
    }

    // Step 1: Transpile Goose entry to standalone C
    var g_cmd: u8[>..] = [];
    g_cmd.append("goose --standalone --header ");
    append_quoted(g_cmd, h_out);
    g_cmd.append(" -o ");
    append_quoted(g_cmd, c_out);
    if cfg.debug_no_bce {
        g_cmd.append(" --debug --no-bce");
    }
    g_cmd.push(' ');
    append_quoted(g_cmd, cfg.entry);

    var out: u8[>..] = [];
    if crap::exec_capture(g_cmd[..], out) != 0 {
        write_stdout("Error: goose --standalone failed:\n");
        write_stdout(out[..]);
        return false;
    }

    // Step 2: Compile fuzz_driver.c (uninstrumented)
    let win_gcc = is_win_gcc(cfg.cc);
    var d_cmd: u8[>..] = [];
    d_cmd.append(cfg.cc);
    d_cmd.push(' ');
    d_cmd.append(cfg.opt);
    d_cmd.append(" -Wall -Wextra -c ");
    if win_gcc {
        d_cmd.append("-mno-avx ");
    }
    if cfg.use_libfuzzer {
        d_cmd.append("-DLIBFUZZER_EXTERNAL_MAIN=1 ");
    }
    append_quoted(d_cmd, drv_c[..]);
    d_cmd.append(" -o ");
    append_quoted(d_cmd, drv_obj);

    out.clear();
    if crap::exec_capture(d_cmd[..], out) != 0 {
        write_stdout("Error: fuzz_driver.c compilation failed:\n");
        write_stdout(out[..]);
        return false;
    }

    // Step 3: Compile instrumented entry + link
    var l_cmd: u8[>..] = [];
    l_cmd.append(cfg.cc);
    l_cmd.push(' ');
    l_cmd.append(cfg.opt);
    if win_gcc {
        l_cmd.append(" -mstackrealign -mno-avx -fno-ipa-cp-clone --param inline-unit-growth=15 --param max-inline-insns-auto=15 --param max-inline-insns-single=30");
    }
    if cfg.use_libfuzzer {
        l_cmd.append(" -fsanitize=fuzzer,address,undefined -DLIBFUZZER_EXTERNAL_MAIN=1");
    } else {
        l_cmd.append(" -fsanitize-coverage=trace-pc");
    }
    l_cmd.append(" -o ");
    append_quoted(l_cmd, exe_out[..]);
    l_cmd.push(' ');
    append_quoted(l_cmd, c_out);
    l_cmd.push(' ');
    append_quoted(l_cmd, drv_obj);
    append_nl_list_quoted(l_cmd, cfg.extra_c[..], "");
    append_nl_list_raw(l_cmd, cfg.extra_libs[..], "-l");
    if is_win {
        l_cmd.append(" -Wl,--stack,33554432 -Wl,--allow-multiple-definition");
    } else {
        l_cmd.append(" -lpthread -lm");
    }

    out.clear();
    if crap::exec_capture(l_cmd[..], out) != 0 {
        write_stdout("Error: fuzzer link failed:\n");
        write_stdout(out[..]);
        return false;
    }
    return true;
}

fn handle_fuzz_cli(all_args: const (u8[:])[:], lit_cfg: const crap::LitConfig&) -> i32 {
    var cfg = FuzzCliArgs { .. };
    guard parse_fuzz_cli_args(all_args, cfg) else { return 2; }
    if cfg.entry.len == 0 && lit_cfg.fuzz_entry_buf.len > 0 {
        cfg.entry = lit_cfg.fuzz_entry_buf[..];
    }
    if cfg.entry.len == 0 {
        write_stdout("Usage: goose-lit fuzz [entry.goose] [--target <id|name>] [--runs <N>] [--cc <cc>] [--libfuzzer] [--extra-c <file>] [--corpus <dir>] [--build-only]\n");
        return 2;
    }
    if cfg.extra_c.len == 0 && lit_cfg.fuzz_extra_c_buf.len > 0 {
        cfg.extra_c.append(lit_cfg.fuzz_extra_c_buf[..]);
    }
    if cfg.extra_libs.len == 0 && lit_cfg.fuzz_extra_libs_buf.len > 0 {
        cfg.extra_libs.append(lit_cfg.fuzz_extra_libs_buf[..]);
    }
    guard file_exists(cfg.entry) else {
        write_stdout("Error: fuzz entrypoint not found: ");
        write_stdout(cfg.entry);
        write_stdout("\n");
        return 1;
    }

    var exe_out: u8[>..] = [];
    guard build_fuzz_binary(cfg, exe_out) else { return 1; }
    if cfg.build_only {
        write_stdout(exe_out[..]);
        write_stdout("\n");
        return 0;
    }

    var r_cmd: u8[>..] = [];
    append_quoted(r_cmd, exe_out[..]);
    if !cfg.use_libfuzzer {
        let tgt = if cfg.target.len > 0 { cfg.target } else { "-1" };
        r_cmd.push(' ');
        r_cmd.append(tgt);
        r_cmd.push(' ');
        r_cmd.append(cfg.runs);
        if cfg.seconds.len > 0 {
            r_cmd.append(" --seconds ");
            r_cmd.append(cfg.seconds);
        }
        if cfg.seed.len > 0 {
            r_cmd.append(" --seed ");
            r_cmd.append(cfg.seed);
        }
        if cfg.evolved_dir.len > 0 {
            r_cmd.append(" --corpus-out ");
            append_quoted(r_cmd, cfg.evolved_dir);
        }
        if cfg.max_rss_kb.len > 0 {
            r_cmd.append(" --max-rss-drift-kb ");
            r_cmd.append(cfg.max_rss_kb);
        }
        if cfg.max_ms.len > 0 {
            r_cmd.append(" --max-input-ms ");
            r_cmd.append(cfg.max_ms);
        }
        if cfg.check_complexity {
            r_cmd.append(" --check-complexity");
        }
    } else {
        r_cmd.append(" -runs=");
        r_cmd.append(cfg.runs);
    }
    append_nl_list_quoted(r_cmd, cfg.corpora[..], "");

    var run_out: u8[>..] = [];
    let rc = crap::exec_capture(r_cmd[..], run_out);
    write_stdout(run_out[..]);
    return rc;
}
