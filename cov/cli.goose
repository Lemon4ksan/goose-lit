// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// cov/cli.goose - Real source-to-source branch coverage collector, merger, and LCOV exporter.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.config;
import crap.ast.model;
import crap.ast.analyzer;
import crap.compiler.bridge;
import crap.coverage.profile;
import crap.coverage.instrument;
import crap.metrics.crap;
import crap.report.ratchet;
import crap.cli;
import runner.lit_runner;

root struct CovCliArgs {
    src_target:   const u8[:] = "",
    out_path:     const u8[:] = ".lit/cache/cov/merged.gcrap-cov",
    lcov_path:    const u8[:] = "",
    cc:           const u8[:] = "",
    filter:       const u8[:] = "",
    jobs:         i64         = 0,
    timeout_sec:  i64         = 120,
    run_gate:     bool        = false,
    gate_ceiling: f64         = 25.0,
    keep_ws:      bool        = false,
    test_targets: u8[>..]     = [],
}

struct CovWorkerCfg {
    list_path:  u8[..256] = [],
    ws_dir:     u8[..256] = [],
    cov_dir:    u8[..256] = [],
    cc:         u8[..128] = [],
    total:      i32       = 0,
    timeout_ms: i32       = 120000,
    is_win:     bool      = false,
}

fn cov_ensure_parent_dirs(path: const u8[:]) {
    var norm: u8[>..] = [];
    crap::normalize_slashes(path, norm);
    for i in norm.len {
        if norm[i] == '/' && i > 0 {
            let dir_slice = norm[..i];
            if !is_dir(dir_slice) {
                make_dir(dir_slice);
            }
        }
    }
}

fn cov_should_skip_dir(name: const u8[:]) -> bool {
    guard name.len > 0 else { return true; }
    if name[0] == '.' { return true; }
    return name == "vendor" || name == "scratch" || name == "bin" ||
        name == "build" || name == "target" || name == "node_modules" ||
        name == "__pycache__";
}

fn cov_should_copy_file(name: const u8[:]) -> bool {
    return crap::slice_ends_with(name, ".goose") ||
        crap::slice_ends_with(name, ".build") ||
        crap::slice_ends_with(name, ".c") ||
        crap::slice_ends_with(name, ".h") ||
        crap::slice_ends_with(name, ".txt") ||
        crap::slice_ends_with(name, ".json") ||
        crap::slice_ends_with(name, ".bat") ||
        crap::slice_ends_with(name, ".cmd") ||
        name == ".litconfig" ||
        name == "lit.conf";
}

fn mirror_workspace_tree(ws_root: const u8[:]) {
    if !is_dir(ws_root) {
        make_dir(ws_root);
    }

    var dir_queue: u8[>..] = [];
    dir_queue.append(".\n");

    var entries:      u8[>..] = [];
    var src_child:    u8[>..] = [];
    var dst_child:    u8[>..] = [];
    var file_buf:     u8[>..] = [];
    var queue_cursor: i64     = 0;

    while queue_cursor < dir_queue.len {
        let rel_nl = crap::slice_index_of_byte(dir_queue[queue_cursor..], '\n');
        guard rel_nl >= 0 else { break; }
        let cur_dir = dir_queue[queue_cursor..queue_cursor + rel_nl];
        queue_cursor += rel_nl + 1;

        entries.clear();
        guard list_dir(cur_dir, entries) else { continue; }

        var lstart: i64 = 0;
        for j in entries.len {
            guard entries[j] == '\n' else { continue; }
            let name = entries[lstart..j];
            lstart = j + 1;

            src_child.clear();
            if cur_dir != "." {
                src_child.append(cur_dir);
                src_child.push('/');
            }
            src_child.append(name);

            if is_dir(src_child[..]) {
                guard !cov_should_skip_dir(name) else { continue; }
                dst_child.clear();
                dst_child.append(ws_root);
                dst_child.push('/');
                dst_child.append(src_child[..]);
                if !is_dir(dst_child[..]) {
                    make_dir(dst_child[..]);
                }
                dir_queue.append(src_child[..]);
                dir_queue.push('\n');
            } else if cov_should_copy_file(name) {
                let sz = crap::native_file_size(src_child[..]);
                guard sz >= 0 && sz <= 4194304 else { continue; }
                file_buf.clear();
                if read_file(src_child[..], file_buf) {
                    dst_child.clear();
                    dst_child.append(ws_root);
                    dst_child.push('/');
                    dst_child.append(src_child[..]);
                    cov_ensure_parent_dirs(dst_child[..]);
                    let _ = write_file(dst_child[..], file_buf[..]);
                }
            }
        }
    }
}

