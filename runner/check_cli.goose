// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// runner/check_cli.goose - Package-aware parallel `goose check` runner across files and directories.
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
    list_path:     u8[..256] = [],
    cache_dir:     u8[..256] = [],
    cc:            u8[..128] = [],
    check_entries: u8[..512] = [],
    total:         i32       = 0,
    fail_fast:     bool      = false,
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

fn check_blob_contains_line(blob: const u8[:], needle: const u8[:]) -> bool {
    guard needle.len > 0 && blob.len > 0 else { return false; }
    var start: i64 = 0;
    while start < blob.len {
        let rel_nl = crap::slice_index_of_byte(blob[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { blob.len };
        if crap::trim_ascii(blob[start..end]) == needle {
            return true;
        }
        start = end + 1;
    }
    return false;
}

fn check_join_norm(dir: const u8[:], name: const u8[:], out: u8[>..]&) {
    var raw: u8[>..] = [];
    if dir.len > 0 && dir != "." && dir != "./" {
        raw.append(dir);
        if raw[raw.len - 1] != '/' && raw[raw.len - 1] != '\\' {
            raw.push('/');
        }
    }
    raw.append(name);
    crap::normalize_path(raw[..], out);
}

fn check_parent_dir(path: const u8[:], out: u8[>..]&) {
    var norm: u8[>..] = [];
    crap::normalize_path(path, norm);
    let last_sl = crap::slice_last_index_of_byte(norm[..], '/');
    if last_sl > 0 {
        out.append(norm[..last_sl]);
    } else if last_sl == 0 {
        out.push('/');
    } else {
        out.push('.');
    }
}

fn check_discover_root_goose_files(dir: const u8[:], exclude_blob: const u8[:], out: u8[>..]&) {
    var entries: u8[>..] = [];
    guard list_dir(dir, entries) else { return; }
    var lstart: i64     = 0;
    var child:  u8[>..] = [];
    for j in entries.len {
        guard entries[j] == '\n' else { continue; }
        let name = crap::trim_ascii(entries[lstart..j]);
        lstart = j + 1;
        guard name.len > 6 && crap::slice_ends_with(name, ".goose") else { continue; }
        child.clear();
        check_join_norm(dir, name, child);
        guard !is_dir(child[..]) && file_exists(child[..]) else { continue; }
        guard !crap::is_excluded_path(child[..], exclude_blob) else { continue; }
        if !check_blob_contains_line(out[..], child[..]) {
            out.append(child[..]);
            out.push('\n');
        }
    }
}

// Traverses non-external `import a.b;` directives starting from `roots_blob` inside `pkg_dir`
// and appends every transitively imported nested `.goose` file to `covered_out`.
fn check_collect_covered_submodules(pkg_dir: const u8[:], roots_blob: const u8[:], covered_out: u8[>..]&) {
    guard roots_blob.len > 0 else { return; }
    var queue: u8[>..] = [];
    queue.append(roots_blob);

    var visited: u8[>..] = [];
    visited.append(roots_blob);

    var src:      u8[>..] = [];
    var mod_rel:  u8[>..] = [];
    var cand:     u8[>..] = [];
    var q_cursor: i64     = 0;

    while q_cursor < queue.len {
        let rel_nl = crap::slice_index_of_byte(queue[q_cursor..], '\n');
        let q_end = if rel_nl >= 0 { q_cursor + rel_nl } else { queue.len };
        let cur_file = crap::trim_ascii(queue[q_cursor..q_end]);
        q_cursor = q_end + 1;
        guard cur_file.len > 0 else { continue; }

        src.clear();
        guard read_file(cur_file, src) else { continue; }

        var pos: i64 = 0;
        while pos < src.len {
            let nl = crap::slice_index_of_byte(src[pos..], '\n');
            let lend = if nl >= 0 { pos + nl } else { src.len };
            let line = crap::trim_ascii(src[pos..lend]);
            pos = lend + 1;

            guard crap::slice_starts_with(line, "import ") else { continue; }
            guard !crap::slice_contains(line, " from ") else { continue; }

            let rest = crap::trim_ascii(line[7..]);
            var mod_end = rest.len;
            for k in rest.len {
                let c = rest[k];
                if c == ';' || c == ' ' || c == '\t' || c == '/' {
                    mod_end = k;
                    break;
                }
            }
            let mod_name = rest[..mod_end];
            guard mod_name.len > 0 else { continue; }

            mod_rel.clear();
            for b in mod_name {
                if b == '.' { mod_rel.push('/'); } else { mod_rel.push(b); }
            }
            mod_rel.append(".goose");

            cand.clear();
            check_join_norm(pkg_dir, mod_rel[..], cand);
            guard file_exists(cand[..]) && !is_dir(cand[..]) else { continue; }

            if !check_blob_contains_line(roots_blob, cand[..]) &&
               !check_blob_contains_line(covered_out[..], cand[..]) {
                covered_out.append(cand[..]);
                covered_out.push('\n');
            }
            if !check_blob_contains_line(visited[..], cand[..]) {
                visited.append(cand[..]);
                visited.push('\n');
                queue.append(cand[..]);
                queue.push('\n');
            }
        }
    }
}

fn check_discover_build_entries_in_dir(dir: const u8[:], out: u8[>..]&) {
    var entries: u8[>..] = [];
    guard list_dir(dir, entries) else { return; }
    var lstart:     i64       = 0;
    var goose_name: u8[..256] = [];
    var cand:       u8[>..]   = [];
    for j in entries.len {
        guard entries[j] == '\n' else { continue; }
        let name = crap::trim_ascii(entries[lstart..j]);
        lstart = j + 1;
        guard name.len > 6 && name.len <= goose_name.cap && crap::slice_ends_with(name, ".build") else { continue; }
        goose_name.clear();
        goose_name.append(name[..name.len - 6]);
        goose_name.append(".goose");
        cand.clear();
        check_join_norm(dir, goose_name[..], cand);
        if file_exists(cand[..]) && !is_dir(cand[..]) && !check_blob_contains_line(out[..], cand[..]) {
            out.append(cand[..]);
            out.push('\n');
        }
    }
}

fn resolve_enclosing_package_entries(
    target_file:     const u8[:],
    configured_blob: const u8[:],
    strict_only:     bool,
    out_entries:     u8[>..]&,
) -> bool {
    var norm_target: u8[>..] = [];
    crap::normalize_path(target_file, norm_target);

    var candidates: u8[>..] = [];
    var scratch:    u8[>..] = [];
    var c_start:    i64     = 0;
    while c_start < configured_blob.len {
        let rel_nl = crap::slice_index_of_byte(configured_blob[c_start..], '\n');
        let c_end = if rel_nl >= 0 { c_start + rel_nl } else { configured_blob.len };
        let item = crap::trim_ascii(configured_blob[c_start..c_end]);
        c_start = c_end + 1;
        guard item.len > 0 && file_exists(item) && !is_dir(item) else { continue; }
        scratch.clear();
        crap::normalize_path(item, scratch);
        if !check_blob_contains_line(candidates[..], scratch[..]) {
            candidates.append(scratch[..]);
            candidates.push('\n');
        }
    }

    // Walk upward from target's parent directory looking for <pkg>.build -> <pkg>.goose sidecars.
    var cur_dir: u8[>..] = [];
    check_parent_dir(norm_target[..], cur_dir);
    for _ in 12 {
        check_discover_build_entries_in_dir(cur_dir[..], candidates);
        if cur_dir[..] == "." || cur_dir[..] == "/" {
            break;
        }
        scratch.clear();
        check_parent_dir(cur_dir[..], scratch);
        if scratch[..] == cur_dir[..] {
            break;
        }
        cur_dir.clear();
        cur_dir.append(scratch[..]);
    }
    check_discover_build_entries_in_dir(".", candidates);

    guard candidates.len > 0 else { return false; }

    // Prefer entries that transitively import `norm_target`.
    // Reuse `cur_dir` for root_dir, `scratch` for single_root.
    var matched: u8[>..] = [];
    var covered: u8[>..] = [];
    var s:       i64     = 0;
    while s < candidates.len {
        let rel_nl = crap::slice_index_of_byte(candidates[s..], '\n');
        let e = if rel_nl >= 0 { s + rel_nl } else { candidates.len };
        let root_fp = crap::trim_ascii(candidates[s..e]);
        s = e + 1;
        guard root_fp.len > 0 else { continue; }

        scratch.clear();
        scratch.append(root_fp);
        scratch.push('\n');
        cur_dir.clear();
        check_parent_dir(root_fp, cur_dir);
        covered.clear();
        check_collect_covered_submodules(cur_dir[..], scratch[..], covered);
        if check_blob_contains_line(covered[..], norm_target[..]) {
            matched.append(root_fp);
            matched.push('\n');
        }
    }

    if matched.len > 0 {
        out_entries.append(matched[..]);
        return true;
    }

    if strict_only {
        return false;
    }

    out_entries.append(candidates[..]);
    return out_entries.len > 0;
}

fn run_single_goose_check(fpath: const u8[:], cc: const u8[:], out_buf: u8[>..]&) -> i32 {
    out_buf.clear();
    if cc.len > 0 {
        var cmd: u8[>..] = [];
        cmd.append("goose check --cc \"");
        cmd.append(cc);
        cmd.append("\" \"");
        cmd.append(fpath);
        cmd.push('"');
        return crap::exec_capture(cmd[..], out_buf);
    }
    return crap::exec_argv_capture("goose", "check", fpath, "", 0, out_buf);
}

// Typechecks `fpath`, falling back to enclosing package entry point(s) when
// `fpath` is an internal package submodule with package-root-relative imports
// or sibling-namespace declarations.
fn typecheck_file_with_fallback(
    fpath:           const u8[:],
    cc:              const u8[:],
    configured_blob: const u8[:],
    used_entry_out:  u8[>..]&,
    out_buf:         u8[>..]&,
) -> i32 {
    used_entry_out.clear();
    let rc = run_single_goose_check(fpath, cc, out_buf);
    if rc == 0 { return 0; }

    let missing_mod = crap::slice_contains(out_buf[..], "cannot find the module");
    var entries: u8[>..] = [];
    guard resolve_enclosing_package_entries(fpath, configured_blob, !missing_mod, entries) else { return rc; }

    var ent_out: u8[>..] = [];
    var s:       i64     = 0;
    while s < entries.len {
        let rel_nl = crap::slice_index_of_byte(entries[s..], '\n');
        let e = if rel_nl >= 0 { s + rel_nl } else { entries.len };
        let ent = crap::trim_ascii(entries[s..e]);
        s = e + 1;
        guard ent.len > 0 else { continue; }

        let erc = run_single_goose_check(ent, cc, ent_out);
        if erc != 0 {
            out_buf.clear();
            out_buf.append(ent_out[..]);
            return erc;
        }
        if used_entry_out.len > 0 {
            used_entry_out.append(", ");
        }
        used_entry_out.append(ent);
    }

    if used_entry_out.len > 0 {
        out_buf.clear();
        return 0;
    }
    return rc;
}

fn check_worker_loop(cfg: CheckWorkerCfg) {
    var list_blob: u8[>..] = [];
    guard read_file(cfg.list_path[..], list_blob) else { return; }

    var fpath:      u8[>..]   = [];
    var slot_path:  u8[..320] = [];
    var out_buf:    u8[>..]   = [];
    var used_entry: u8[>..]   = [];
    var slot_buf:   u8[>..]   = [];

    while true {
        if cfg.fail_fast && crap::native_atomic_get_stop() != 0 {
            break;
        }
        let idx = crap::native_work_claim(cfg.total);
        if idx < 0 { break; }

        fpath.clear();
        guard check_get_line(list_blob[..], idx, fpath) else { continue; }

        let t0 = (monotonic_now().nanos as! i64) / 1000;
        let rc = typecheck_file_with_fallback(
            fpath[..],
            cfg.cc[..],
            cfg.check_entries[..],
            used_entry,
            out_buf,
        );
        let dt_ms = ((monotonic_now().nanos as! i64) / 1000 - t0) / 1000;

        slot_buf.clear();
        if rc == 0 {
            slot_buf.append("PASS ");
            format(slot_buf, dt_ms);
            if used_entry.len > 0 {
                slot_buf.append(" via ");
                slot_buf.append(used_entry[..]);
            }
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
            write_stdout("Usage: goose-lit check <path...> [-j <N|auto>] [--filter <glob>] [--fail-fast] [--cc <cc>]\n");
            return false;
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
    if lit_cfg.has_jobs && lit_cfg.jobs > 0 && !lit_cfg.jobs_auto {
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

    var raw_files:    u8[>..] = [];
    var covered_blob: u8[>..] = [];
    var dir_roots:    u8[>..] = [];
    var t_start:      i64     = 0;
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
        if is_dir(t_item) && cfg.filter.len == 0 {
            dir_roots.clear();
            check_discover_root_goose_files(t_item, lit_cfg.exclude_buf[..], dir_roots);
            check_collect_covered_submodules(t_item, dir_roots[..], covered_blob);
        }
        crap::collect_goose_files_filtered(t_item, true, lit_cfg.exclude_buf[..], raw_files);
    }

    var files_blob:         u8[>..] = [];
    var norm_fp:            u8[>..] = [];
    var f_start:            i64     = 0;
    var total:              i32     = 0;
    var covered_submodules: i32     = 0;
    while f_start < raw_files.len {
        let rel_nl = crap::slice_index_of_byte(raw_files[f_start..], '\n');
        let f_end = if rel_nl >= 0 { f_start + rel_nl } else { raw_files.len };
        let fp = crap::trim_ascii(raw_files[f_start..f_end]);
        f_start = f_end + 1;
        guard fp.len > 0 else { continue; }
        norm_fp.clear();
        crap::normalize_path(fp, norm_fp);
        if cfg.filter.len == 0 && check_blob_contains_line(covered_blob[..], norm_fp[..]) {
            covered_submodules++;
            continue;
        }
        if cfg.filter.len > 0 {
            let last_sl = crap::slice_last_index_of_byte(fp, '/');
            let base = if last_sl >= 0 { fp[last_sl + 1..] } else { fp };
            if !crap::glob_match(cfg.filter, fp) && !crap::glob_match(cfg.filter, base) {
                continue;
            }
        }
        if !check_blob_contains_line(files_blob[..], fp) {
            files_blob.append(fp);
            files_blob.push('\n');
            total++;
        }
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
        crap::default_auto_jobs(1024)
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
    if lit_cfg.check_entries_buf.len > 0 {
        let _ = crap::set_bounded(wcfg.check_entries, lit_cfg.check_entries_buf[..]);
    } else if lit_cfg.sloc_bce_entries_buf.len > 0 {
        let _ = crap::set_bounded(wcfg.check_entries, lit_cfg.sloc_bce_entries_buf[..]);
    }

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
    var passed:    i32      = 0;
    var failed:    i32      = 0;
    var fp_buf:    u8[>..]  = [];
    var slot_p:    u8[..64] = [];
    var slot_data: u8[>..]  = [];

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
                    let meta = head[5..];
                    let via_idx = crap::slice_index_of(meta, " via ");
                    if via_idx >= 0 {
                        write_stdout(" (");
                        write_stdout(meta[..via_idx]);
                        write_stdout(" ms,");
                        write_stdout(meta[via_idx..]);
                        write_stdout(")");
                    } else {
                        write_stdout(" (");
                        write_stdout(meta);
                        write_stdout(" ms)");
                    }
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

    var sum: u8[..256] = [];
    sum.append("Check Summary: ");
    format(sum, passed, "/", total, " passed, ", failed, " failed");
    if covered_submodules > 0 {
        format(sum, " (+", covered_submodules, " submodules covered via root entries)");
    }
    format(sum, " in ", dt_all_ms, " ms\n");
    write_stdout(sum[..]);
    return if failed == 0 { 0 } else { 1 };
}
