// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sloc/correlate.goose - Scope map parser, repeatable profile runner, and
// RDTSC cycles-vs-SLOC correlation engine.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import crap.ast.model;
import profile.cli;
import runner.lit_runner;
import sloc.model;

fn normalize_map_path(raw: const u8[:], out: u8[>..]&) {
    var tmp: u8[>..] = [];
    crap::normalize_slashes(raw, tmp);
    var s: const u8[:] = crap::trim_ascii(tmp[..]);
    while crap::slice_starts_with(s, "./") {
        s = s[2..];
    }
    out.append(s);
}

fn normalize_prefix_list(raw: const u8[:], out: u8[>..]&) {
    var first = true;
    var item_buf: u8[>..] = [];
    var rem = raw;
    while rem.len > 0 {
        let tok, rest = crap::take_next_delim(rem, ',');
        rem = rest;
        guard tok.len > 0 else { continue; }
        item_buf.clear();
        normalize_map_path(tok, item_buf);
        guard item_buf.len > 0 else { continue; }
        if !first {
            out.push(',');
        }
        first = false;
        out.append(item_buf[..]);
    }
}

fn extract_delim_col(line: const u8[:], delim: u8, col_idx: i64) -> const u8[:] {
    var cur:   i64 = 0;
    var start: i64 = 0;
    for i in line.len {
        if line[i] == delim {
            if cur == col_idx {
                return crap::trim_ascii(line[start..i]);
            }
            cur += 1;
            start = i + 1;
        }
    }
    if cur == col_idx {
        return crap::trim_ascii(line[start..]);
    }
    return "";
}

fn parse_sloc_map(raw: const u8[:], pool: u8[>..]&, maps: ScopeMapping[>..]&) -> i64 {
    var added:    i64     = 0;
    var pref_buf: u8[>..] = [];
    var b_buf:    u8[>..] = [];
    var rem = raw;

    while rem.len > 0 {
        let line, rest = crap::take_next_line(rem);
        rem = rest;
        guard line.len > 0 && line[0] != '#' else { continue; }

        let delim: u8 = if crap::slice_index_of_byte(line, '|') >= 0 { '|' } else { '\t' };
        let name = extract_delim_col(line, delim, 0);
        let kind_s = extract_delim_col(line, delim, 1);
        let prefs_raw = extract_delim_col(line, delim, 2);
        let bench_raw = extract_delim_col(line, delim, 3);
        guard name.len > 0 && prefs_raw.len > 0 else { continue; }

        var kind: u8 = 0;
        if kind_s == "bench" {
            kind = SLOC_SCOPE_BENCH;
        } else if kind_s == "stage" {
            kind = SLOC_SCOPE_STAGE;
        } else {
            continue;
        }

        pref_buf.clear();
        normalize_prefix_list(prefs_raw, pref_buf);
        guard pref_buf.len > 0 else { continue; }

        b_buf.clear();
        if bench_raw.len > 0 {
            normalize_map_path(bench_raw, b_buf);
        }

        let no, nl = crap::pool_add(pool, name);
        let po, pl = crap::pool_add(pool, pref_buf[..]);
        var bo: i32 = 0;
        var bl: i32 = 0;
        if b_buf.len > 0 {
            bo, bl = crap::pool_add(pool, b_buf[..]);
        }
        maps.push(ScopeMapping {
            name_off:     no,
            name_len:     nl,
            kind:         kind,
            prefixes_off: po,
            prefixes_len: pl,
            bench_off:    bo,
            bench_len:    bl,
        });
        added += 1;
    }
    return added;
}

fn parse_profile_tsv_samples(raw: const u8[:], samples: ProfileSample[>..]&) -> i64 {
    var added: i64 = 0;
    var rem = raw;
    while rem.len > 0 {
        let line, rest = crap::take_next_line(rem);
        rem = rest;

        if crap::slice_starts_with(line, "@LIT_BENCH\t") {
            var s = ProfileSample { kind: SLOC_SCOPE_BENCH, .. };
            let _ = crap::set_bounded(s.case_name, extract_tsv_col(line, 2));
            let iters, _ = crap::parse_i64_slice(extract_tsv_col(line, 3));
            s.calls = iters;
            s.cycles_x10 = parse_decimal_x10(extract_tsv_col(line, 5));
            let sb, _ = crap::parse_i64_slice(extract_tsv_col(line, 8));
            s.scratch_b = sb;
            samples.push(s);
            added += 1;
        } else if crap::slice_starts_with(line, "@LIT_STAGE\t") {
            var s = ProfileSample { kind: SLOC_SCOPE_STAGE, .. };
            let _ = crap::set_bounded(s.case_name, extract_tsv_col(line, 1));
            let _ = crap::set_bounded(s.stage_name, extract_tsv_col(line, 2));
            let calls, _ = crap::parse_i64_slice(extract_tsv_col(line, 3));
            s.calls = calls;
            s.cycles_x10 = parse_decimal_x10(extract_tsv_col(line, 4));
            let sb, _ = crap::parse_i64_slice(extract_tsv_col(line, 10));
            s.scratch_b = sb;
            samples.push(s);
            added += 1;
        }
    }
    return added;
}

