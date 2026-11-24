// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// runner/check_cli.goose - Parallel `goose check` runner across files and directories.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.time;
import sys.config;
import crap.ast.analyzer;

root struct CheckCliArgs {
    filter:    const u8[:] = "",
    cc:        const u8[:] = "",
    jobs:      i64         = 0,
    fail_fast: bool        = false,
    targets:   u8[>..]     = [],
}

struct CheckWorkerCfg {
    list_path: u8[..256] = [],
    cache_dir: u8[..256] = [],
    cc:        u8[..128] = [],
    total:     i32       = 0,
    fail_fast: bool      = false,
}

fn check_get_line(blob: const u8[:], idx: i32, out: u8[>..]&) -> bool {
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

fn check_worker_loop(cfg: CheckWorkerCfg) {
    var list_blob: u8[>..] = [];
    guard read_file(cfg.list_path[..], list_blob) else { return; }

    var fpath:     u8[>..] = [];
    var slot_path: u8[>..] = [];
    var out_buf:   u8[>..] = [];
    var slot_buf:  u8[>..] = [];

    while true {
        if cfg.fail_fast && crap::native_atomic_get_stop() != 0 {
            break;
        }
        let idx = crap::native_work_claim(cfg.total);
        if idx < 0 { break; }

        fpath.clear();
        guard check_get_line(list_blob[..], idx, fpath) else { continue; }

        out_buf.clear();
        let t0 = (monotonic_now().nanos as! i64) / 1000;
        let rc = if cfg.cc.len > 0 {
            var cmd: u8[>..] = [];
            cmd.append("goose check --cc ");
            cmd.append(cfg.cc[..]);
            cmd.append(" \"");
            cmd.append(fpath[..]);
            cmd.push('"');
            crap::exec_capture(cmd[..], out_buf)
        } else {
            crap::exec_argv_capture("goose", "check", fpath[..], "", 0, out_buf)
        };
        let dt_ms = ((monotonic_now().nanos as! i64) / 1000 - t0) / 1000;

        slot_buf.clear();
        if rc == 0 {
            slot_buf.append("PASS ");
            format(slot_buf, dt_ms);
            slot_buf.push('\n');
        } else {
            if cfg.fail_fast {
                crap::native_atomic_set_stop(1);
            }
            slot_buf.append("FAIL ");
            format(slot_buf, dt_ms);
            slot_buf.push('\n');
            slot_buf.append(out_buf[..]);
        }

        slot_path.clear();
        slot_path.append(cfg.cache_dir[..]);
        slot_path.append("/.chk_slot_");
        format(slot_path, idx);
        slot_path.append(".res");
        let _ = write_file(slot_path[..], slot_buf[..]);
    }
}

thread_fn check_parallel_worker(cfg: CheckWorkerCfg) {
    check_worker_loop(cfg);
}

fn parse_check_cli_args(all_args: const (u8[:])[:], cfg: CheckCliArgs&) -> bool {
    var idx: i64 = 2;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--help" || a == "-h" {
            write_stdout("Usage: goose-lit check <path...> [-j <N>] [--filter <glob>] [--fail-fast] [--cc <cc>]\n");
            return false;
        } else if (a == "-j" || a == "--jobs") && idx + 1 < all_args.len {
            idx++;
            let jv, ok = crap::parse_i64_slice(all_args[idx]);
            if ok && jv > 0 { cfg.jobs = jv; }
        } else if a == "--filter" && idx + 1 < all_args.len {
            idx++;
            cfg.filter = all_args[idx];
        } else if a == "--cc" && idx + 1 < all_args.len {
            idx++;
            cfg.cc = all_args[idx];
        } else if a == "--fail-fast" || a == "-x" {
            cfg.fail_fast = true;
        } else if a == "--config" && idx + 1 < all_args.len {
            idx++;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option for check: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        } else {
            cfg.targets.append(a);
            cfg.targets.push('\n');
        }
        idx++;
    }
    return true;
}