fn cov_copy_shim_to(prog: const u8[:], shim_name: const u8[:], dst_path: const u8[:]) -> bool {
    var src_p: u8[>..] = [];
    resolve_lit_shim_path(prog, shim_name, src_p);
    var data: u8[>..] = [];
    guard read_file(src_p[..], data) else { return false; }
    return write_file(dst_path, data[..]);
}

fn cov_collect_tests(
    test_targets: const u8[:],
    exclude_blob: const u8[:],
    filter_glob:  const u8[:],
    out_tests:    u8[>..]&,
) {
    var raw_blob: u8[>..] = [];
    var norm:     u8[>..] = [];
    var t_rem = test_targets;
    while t_rem.len > 0 {
        let item, rest = crap::take_next_line(t_rem);
        t_rem = rest;
        if item.len > 0 {
            if file_exists(item) {
                norm.clear();
                crap::normalize_path(item, norm);
                raw_blob.append(norm[..]);
                raw_blob.push('\n');
            } else if is_dir(item) {
                let _ = discover_test_files_filtered(item, exclude_blob, raw_blob);
            }
        }
    }

    // Filter out helper kits, unsupported/xfail directive tests, and non-matching globs
    var src:   u8[>..] = [];
    var r_pos: i64     = 0;
    while r_pos != raw_blob.len {
        let fpath = crap::next_line_at(raw_blob[..], r_pos);
        guard fpath.len > 0 else { continue; }
        guard crap::slice_ends_with(fpath, ".goose") else { continue; }
        guard !crap::is_excluded_path(fpath, exclude_blob) else { continue; }
        guard crap::path_matches_filter(filter_glob, fpath) else { continue; }

        src.clear();
        if read_file(fpath, src) {
            // Skip directive-only LIT tests that intentionally fail or are unsupported
            if crap::slice_contains(src[..], "// XFAIL:") || crap::slice_contains(src[..], "// UNSUPPORTED:") {
                continue;
            }
            if !crap::slice_contains(src[..], "fn main(") {
                continue;
            }
            out_tests.append(fpath);
            out_tests.push('\n');
        }
    }
}

thread_fn cov_parallel_worker(cfg: CovWorkerCfg) {
    var list_blob: u8[>..] = [];
    guard read_file(cfg.list_path[..], list_blob) else { return; }

    var test_rel:  u8[>..]   = [];
    var test_src:  u8[>..]   = [];
    var cmd:       u8[>..]   = [];
    var prof_path: u8[..320] = [];
    var slot_path: u8[..320] = [];
    var run_out:   u8[>..]   = [];
    var slot_buf:  u8[>..]   = [];

    while true {
        let idx = crap::native_work_claim(cfg.total);
        if idx < 0 { break; }

        test_rel.clear();
        guard crap::blob_get_line(list_blob[..], idx, test_rel) else { continue; }

        test_src.clear();
        let _ = read_file(test_rel[..], test_src);

        cmd.clear();
        cmd.append("goose build -O0");
        if cfg.cc.len > 0 {
            cmd.append(" --cc ");
            cmd.append(cfg.cc[..]);
        }
        cmd.append(" --include ../cov_rt.h");
        if crap::slice_contains(test_src[..], "%prof_hook") || crap::slice_contains(test_src[..], "prof_hook.h") {
            cmd.append(" --include ../prof_hook.h");
        }
        if crap::slice_contains(test_src[..], "%alloc_hook") || crap::slice_contains(test_src[..], "alloc_hook.h") {
            cmd.append(" --include ../alloc_hook.h");
        }
        cmd.append(" -o ../cov_bin_");
        format(cmd, idx);
        if cfg.is_win { cmd.append(".exe"); }
        cmd.push(' ');
        cmd.append(test_rel[..]);
        cmd.append(" && ");
        if cfg.is_win {
            cmd.append("..\\cov_bin_");
            format(cmd, idx);
            cmd.append(".exe");
        } else {
            cmd.append("../cov_bin_");
            format(cmd, idx);
        }

        prof_path.clear();
        prof_path.append(cfg.cov_dir[..]);
        prof_path.append("/prof_");
        format(prof_path, idx);
        prof_path.append(".gcrap-cov");

        run_out.clear();
        let rc = crap::exec_in_dir_with_env_capture(
            cfg.ws_dir[..],
            cmd[..],
            "GCRAP_PROFILE_OUT",
            prof_path[..],
            cfg.timeout_ms,
            run_out,
        );

        slot_buf.clear();
        if rc == 0 {
            slot_buf.append("PASS\n");
        } else {
            slot_buf.append("FAIL\n");
            slot_buf.append(run_out[..]);
        }
        slot_path.clear();
        slot_path.append(cfg.cov_dir[..]);
        slot_path.append("/slot_");
        format(slot_path, idx);
        slot_path.append(".res");
        let _ = write_file(slot_path[..], slot_buf[..]);
    }
}