fn path_matches_scope_prefix(fpath: const u8[:], pref: const u8[:]) -> bool {
    guard pref.len > 0 && fpath.len > 0 else { return false; }
    if pref == "." || pref == "./" { return true; }
    var f = fpath;
    while f.len > 1 && f[f.len - 1] == '/' {
        f = f[..f.len - 1];
    }
    var p = pref;
    while p.len > 1 && p[p.len - 1] == '/' {
        p = p[..p.len - 1];
    }
    if f == p { return true; }
    return f.len > p.len && crap::slice_starts_with(f, p) && f[p.len] == '/';
}

fn path_matches_prefix_csv(fpath: const u8[:], csv: const u8[:]) -> bool {
    var rem = csv;
    while rem.len > 0 {
        let pref, rest = crap::take_next_delim(rem, ',');
        rem = rest;
        if pref.len > 0 && path_matches_scope_prefix(fpath, pref) {
            return true;
        }
    }
    return false;
}

fn scope_covered_by_scan(scope_csv: const u8[:], scan_prefixes_nl: const u8[:]) -> bool {
    var checked: i64 = 0;
    var s_rem = scope_csv;
    while s_rem.len > 0 {
        let pref, s_rest = crap::take_next_delim(s_rem, ',');
        s_rem = s_rest;
        guard pref.len > 0 else { continue; }
        checked += 1;

        var covered = false;
        var t_rem = scan_prefixes_nl;
        while t_rem.len > 0 {
            let target, t_rest = crap::take_next_line(t_rem);
            t_rem = t_rest;
            guard target.len > 0 else { continue; }
            if target == "." || path_matches_scope_prefix(pref, target) {
                covered = true;
                break;
            }
        }
        guard covered else { return false; }
    }
    return checked > 0;
}

fn match_scope_cycles_x10(scope_name: const u8[:], kind: u8, samples: const ProfileSample[:]) -> i64 {
    if kind == SLOC_SCOPE_BENCH {
        for &s in samples {
            if s.kind == SLOC_SCOPE_BENCH && s.case_name[..] == scope_name {
                return s.cycles_x10;
            }
        }
        return 0;
    }

    // Stage matching: `case_name::stage_name`, `*::stage_name`, or bare `stage_name`
    let sep = crap::slice_index_of(scope_name, "::");
    let is_wild = sep < 0 || scope_name[..sep] == "*";
    let want_stage = if sep >= 0 { scope_name[sep + 2..] } else { scope_name };

    if !is_wild {
        let want_case = scope_name[..sep];
        for &s in samples {
            if s.kind == SLOC_SCOPE_STAGE && s.case_name[..] == want_case && s.stage_name[..] == want_stage {
                return s.cycles_x10;
            }
        }
        return 0;
    }

    // Call-weighted mean across matching stage samples
    var w_sum:     i64 = 0;
    var w_cyc_sum: i64 = 0;
    for &s in samples {
        if s.kind == SLOC_SCOPE_STAGE && s.stage_name[..] == want_stage {
            let w = if s.calls > 0 { s.calls } else { 1 };
            w_sum += w;
            w_cyc_sum += w * s.cycles_x10;
        }
    }
    guard w_sum > 0 else { return 0; }
    return (w_cyc_sum + (w_sum / 2)) / w_sum;
}

fn classify_sloc_radar(cycles_x10: i64, cyc_per_sloc_x100: i64) -> u8 {
    if cycles_x10 <= 0 { return SLOC_RADAR_UNPROFILED; }
    if cyc_per_sloc_x100 >= 100 { return SLOC_RADAR_HOT_KERNEL; }
    if cyc_per_sloc_x100 >= 10 { return SLOC_RADAR_BALANCED; }
    return SLOC_RADAR_COLD_BLOAT;
}

