// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sloc/baseline.goose - Baseline v1 persistence and ratchet/Pareto gate engine.
namespace lit;

import std;
import os;
import sys.bytes;
import crap.ast.model;
import sloc.model;
import sloc.correlate;

fn next_ws_token(line: const u8[:], pos: i64&) -> const u8[:] {
    let n = line.len;
    while pos < n && crap::is_ascii_space(line[pos]) {
        pos += 1;
    }
    let start = pos;
    while pos < n && !crap::is_ascii_space(line[pos]) {
        pos += 1;
    }
    guard start < pos && pos <= n else { return ""; }
    return line[start..pos];
}

fn parse_sloc_baseline(
    raw:        const u8[:],
    pool:       u8[>..]&,
    out:        SlocBaseline&,
    out_files:  SlocBaselineFile[>..]&,
    out_scopes: SlocBaselineScope[>..]&,
) -> bool {
    out = SlocBaseline { .. };
    var saw_header = false;
    var norm_buf: u8[>..] = [];
    var start:    i64     = 0;

    while start < raw.len {
        let rel_nl = crap::slice_index_of_byte(raw[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { raw.len };
        let line = crap::trim_ascii(raw[start..end]);
        start = end + 1;
        guard line.len > 0 else { continue; }

        if line[0] == '#' {
            if crap::slice_starts_with(line, "# goose-sloc baseline v1") {
                saw_header = true;
                if crap::slice_contains(line, "bce_measured=1") {
                    out.bce_measured = true;
                }
            }
            continue;
        }

        var pos: i64 = 0;
        let tag = next_ws_token(line, pos);
        if tag == "TOTAL" {
            let tf, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let ts, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let tst, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let tt, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let tc, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let tb, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let tsm, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            out.total_files = tf;
            out.total_sloc = ts;
            out.total_stmts = tst;
            out.total_tokens = tt;
            out.total_comments = tc;
            out.total_bce_kept = tb;
            out.total_smells = tsm;
            out.loaded = true;
        } else if tag == "FILE" {
            let raw_p = next_ws_token(line, pos);
            guard raw_p.len > 0 else { continue; }
            norm_buf.clear();
            crap::normalize_slashes(raw_p, norm_buf);
            var clean_p: const u8[:] = norm_buf[..];
            while crap::slice_starts_with(clean_p, "./") {
                clean_p = clean_p[2..];
            }
            let po, pl = crap::pool_add(pool, clean_p);
            let sl, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let st, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let tk, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let cm, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let pk, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let bk, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let sm, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            out_files.push(SlocBaselineFile {
                path_off:      po,
                path_len:      pl,
                sloc:          sl,
                stmts:         st,
                tokens:        tk,
                comment_lines: cm,
                packing_x100:  pk,
                bce_kept:      bk,
                smells_total:  sm,
            });
            out.loaded = true;
        } else if tag == "SCOPE" {
            let sname = next_ws_token(line, pos);
            let kind_s = next_ws_token(line, pos);
            guard sname.len > 0 else { continue; }
            let kind: u8 = if kind_s == "stage" { SLOC_SCOPE_STAGE } else { SLOC_SCOPE_BENCH };
            let no, nl = crap::pool_add(pool, sname);
            let sl, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let st, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let cyc, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let cps, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            let cl, _ = crap::parse_i64_slice(next_ws_token(line, pos));
            out_scopes.push(SlocBaselineScope {
                name_off:          no,
                name_len:          nl,
                kind:              kind,
                sloc:              sl,
                stmts:             st,
                cycles_x10:        cyc,
                cyc_per_sloc_x100: cps,
                cl_x10:            cl,
            });
        }
    }

    if saw_header {
        out.loaded = true;
    }
    return out.loaded;
}

fn find_prev_scope(
    name:        const u8[:],
    kind:        u8,
    prev_pool:   const u8[:],
    prev_scopes: const SlocBaselineScope[:],
) -> i64 {
    for i in prev_scopes.len {
        if prev_scopes[i].kind == kind {
            let pname = crap::pool_slice(prev_pool, prev_scopes[i].name_off, prev_scopes[i].name_len);
            if pname == name {
                return i;
            }
        }
    }
    return -1;
}

fn serialize_sloc_baseline(
    pool:            const u8[:],
    files:           const FileSlocStats[:],
    dirs:            const DirSlocStats[:],
    scopes:          const CycleSlocRow[:],
    bce_measured:    bool,
    prev_base:       const SlocBaseline&,
    prev_pool:       const u8[:],
    prev_scopes:     const SlocBaselineScope[:],
    preserve_cycles: bool,
    out:             u8[>..]&,
) {
    let _ = prev_base.loaded;
    out.append("# goose-sloc baseline v1 bce_measured=");
    out.push(if bce_measured { '1' } else { '0' });
    out.push('\n');

    var t_sloc:   i64 = 0;
    var t_stmts:  i64 = 0;
    var t_tokens: i64 = 0;
    var t_comm:   i64 = 0;
    var t_bce:    i64 = if bce_measured { 0 } else { -1 };
    var t_smells: i64 = 0;
    for &f in files {
        t_sloc += f.sloc;
        t_stmts += f.stmts;
        t_tokens += f.tokens;
        t_comm += f.comment_lines;
        t_smells += f.smells_total;
        if bce_measured && f.bce_kept > 0 {
            t_bce += f.bce_kept;
        }
    }

    out.append("TOTAL ");
    crap::append_i64(out, files.len);
    out.push(' ');
    crap::append_i64(out, t_sloc);
    out.push(' ');
    crap::append_i64(out, t_stmts);
    out.push(' ');
    crap::append_i64(out, t_tokens);
    out.push(' ');
    crap::append_i64(out, t_comm);
    out.push(' ');
    crap::append_i64(out, t_bce);
    out.push(' ');
    crap::append_i64(out, t_smells);
    out.push('\n');

    for &d in dirs {
        out.append("DIR ");
        out.append(crap::pool_slice(pool, d.dir_off, d.dir_len));
        out.push(' ');
        crap::append_i64(out, d.files);
        out.push(' ');
        crap::append_i64(out, d.sloc);
        out.push(' ');
        crap::append_i64(out, d.stmts);
        out.push(' ');
        crap::append_i64(out, d.tokens);
        out.push(' ');
        crap::append_i64(out, d.comment_lines);
        out.push(' ');
        crap::append_i64(out, d.smells_total);
        out.push('\n');
    }

    for &f in files {
        out.append("FILE ");
        out.append(crap::pool_slice(pool, f.path_off, f.path_len));
        out.push(' ');
        crap::append_i64(out, f.sloc);
        out.push(' ');
        crap::append_i64(out, f.stmts);
        out.push(' ');
        crap::append_i64(out, f.tokens);
        out.push(' ');
        crap::append_i64(out, f.comment_lines);
        out.push(' ');
        crap::append_i64(out, f.packing_x100);
        out.push(' ');
        crap::append_i64(out, if bce_measured { max(f.bce_kept, 0) } else { -1 });
        out.push(' ');
        crap::append_i64(out, f.smells_total);
        out.push('\n');
    }

    if scopes.len > 0 {
        for &s in scopes {
            let sname = crap::pool_slice(pool, s.name_off, s.name_len);
            var cyc = s.cycles_x10;
            var cps = s.cyc_per_sloc_x100;
            var cl = s.cl_x10;
            if cyc <= 0 && preserve_cycles {
                let pi = find_prev_scope(sname, s.kind, prev_pool, prev_scopes);
                if pi >= 0 {
                    cyc = prev_scopes[pi].cycles_x10;
                    if s.sloc > 0 && cyc > 0 {
                        cps = (cyc * 10 + (s.sloc / 2)) / s.sloc;
                        cl = cyc * s.sloc;
                    }
                }
            }
            out.append("SCOPE ");
            out.append(sname);
            out.append(if s.kind == SLOC_SCOPE_STAGE { " stage " } else { " bench " });
            crap::append_i64(out, s.sloc);
            out.push(' ');
            crap::append_i64(out, s.stmts);
            out.push(' ');
            crap::append_i64(out, cyc);
            out.push(' ');
            crap::append_i64(out, cps);
            out.push(' ');
            crap::append_i64(out, cl);
            out.push('\n');
        }
    } else if preserve_cycles && prev_scopes.len > 0 {
        for &ps in prev_scopes {
            let sname = crap::pool_slice(prev_pool, ps.name_off, ps.name_len);
            out.append("SCOPE ");
            out.append(sname);
            out.append(if ps.kind == SLOC_SCOPE_STAGE { " stage " } else { " bench " });
            crap::append_i64(out, ps.sloc);
            out.push(' ');
            crap::append_i64(out, ps.stmts);
            out.push(' ');
            crap::append_i64(out, ps.cycles_x10);
            out.push(' ');
            crap::append_i64(out, ps.cyc_per_sloc_x100);
            out.push(' ');
            crap::append_i64(out, ps.cl_x10);
            out.push('\n');
        }
    }
}

fn find_baseline_file(
    fpath:      const u8[:],
    base_pool:  const u8[:],
    base_files: const SlocBaselineFile[:],
) -> i64 {
    for i in base_files.len {
        let bp = crap::pool_slice(base_pool, base_files[i].path_off, base_files[i].path_len);
        if bp == fpath || crap::paths_match(bp, fpath) {
            return i;
        }
    }
    return -1;
}

inline fn promote_verdict(cur: u8&, next: u8) {
    if next > cur {
        cur = next;
    }
}

fn append_reason(dst: u8[..512]&, msg: const u8[:]) {
    if dst.len > 0 {
        guard dst.len + 2 <= dst.cap else { return; }
        dst.append("; ");
    }
    let rem = dst.cap - dst.len;
    let n = min(msg.len, rem);
    if n > 0 {
        dst.append(msg[..n]);
    }
}

fn evaluate_sloc_gate(
    cfg:             const SlocCliArgs&,
    pool:            const u8[:],
    maps:            const ScopeMapping[:],
    files:           FileSlocStats[>..]&,
    scopes:          CycleSlocRow[>..]&,
    base:            const SlocBaseline&,
    base_pool:       const u8[:],
    base_files:      const SlocBaselineFile[:],
    base_scopes:     const SlocBaselineScope[:],
    is_partial_scan: bool,
    format_fails:    i64,
    res:             SlocGateResult&,
) {
    res = SlocGateResult { .. };
    res.audit.has_baseline = base.loaded;
    res.audit.format_violations = format_fails;

    let max_pack_x100 = ((cfg.max_packing * 100.0) + 0.5) as! i64;
    let max_tok_x100 = ((cfg.max_token_density * 100.0) + 0.5) as! i64;

    var cur_sloc:     i64 = 0;
    var cur_stmts:    i64 = 0;
    var cur_tokens:   i64 = 0;
    var cur_comments: i64 = 0;
    var cur_smells:   i64 = 0;
    var cur_bce:      i64 = 0;
    var any_bce_meas = false;

    var sub_base_sloc:     i64 = 0;
    var sub_base_stmts:    i64 = 0;
    var sub_base_tokens:   i64 = 0;
    var sub_base_comments: i64 = 0;
    var sub_base_smells:   i64 = 0;
    var sub_base_bce:      i64 = 0;
    var bce_file_regressed = false;

    for &f in files {
        f.packing_violation = false;
        f.packing_delta_violation = false;
        f.tok_density_violation = false;

        cur_sloc += f.sloc;
        cur_stmts += f.stmts;
        cur_tokens += f.tokens;
        cur_comments += f.comment_lines;
        cur_smells += f.smells_total;
        if f.bce_kept >= 0 {
            any_bce_meas = true;
            cur_bce += f.bce_kept;
        }

        if cfg.check_packing && f.sloc >= 10 && f.packing_x100 > max_pack_x100 {
            f.packing_violation = true;
            res.audit.packing_violations += 1;
        }
        if cfg.max_token_density > 0.0 && f.sloc >= 10 && f.tok_density_x100 > max_tok_x100 {
            f.tok_density_violation = true;
            res.audit.packing_violations += 1;
        }

        if base.loaded {
            let fpath = crap::pool_slice(pool, f.path_off, f.path_len);
            let bi = find_baseline_file(fpath, base_pool, base_files);
            if bi >= 0 {
                let bf = base_files[bi];
                sub_base_sloc += bf.sloc;
                sub_base_stmts += bf.stmts;
                sub_base_tokens += bf.tokens;
                sub_base_comments += bf.comment_lines;
                sub_base_smells += bf.smells_total;
                if bf.bce_kept >= 0 {
                    sub_base_bce += bf.bce_kept;
                }
                let delta_pack_gaming = f.sloc < bf.sloc && f.stmts >= bf.stmts &&
                    (f.packing_x100 - bf.packing_x100) > 15 &&
                    (f.packing_x100 > 100 || (bf.tokens > 0 && f.tokens * 100 >= bf.tokens * 95));
                if cfg.check_packing && delta_pack_gaming {
                    f.packing_delta_violation = true;
                    res.audit.packing_violations += 1;
                }
                if cfg.bce_enabled && base.bce_measured && f.bce_kept >= 0 && bf.bce_kept >= 0 && f.bce_kept > bf.bce_kept {
                    bce_file_regressed = true;
                }
            }
        }
    }

    res.audit.cur_sloc = cur_sloc;
    var best_verdict: u8 = SLOC_VERDICT_UNCHANGED;

    if base.loaded {
        let b_sloc = if is_partial_scan { sub_base_sloc } else { base.total_sloc };
        let b_stmts = if is_partial_scan { sub_base_stmts } else { base.total_stmts };
        let b_tokens = if is_partial_scan { sub_base_tokens } else { base.total_tokens };
        let b_comments = if is_partial_scan { sub_base_comments } else { base.total_comments };
        let b_smells = if is_partial_scan { sub_base_smells } else { base.total_smells };
        let b_bce = if is_partial_scan { sub_base_bce } else { base.total_bce_kept };

        res.audit.base_sloc = b_sloc;
        res.audit.delta_sloc = cur_sloc - b_sloc;
        res.audit.delta_stmts = cur_stmts - b_stmts;
        res.audit.delta_tokens = cur_tokens - b_tokens;
        res.audit.delta_comments = cur_comments - b_comments;
        res.audit.delta_smells = cur_smells - b_smells;

        if cfg.bce_enabled {
            if !base.bce_measured {
                res.audit.bce_skipped_unmeasured = true;
            } else if any_bce_meas && b_bce >= 0 {
                res.audit.bce_compared = true;
                res.audit.delta_bce_kept = cur_bce - b_bce;
                if cur_bce > b_bce || bce_file_regressed {
                    promote_verdict(best_verdict, SLOC_VERDICT_GAMING_DETECTED);
                    append_reason(res.reason, "bce:keep regressed");
                }
            }
        }

        // Scope Pareto evaluation (deduplicating hot-growth credits across overlapping scopes)
        var hot_file_mask: u8[>..] = [];
        for _ in files.len {
            hot_file_mask.push(0);
        }
        var any_hot_mapped = false;
        var unmapped_hot_credit: i64 = 0;

        for &sc in scopes {
            let sname = crap::pool_slice(pool, sc.name_off, sc.name_len);
            let bi = find_prev_scope(sname, sc.kind, base_pool, base_scopes);
            guard bi >= 0 else { continue; }
            let bs = base_scopes[bi];
            sc.base_sloc = bs.sloc;
            sc.base_cycles_x10 = bs.cycles_x10;

            guard sc.cycles_x10 > 0 && bs.cycles_x10 > 0 && sc.sloc > 0 && bs.sloc > 0 else {
                continue;
            }

            let cur_c = sc.cycles_x10 as f64;
            let base_c = bs.cycles_x10 as f64;
            let norm_cl = (cur_c / base_c) * ((sc.sloc as f64) / bs.sloc);
            sc.norm_cl_x1000 = ((norm_cl * 1000.0) + 0.5) as! i64;

            let hi_c = base_c * (1.0 + cfg.cycle_noise / 100.0);
            let lo_c = base_c * (1.0 - cfg.cycle_noise / 100.0);

            if sc.sloc < bs.sloc && cur_c > hi_c {
                sc.verdict = SLOC_VERDICT_SLOC_WIN_PERF_REGRESS;
                append_reason(res.reason, "SLOC win regressed cycles");
            } else if cur_c > hi_c {
                sc.verdict = SLOC_VERDICT_REGRESSION;
                append_reason(res.reason, "scope cycles regressed");
            } else if cur_c < lo_c && sc.sloc > bs.sloc {
                if cfg.allow_hot_growth && sc.norm_cl_x1000 <= 900 {
                    sc.verdict = SLOC_VERDICT_PARETO_WIN;
                    sc.hot_growth_credited = sc.sloc - bs.sloc;
                    let mi: i64 = sc.map_idx;
                    if mi >= 0 && mi < maps.len {
                        any_hot_mapped = true;
                        let prefs = crap::pool_slice(pool, maps[mi].prefixes_off, maps[mi].prefixes_len);
                        for fi in files.len {
                            let fpath = crap::pool_slice(pool, files[fi].path_off, files[fi].path_len);
                            if path_matches_prefix_csv(fpath, prefs) {
                                hot_file_mask[fi] = 1;
                            }
                        }
                    } else {
                        unmapped_hot_credit += sc.hot_growth_credited;
                    }
                } else {
                    sc.verdict = SLOC_VERDICT_PERF_WIN_BLOAT_WARN;
                    append_reason(res.reason, "perf win grew SLOC");
                }
            } else if sc.sloc < bs.sloc || cur_c < lo_c {
                sc.verdict = SLOC_VERDICT_PARETO_WIN;
            } else {
                sc.verdict = SLOC_VERDICT_UNCHANGED;
            }
            promote_verdict(best_verdict, sc.verdict);
        }

        if any_hot_mapped {
            var unique_hot_delta: i64 = 0;
            for fi in files.len {
                guard hot_file_mask[fi] == 1 else { continue; }
                let fpath = crap::pool_slice(pool, files[fi].path_off, files[fi].path_len);
                let bfi = find_baseline_file(fpath, base_pool, base_files);
                let prev_sloc = if bfi >= 0 { base_files[bfi].sloc } else { 0 };
                unique_hot_delta += (files[fi].sloc - prev_sloc);
            }
            if unique_hot_delta > 0 {
                res.audit.hot_growth_credit_sum += unique_hot_delta;
            }
        }
        res.audit.hot_growth_credit_sum += unmapped_hot_credit;

        let eff_delta = cfg.sloc_delta + res.audit.hot_growth_credit_sum;
        if res.audit.delta_sloc > eff_delta {
            promote_verdict(best_verdict, SLOC_VERDICT_REGRESSION);
            append_reason(res.reason, "SLOC exceeded budget");
        } else if res.audit.delta_sloc < 0 && best_verdict == SLOC_VERDICT_UNCHANGED {
            promote_verdict(best_verdict, SLOC_VERDICT_PARETO_WIN);
        }

        if cfg.check_smells && res.audit.delta_smells > 0 {
            promote_verdict(best_verdict, SLOC_VERDICT_REGRESSION);
            append_reason(res.reason, "compiler smells increased");
        }
    }

    if res.audit.packing_violations > 0 {
        promote_verdict(best_verdict, SLOC_VERDICT_GAMING_DETECTED);
        append_reason(res.reason, "packing violation");
    }
    if format_fails > 0 {
        promote_verdict(best_verdict, SLOC_VERDICT_GAMING_DETECTED);
        append_reason(res.reason, "goose format --check failed");
    }

    res.verdict = best_verdict;
    res.exit_code = if best_verdict >= SLOC_VERDICT_PERF_WIN_BLOAT_WARN { 1 } else { 0 };
}