fn parse_cov_cli_args(all_args: const (u8[:])[:], cfg: CovCliArgs&) -> bool {
    var idx: i64 = 2;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--help" || a == "-h" {
            write_stdout("Usage: goose-lit cov <src_target> [--tests <path>] [-j <N>] [--filter <glob>] [--out <path>] [--lcov <path>] [--cc <cc>] [--gate [ceiling]] [--keep]\n");
            return false;
        } else if (a == "--tests" || a == "--test") && idx + 1 < all_args.len {
            idx++;
            cfg.test_targets.append(all_args[idx]);
            cfg.test_targets.push('\n');
        } else if (a == "-j" || a == "--jobs") && idx + 1 < all_args.len {
            idx++;
            if all_args[idx] == "auto" {
                cfg.jobs = 0;
            } else {
                let jv, ok = crap::parse_i64_slice(all_args[idx]);
                if ok && jv > 0 { cfg.jobs = jv; }
            }
        } else if a == "--filter" && idx + 1 < all_args.len {
            idx++;
            cfg.filter = all_args[idx];
        } else if a == "--out" && idx + 1 < all_args.len {
            idx++;
            cfg.out_path = all_args[idx];
        } else if a == "--lcov" && idx + 1 < all_args.len {
            idx++;
            cfg.lcov_path = all_args[idx];
        } else if a == "--cc" && idx + 1 < all_args.len {
            idx++;
            cfg.cc = all_args[idx];
        } else if a == "--timeout" && idx + 1 < all_args.len {
            idx++;
            let tv, ok = crap::parse_i64_slice(all_args[idx]);
            if ok && tv > 0 { cfg.timeout_sec = tv; }
        } else if a == "--gate" {
            cfg.run_gate = true;
            if idx + 1 < all_args.len && !crap::slice_starts_with(all_args[idx + 1], "-") {
                let gv, ok = crap::parse_f64_slice(all_args[idx + 1]);
                if ok {
                    cfg.gate_ceiling = gv;
                    idx++;
                }
            }
        } else if a == "--keep" {
            cfg.keep_ws = true;
        } else if a == "--config" && idx + 1 < all_args.len {
            idx++;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option for cov: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        } else if cfg.src_target.len == 0 {
            cfg.src_target = a;
        }
        idx++;
    }
    return true;
}