fn correlate_scopes(
    maps:            const ScopeMapping[:],
    pool:            const u8[:],
    files:           const FileSlocStats[:],
    samples:         const ProfileSample[:],
    scan_prefixes:   const u8[:],
    is_partial_scan: bool,
    rows:            CycleSlocRow[>..]&,
) {
    for mi in maps.len {
        let m = maps[mi];
        let prefs = crap::pool_slice(pool, m.prefixes_off, m.prefixes_len);
        if is_partial_scan && !scope_covered_by_scan(prefs, scan_prefixes) {
            continue;
        }

        var row = CycleSlocRow {
            map_idx:  mi as i32,
            name_off: m.name_off,
            name_len: m.name_len,
            kind:     m.kind,
            ..
        };

        for &f in files {
            let fpath = crap::pool_slice(pool, f.path_off, f.path_len);
            if path_matches_prefix_csv(fpath, prefs) {
                row.files += 1;
                row.sloc += f.sloc;
                row.stmts += f.stmts;
            }
        }

        let sname = crap::pool_slice(pool, m.name_off, m.name_len);
        row.cycles_x10 = match_scope_cycles_x10(sname, m.kind, samples);
        if row.sloc > 0 && row.cycles_x10 > 0 {
            row.cyc_per_sloc_x100 = (row.cycles_x10 * 10 + (row.sloc / 2)) / row.sloc;
            row.cl_x10 = row.cycles_x10 * row.sloc;
        }
        if row.stmts > 0 && row.cycles_x10 > 0 {
            row.cyc_per_stmt_x100 = (row.cycles_x10 * 10 + (row.stmts / 2)) / row.stmts;
        }
        row.radar = classify_sloc_radar(row.cycles_x10, row.cyc_per_sloc_x100);
        rows.push(row);
    }
}

fn collect_unique_map_benches(maps: const ScopeMapping[:], pool: const u8[:], out_blob: u8[>..]&) {
    for &m in maps {
        guard m.bench_len > 0 else { continue; }
        let b = crap::pool_slice(pool, m.bench_off, m.bench_len);
        if b.len > 0 && !crap::blob_contains_line(out_blob[..], b) {
            out_blob.append(b);
            out_blob.push('\n');
        }
    }
}

fn run_profile_benchmarks(
    bench_paths_blob: const u8[:],
    cc:               const u8[:],
    benchtime:        const u8[:],
    filter:           const u8[:],
    tsv_out:          u8[>..]&,
) -> i32 {
    crap::ensure_lit_cache_dir();

    var prog_raw: u8[>..] = [];
    arg(0, prog_raw);
    var prog_abs: u8[>..] = [];
    let prog_has_sep = crap::slice_index_of_byte(prog_raw[..], '/') >= 0 ||
        crap::slice_index_of_byte(prog_raw[..], '\\') >= 0;
    let prog = if prog_has_sep && crap::resolve_abs_path(prog_raw[..], prog_abs) {
        prog_abs[..]
    } else {
        prog_raw[..]
    };

    var cc_abs: u8[>..] = [];
    let cc_has_sep = cc.len > 0 &&
        (crap::slice_index_of_byte(cc, '/') >= 0 || crap::slice_index_of_byte(cc, '\\') >= 0);
    let eff_cc = if cc_has_sep && crap::resolve_abs_path(cc, cc_abs) {
        cc_abs[..]
    } else {
        cc
    };

    var seen:    u8[>..]  = [];
    var cmd:     u8[>..]  = [];
    var cap_out: u8[>..]  = [];
    var tmp_tsv: u8[..64] = [];
    var tsv_buf: u8[>..]  = [];

    var b_rem = bench_paths_blob;
    while b_rem.len > 0 {
        let bench, rest = crap::take_next_line(b_rem);
        b_rem = rest;
        guard bench.len > 0 && !crap::blob_contains_line(seen[..], bench) else { continue; }
        seen.append(bench);
        seen.push('\n');

        guard file_exists(bench) else {
            write_stdout("Error: benchmark file not found: ");
            write_stdout(bench);
            write_stdout("\n");
            return 1;
        }

        tmp_tsv.clear();
        tmp_tsv.append(".lit/cache/.sloc_prof_");
        crap::append_u64(tmp_tsv, crap::native_next_seq());
        tmp_tsv.append(".tsv");

        cmd.clear();
        cmd.append(prog);
        cmd.push(0);
        cmd.append("profile");
        cmd.push(0);
        cmd.append(bench);
        cmd.push(0);
        if eff_cc.len > 0 {
            cmd.append("--cc");
            cmd.push(0);
            cmd.append(eff_cc);
            cmd.push(0);
        }
        if benchtime.len > 0 {
            cmd.append("--benchtime");
            cmd.push(0);
            cmd.append(benchtime);
            cmd.push(0);
        }
        if filter.len > 0 {
            cmd.append("--filter");
            cmd.push(0);
            cmd.append(filter);
            cmd.push(0);
        }
        cmd.append("--save");
        cmd.push(0);
        cmd.append(tmp_tsv[..]);
        cmd.push(0);

        cap_out.clear();
        let rc = crap::exec_argv_nul_capture(cmd[..], 0, cap_out);
        if rc != 0 {
            write_stdout("Error: profile run failed for ");
            write_stdout(bench);
            write_stdout(":\n");
            write_stdout(cap_out[..]);
            if file_exists(tmp_tsv[..]) {
                let _ = delete_file(tmp_tsv[..]);
            }
            return rc;
        }

        if file_exists(tmp_tsv[..]) {
            tsv_buf.clear();
            if read_file(tmp_tsv[..], tsv_buf) {
                tsv_out.append(tsv_buf[..]);
            }
            let _ = delete_file(tmp_tsv[..]);
        }
    }
    return 0;
}