fn handle_check_cli(all_args: const (u8[:])[:], lit_cfg: const crap::LitConfig&) -> i32 {
    var cfg = CheckCliArgs { .. };
    if lit_cfg.has_jobs && lit_cfg.jobs > 0 {
        cfg.jobs = lit_cfg.jobs;
    }
    if lit_cfg.cc_buf.len > 0 {
        cfg.cc = lit_cfg.cc_buf[..];
    }
    guard parse_check_cli_args(all_args, cfg) else { return 2; }

    if cfg.targets.len == 0 {
        if lit_cfg.src_dir_buf.len > 0 {
            cfg.targets.append(lit_cfg.src_dir_buf[..]);
            cfg.targets.push('\n');
        } else {
            cfg.targets.append(".\n");
        }
    }

    var raw_files: u8[>..] = [];
    var t_start:   i64     = 0;
    while t_start < cfg.targets.len {
        let rel_nl = crap::slice_index_of_byte(cfg.targets[t_start..], '\n');
        let t_end = if rel_nl >= 0 { t_start + rel_nl } else { cfg.targets.len };
        let t_item = crap::trim_ascii(cfg.targets[t_start..t_end]);
        t_start = t_end + 1;
        guard t_item.len > 0 else { continue; }
        guard file_exists(t_item) || is_dir(t_item) else {
            write_stdout("Error: check target not found: ");
            write_stdout(t_item);
            write_stdout("\n");
            return 2;
        }
        crap::collect_goose_files_filtered(t_item, true, lit_cfg.exclude_buf[..], raw_files);
    }

    var files_blob: u8[>..] = [];
    var f_start:    i64     = 0;
    var total:      i32     = 0;
    while f_start < raw_files.len {
        let rel_nl = crap::slice_index_of_byte(raw_files[f_start..], '\n');
        let f_end = if rel_nl >= 0 { f_start + rel_nl } else { raw_files.len };
        let fp = crap::trim_ascii(raw_files[f_start..f_end]);
        f_start = f_end + 1;
        guard fp.len > 0 else { continue; }
        if cfg.filter.len > 0 {
            let last_sl = crap::slice_last_index_of_byte(fp, '/');
            let base = if last_sl >= 0 { fp[last_sl + 1..] } else { fp };
            if !crap::glob_match(cfg.filter, fp) && !crap::glob_match(cfg.filter, base) {
                continue;
            }
        }
        files_blob.append(fp);
        files_blob.push('\n');
        total++;
    }

    if total == 0 {
        write_stdout("No .goose files matched check target.\n");
        return 0;
    }

    crap::ensure_lit_cache_dir();
    let cache_dir: const u8[:] = ".lit/cache";
    let list_path: const u8[:] = ".lit/cache/.chk_files.list";
    let _ = write_file(list_path, files_blob[..]);

    let eff_jobs = if cfg.jobs > 0 {
        cfg.jobs
    } else {
        min(max(crap::native_cpu_count() as i64, 1), 4)
    };
    let n_workers = min(eff_jobs, total);

    let t0_all = (monotonic_now().nanos as! i64) / 1000;
    crap::native_work_reset();
    var wcfg = CheckWorkerCfg {
        total:     total,
        fail_fast: cfg.fail_fast,
    };
    let _ = crap::set_bounded(wcfg.list_path, list_path);
    let _ = crap::set_bounded(wcfg.cache_dir, cache_dir);
    let _ = crap::set_bounded(wcfg.cc, cfg.cc);

    if n_workers <= 1 {
        check_worker_loop(wcfg);
    } else {
        var tids: i64[>..] = [];
        for _ in n_workers {
            tids.push(thread_spawn(check_parallel_worker, wcfg));
        }
        for ti in tids.len {
            var why: u8[>..] = [];
            let _ = thread_wait(tids[ti], why);
        }
    }

    let dt_all_ms = ((monotonic_now().nanos as! i64) / 1000 - t0_all) / 1000;
    var passed:    i32     = 0;
    var failed:    i32     = 0;
    var fp_buf:    u8[>..] = [];
    var slot_p:    u8[>..] = [];
    var slot_data: u8[>..] = [];

    for idx in total {
        fp_buf.clear();
        let _ = check_get_line(files_blob[..], idx, fp_buf);
        slot_p.clear();
        slot_p.append(cache_dir);
        slot_p.append("/.chk_slot_");
        format(slot_p, idx);
        slot_p.append(".res");

        slot_data.clear();
        if read_file(slot_p[..], slot_data) {
            let nl = crap::slice_index_of_byte(slot_data[..], '\n');
            let head = if nl >= 0 { slot_data[..nl] } else { slot_data[..] };
            let body = if nl >= 0 && nl + 1 < slot_data.len { slot_data[nl + 1..] } else { "" };
            if crap::slice_starts_with(head, "PASS") {
                passed++;
                write_stdout("  [CHECK OK] ");
                write_stdout(fp_buf[..]);
                if head.len > 5 {
                    write_stdout(" (");
                    write_stdout(head[5..]);
                    write_stdout(" ms)");
                }
                write_stdout("\n");
            } else {
                failed++;
                write_stdout("  [CHECK FAIL] ");
                write_stdout(fp_buf[..]);
                write_stdout("\n");
                if body.len > 0 { write_stdout(body); }
            }
            delete_file(slot_p[..]);
        }
    }
    if file_exists(list_path) { delete_file(list_path); }

    var sum: u8[>..] = [];
    sum.append("Check Summary: ");
    format(sum, passed, "/", total, " passed, ", failed, " failed in ", dt_all_ms, " ms\n");
    write_stdout(sum[..]);
    return if failed == 0 { 0 } else { 1 };
}