fn handle_cov_cli(all_args: const (u8[:])[:], lit_cfg: const crap::LitConfig&) -> i32 {
    var cfg = CovCliArgs { .. };
    if lit_cfg.cc_buf.len > 0 {
        cfg.cc = lit_cfg.cc_buf[..];
    }
    if lit_cfg.has_jobs && lit_cfg.jobs > 0 {
        cfg.jobs = lit_cfg.jobs;
    }
    if lit_cfg.has_gate_ceiling {
        cfg.gate_ceiling = lit_cfg.gate_ceiling;
    }
    if lit_cfg.has_timeout && lit_cfg.timeout_sec > 0 {
        cfg.timeout_sec = lit_cfg.timeout_sec;
    }
    guard parse_cov_cli_args(all_args, cfg) else { return 2; }
    if cfg.src_target.len == 0 {
        if lit_cfg.src_dir_buf.len > 0 {
            cfg.src_target = lit_cfg.src_dir_buf[..];
        } else {
            cfg.src_target = ".";
        }
    }
    guard file_exists(cfg.src_target) || is_dir(cfg.src_target) else {
        write_stdout("Error: coverage source target not found: ");
        write_stdout(cfg.src_target);
        write_stdout("\n");
        return 1;
    }

    if cfg.test_targets.len == 0 {
        if lit_cfg.tests_dir_buf.len > 0 {
            cfg.test_targets.append(lit_cfg.tests_dir_buf[..]);
            cfg.test_targets.push('\n');
        } else {
            cfg.test_targets.append("tests\n");
        }
    }

    // 1. Collect and analyze source files identically to `crap`
    var files_blob: u8[>..] = [];
    let inc_tests = if lit_cfg.has_include_tests { lit_cfg.include_tests } else { false };
    crap::collect_goose_files_filtered(cfg.src_target, inc_tests, lit_cfg.exclude_buf[..], files_blob);
    guard files_blob.len > 0 else {
        write_stdout("Error: no .goose source files found under ");
        write_stdout(cfg.src_target);
        write_stdout("\n");
        return 1;
    }

    var pool:                u8[>..]                 = [];
    var functions:           crap::FunctionInfo[>..] = [];
    var branches:            crap::BranchSite[>..]   = [];
    var call_sites:          crap::CallSite[>..]     = [];
    var analyzed_files_blob: u8[>..]                 = [];
    crap::analyze_files_blob(
        files_blob[..],
        pool,
        functions,
        branches,
        call_sites,
        analyzed_files_blob,
    );

    if branches.len == 0 {
        write_stdout("Notice: 0 branch sites found in target.\n");
        return 0;
    }

    // 2. Discover test files
    var test_files_blob: u8[>..] = [];
    cov_collect_tests(cfg.test_targets[..], lit_cfg.exclude_buf[..], cfg.filter, test_files_blob);
    guard test_files_blob.len > 0 else {
        write_stdout("Error: no runnable test files found.\n");
        return 1;
    }

    // 3. Prepare shadow workspace `.lit/cache/cov/ws`
    let cov_dir: const u8[:] = ".lit/cache/cov";
    let ws_dir:  const u8[:] = ".lit/cache/cov/ws";
    crap::ensure_lit_cache_dir();
    if is_dir(ws_dir) {
        let _ = crap::native_remove_tree(ws_dir);
    }
    if !is_dir(cov_dir) { make_dir(cov_dir); }
    mirror_workspace_tree(ws_dir);

    var prog: u8[>..] = [];
    arg(0, prog);
    guard cov_copy_shim_to(prog[..], "cov_rt.h", ".lit/cache/cov/cov_rt.h") else {
        write_stdout("Error: failed to stage shim/cov_rt.h\n");
        return 1;
    }
    let _ = cov_copy_shim_to(prog[..], "prof_hook.h", ".lit/cache/cov/prof_hook.h");
    let _ = cov_copy_shim_to(prog[..], "alloc_hook.h", ".lit/cache/cov/alloc_hook.h");

    // 4. Instrument each analyzed file inside shadow workspace
    var file_idx:     i32                   = 0;
    var orig_src:     u8[>..]               = [];
    var inst_src:     u8[>..]               = [];
    var file_b:       crap::BranchSite[>..] = [];
    var ws_file_path: u8[>..]               = [];
    var f_rem:        const u8[:]           = analyzed_files_blob[..];

    while f_rem.len > 0 {
        let fpath, rest = crap::take_next_line(f_rem);
        f_rem = rest;
        guard fpath.len > 0 else { continue; }

        file_b.clear();
        for bi in branches.len {
            let f_idx = branches[bi].func_idx as i64;
            if f_idx >= 0 && f_idx < functions.len {
                let fn_file = crap::pool_slice(pool[..], functions[f_idx].file_off, functions[f_idx].file_len);
                if fn_file == fpath {
                    file_b.push(branches[bi]);
                }
            }
        }

        orig_src.clear();
        if read_file(fpath, orig_src) {
            inst_src.clear();
            let _ = crap::instrument_source_file(orig_src[..], file_idx, file_b[..], inst_src);
            ws_file_path.clear();
            ws_file_path.append(ws_dir);
            ws_file_path.push('/');
            ws_file_path.append(fpath);
            cov_ensure_parent_dirs(ws_file_path[..]);
            let _ = write_file(ws_file_path[..], inst_src[..]);
        }
        file_idx++;
    }

    // 5. Write test manifest & run instrumented tests in parallel
    let list_path: const u8[:] = ".lit/cache/cov/tests.list";
    let _ = write_file(list_path, test_files_blob[..]);

    var total_tests: i32 = 0;
    for i in test_files_blob.len {
        if test_files_blob[i] == '\n' { total_tests++; }
    }

    let eff_jobs = if cfg.jobs > 0 {
        cfg.jobs
    } else {
        crap::default_auto_jobs(1536)
    };
    let n_workers = min(eff_jobs, total_tests);

    crap::native_work_reset();
    var wcfg = CovWorkerCfg {
        total:      total_tests,
        timeout_ms: (min(cfg.timeout_sec, 2147483) * 1000) as i32,
        is_win:     crap::native_host_os() == 1,
    };
    let _ = crap::set_bounded(wcfg.list_path, list_path);
    let _ = crap::set_bounded(wcfg.ws_dir, ws_dir);
    let _ = crap::set_bounded(wcfg.cov_dir, cov_dir);
    let _ = crap::set_bounded(wcfg.cc, cfg.cc);

    var tids: i64[>..] = [];
    for _ in n_workers {
        tids.push(thread_spawn(cov_parallel_worker, wcfg));
    }
    for ti in tids.len {
        var why: u8[>..] = [];
        let _ = thread_wait(tids[ti], why);
    }

    // 6. Merge profiles & inspect test results
    var passed:    i32      = 0;
    var failed:    i32      = 0;
    var prof_p:    u8[..96] = [];
    var slot_p:    u8[..96] = [];
    var slot_data: u8[>..]  = [];
    var t_name:    u8[>..]  = [];

    for idx in total_tests {
        slot_p.clear();
        slot_p.append(cov_dir);
        slot_p.append("/slot_");
        format(slot_p, idx);
        slot_p.append(".res");

        slot_data.clear();
        if read_file(slot_p[..], slot_data) && crap::slice_starts_with(slot_data[..], "PASS") {
            passed++;
        } else {
            failed++;
            t_name.clear();
            let _ = crap::blob_get_line(test_files_blob[..], idx, t_name);
            write_stdout("  [COV TEST FAIL] ");
            write_stdout(t_name[..]);
            write_stdout("\n");
            if slot_data.len > 5 {
                write_stdout(slot_data[5..]);
            }
        }
        if file_exists(slot_p[..]) { delete_file(slot_p[..]); }

        prof_p.clear();
        prof_p.append(cov_dir);
        prof_p.append("/prof_");
        format(prof_p, idx);
        prof_p.append(".gcrap-cov");
        if file_exists(prof_p[..]) {
            let _ = crap::load_gcrap_profile(prof_p[..], branches);
            if !cfg.keep_ws { delete_file(prof_p[..]); }
        }
    }

    // 7. Save merged profile & optional LCOV export
    cov_ensure_parent_dirs(cfg.out_path);
    if !crap::save_gcrap_profile(cfg.out_path, branches[..]) {
        write_stdout("Error: failed to write merged coverage profile to ");
        write_stdout(cfg.out_path);
        write_stdout("\n");
        return 1;
    }
    if cfg.lcov_path.len > 0 {
        cov_ensure_parent_dirs(cfg.lcov_path);
        let _ = crap::export_lcov_profile(cfg.lcov_path, pool[..], functions[..], branches[..]);
    }

    var covered_total: i64 = 0;
    for bi in branches.len {
        if branches[bi].covered { covered_total++; }
    }
    let total_br = branches.len;
    let pct_x10 = (covered_total * 1000) / total_br;

    var summary: u8[>..] = [];
    summary.append("Real Branch Coverage: ");
    format(summary, covered_total, "/", total_br, " branches (");
    format(summary, pct_x10 / 10, ".", pct_x10 % 10, "%), ");
    format(summary, passed, "/", total_tests, " tests passed\n");
    summary.append("Saved profile: ");
    summary.append(cfg.out_path);
    summary.push('\n');
    if cfg.lcov_path.len > 0 {
        summary.append("Saved LCOV: ");
        summary.append(cfg.lcov_path);
        summary.push('\n');
    }
    write_stdout(summary[..]);

    if !cfg.keep_ws {
        let _ = crap::native_remove_tree(ws_dir);
        if file_exists(list_path) { delete_file(list_path); }
        for idx in total_tests {
            var bin_p: u8[>..] = [];
            bin_p.append(".lit/cache/cov/cov_bin_");
            format(bin_p, idx);
            if crap::native_host_os() == 1 { bin_p.append(".exe"); }
            if file_exists(bin_p[..]) { delete_file(bin_p[..]); }
        }
    }

    if cfg.run_gate {
        crap::propagate_trust_taint(functions, call_sites, pool);
        var bce_blob: u8[>..] = [];
        if crap::run_goose_bce_lines(cfg.src_target, bce_blob) == 0 || bce_blob.len > 0 {
            crap::apply_bce_lines_blob(bce_blob, pool, functions, branches);
        }
        var rcfg = crap::default_risk_config();
        rcfg.has_coverage_profile = true;
        crap::aggregate_coverage_metrics(rcfg, functions, branches);
        crap::compute_crap_metrics(rcfg, functions, branches);
        let gate_rc = crap::evaluate_gate_on_workspace(
            pool[..],
            functions[..],
            branches[..],
            lit_cfg.baseline_buf[..],
            if lit_cfg.has_delta { lit_cfg.delta_threshold } else { 5.0 },
            cfg.gate_ceiling,
            true,
        );
        if gate_rc != 0 { return gate_rc; }
    }

    return if failed > 0 { 1 } else { 0 };
}
