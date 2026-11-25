// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sloc/report.goose - Table, Markdown, JSON, and TSV formatters with Self-Audit output.
namespace lit;

import std;
import sys.bytes;
import crap.ast.model;
import sloc.model;

fn append_fixed_x10(out: u8[>..]&, val_x10: i64) {
    var v = val_x10;
    if v < 0 {
        out.push('-');
        v = 0 - v;
    }
    crap::append_i64(out, v / 10);
    out.push('.');
    crap::append_i64(out, v % 10);
}

fn append_fixed_x100(out: u8[>..]&, val_x100: i64) {
    var v = val_x100;
    if v < 0 {
        out.push('-');
        v = 0 - v;
    }
    crap::append_i64(out, v / 100);
    out.push('.');
    let frac = v % 100;
    crap::append_i64(out, frac / 10);
    crap::append_i64(out, frac % 10);
}

fn append_signed_i64(out: u8[>..]&, val: i64) {
    if val > 0 {
        out.push('+');
    }
    crap::append_i64(out, val);
}

fn sum_file_totals(
    files:    const FileSlocStats[:],
    sloc_out: i64&,
    stmt_out: i64&,
    tok_out:  i64&,
    comm_out: i64&,
    sm_out:   i64&,
) {
    sloc_out = 0;
    stmt_out = 0;
    tok_out = 0;
    comm_out = 0;
    sm_out = 0;
    for &f in files {
        sloc_out += f.sloc;
        stmt_out += f.stmts;
        tok_out += f.tokens;
        comm_out += f.comment_lines;
        sm_out += f.smells_total;
    }
}

fn format_sloc_report_table(
    cfg:      const SlocCliArgs&,
    pool:     const u8[:],
    files:    const FileSlocStats[:],
    dirs:     const DirSlocStats[:],
    dead_fns: const DeadFnCandidate[:],
    scopes:   const CycleSlocRow[:],
    gate_res: const SlocGateResult&,
    out:      u8[>..]&,
) {
    var t_sloc:   i64 = 0;
    var t_stmts:  i64 = 0;
    var t_tokens: i64 = 0;
    var t_comm:   i64 = 0;
    var t_smells: i64 = 0;
    sum_file_totals(files, t_sloc, t_stmts, t_tokens, t_comm, t_smells);
    let avg_pack = if t_sloc > 0 { (t_stmts * 100 + (t_sloc / 2)) / t_sloc } else { 0 };

    out.append("=== goose-lit sloc (Cycles vs SLOC Radar) ===\n");
    out.append("Files: ");
    crap::append_i64(out, files.len);
    out.append(" | SLOC: ");
    crap::append_i64(out, t_sloc);
    out.append(" | Stmts: ");
    crap::append_i64(out, t_stmts);
    out.append(" | Pack: ");
    append_fixed_x100(out, avg_pack);
    out.append(" | Comments: ");
    crap::append_i64(out, t_comm);
    out.append(" | Smells: ");
    crap::append_i64(out, t_smells);
    out.append(" | Verdict: ");
    out.append(sloc_verdict_name(gate_res.verdict));
    out.push('\n');

    if gate_res.audit.has_baseline {
        out.append("Self-Audit Delta: SLOC ");
        append_signed_i64(out, gate_res.audit.delta_sloc);
        out.append(" | Stmts ");
        append_signed_i64(out, gate_res.audit.delta_stmts);
        out.append(" | Tokens ");
        append_signed_i64(out, gate_res.audit.delta_tokens);
        out.append(" | Comments ");
        append_signed_i64(out, gate_res.audit.delta_comments);
        out.append(" | Smells ");
        append_signed_i64(out, gate_res.audit.delta_smells);
        if gate_res.audit.bce_compared {
            out.append(" | BCE_kept ");
            append_signed_i64(out, gate_res.audit.delta_bce_kept);
        } else if gate_res.audit.bce_skipped_unmeasured {
            out.append(" | BCE: skipped (baseline unmeasured)");
        }
        if gate_res.audit.hot_growth_credit_sum > 0 {
            out.append(" | HotCredit +");
            crap::append_i64(out, gate_res.audit.hot_growth_credit_sum);
        }
        out.push('\n');
    }

    if gate_res.reason.len > 0 {
        out.append("Gate Notes: ");
        out.append(gate_res.reason[..]);
        out.push('\n');
    }

    if dirs.len > 0 {
        out.append("\nDirectory Breakdown:\n");
        out.append("  Directory                  | Files |    SLOC |   Stmts |  Pack | Smells\n");
        out.append("  ---------------------------+-------+---------+---------+-------+-------\n");
        var nb: u8[..32] = [];
        for &d in dirs {
            out.append("  ");
            crap::append_padded_right(out, crap::pool_slice(pool, d.dir_off, d.dir_len), 26);
            out.append(" | ");
            nb.clear();
            crap::append_i64(nb, d.files);
            crap::append_padded_left(out, nb[..], 5);
            out.append(" | ");
            nb.clear();
            crap::append_i64(nb, d.sloc);
            crap::append_padded_left(out, nb[..], 7);
            out.append(" | ");
            nb.clear();
            crap::append_i64(nb, d.stmts);
            crap::append_padded_left(out, nb[..], 7);
            out.append(" | ");
            let dp = if d.sloc > 0 { (d.stmts * 100 + (d.sloc / 2)) / d.sloc } else { 0 };
            var pb: u8[>..] = [];
            append_fixed_x100(pb, dp);
            crap::append_padded_left(out, pb[..], 5);
            out.append(" | ");
            nb.clear();
            crap::append_i64(nb, d.smells_total);
            crap::append_padded_left(out, nb[..], 6);
            out.push('\n');
        }
    }

    if scopes.len > 0 {
        out.append("\nCycles-vs-SLOC Scopes:\n");
        out.append("  Scope                              | Kind  |   SLOC |   Cycles | Cyc/SLOC |          CL | Radar      | Verdict\n");
        out.append("  -----------------------------------+-------+--------+----------+----------+-------------+------------+--------\n");
        var nb: u8[>..] = [];
        for &s in scopes {
            out.append("  ");
            crap::append_padded_right(out, crap::pool_slice(pool, s.name_off, s.name_len), 34);
            out.append(" | ");
            out.append(if s.kind == SLOC_SCOPE_STAGE { "stage" } else { "bench" });
            out.append(" | ");
            nb.clear();
            crap::append_i64(nb, s.sloc);
            crap::append_padded_left(out, nb[..], 6);
            out.append(" | ");
            nb.clear();
            append_fixed_x10(nb, s.cycles_x10);
            crap::append_padded_left(out, nb[..], 8);
            out.append(" | ");
            nb.clear();
            append_fixed_x100(nb, s.cyc_per_sloc_x100);
            crap::append_padded_left(out, nb[..], 8);
            out.append(" | ");
            nb.clear();
            append_fixed_x10(nb, s.cl_x10);
            crap::append_padded_left(out, nb[..], 11);
            out.append(" | ");
            crap::append_padded_right(out, sloc_radar_name(s.radar), 10);
            out.append(" | ");
            out.append(sloc_verdict_name(s.verdict));
            out.push('\n');
        }
    }

    if gate_res.audit.packing_violations > 0 {
        out.append("\nPacking / Density Violations:\n");
        for &f in files {
            if f.packing_violation || f.packing_delta_violation || f.tok_density_violation {
                out.append("  [GAMING] ");
                out.append(crap::pool_slice(pool, f.path_off, f.path_len));
                out.append(" sloc=");
                crap::append_i64(out, f.sloc);
                out.append(" stmts=");
                crap::append_i64(out, f.stmts);
                out.append(" pack=");
                append_fixed_x100(out, f.packing_x100);
                out.push('\n');
            }
        }
    }

    if cfg.show_smells {
        out.append("\nCompiler Smells (per file with smells > 0):\n");
        for &f in files {
            guard f.smells_total > 0 else { continue; }
            out.append("  ");
            out.append(crap::pool_slice(pool, f.path_off, f.path_len));
            out.append(": total=");
            crap::append_i64(out, f.smells_total);
            out.append(" (u64_loop=");
            crap::append_i64(out, f.smell_u64_loop);
            out.append(", sat_loop=");
            crap::append_i64(out, f.smell_sat_loop);
            out.append(", val_for=");
            crap::append_i64(out, f.smell_val_copy_for);
            out.append(", while_len=");
            crap::append_i64(out, f.smell_manual_while);
            out.append(", multiret_inline=");
            crap::append_i64(out, f.smell_multiret_inline);
            out.append(")\n");
        }
        if dead_fns.len > 0 {
            out.append("\nAdvisory dead_fn candidates (zero repo-wide call sites): ");
            crap::append_i64(out, dead_fns.len);
            out.push('\n');
            let limit = min(dead_fns.len, 40);
            for i in limit {
                out.append("  ");
                out.append(crap::pool_slice(pool, dead_fns[i].file_off, dead_fns[i].file_len));
                out.push(':');
                crap::append_i64(out, dead_fns[i].line);
                out.append(" fn ");
                out.append(crap::pool_slice(pool, dead_fns[i].name_off, dead_fns[i].name_len));
                out.push('\n');
            }
        }
    }
}

fn format_sloc_report_md(
    cfg:      const SlocCliArgs&,
    pool:     const u8[:],
    files:    const FileSlocStats[:],
    dirs:     const DirSlocStats[:],
    dead_fns: const DeadFnCandidate[:],
    scopes:   const CycleSlocRow[:],
    gate_res: const SlocGateResult&,
    out:      u8[>..]&,
) {
    let _ = cfg.show_smells;
    let _ = dirs.len;
    let _ = dead_fns.len;
    var t_sloc:   i64 = 0;
    var t_stmts:  i64 = 0;
    var t_tokens: i64 = 0;
    var t_comm:   i64 = 0;
    var t_smells: i64 = 0;
    sum_file_totals(files, t_sloc, t_stmts, t_tokens, t_comm, t_smells);

    out.append("## goose-lit sloc report\n\n");
    out.append("- Verdict: `");
    out.append(sloc_verdict_name(gate_res.verdict));
    out.append("` | Files: ");
    crap::append_i64(out, files.len);
    out.append(" | SLOC: ");
    crap::append_i64(out, t_sloc);
    out.append(" | Stmts: ");
    crap::append_i64(out, t_stmts);
    out.append(" | Smells: ");
    crap::append_i64(out, t_smells);
    out.append("\n");

    if gate_res.audit.has_baseline {
        out.append("- Self-Audit Delta: SLOC `");
        append_signed_i64(out, gate_res.audit.delta_sloc);
        out.append("`, Stmts `");
        append_signed_i64(out, gate_res.audit.delta_stmts);
        out.append("`, Comments `");
        append_signed_i64(out, gate_res.audit.delta_comments);
        out.append("`, Smells `");
        append_signed_i64(out, gate_res.audit.delta_smells);
        out.append("`\n");
    }

    if scopes.len > 0 {
        out.append("\n| Scope | Kind | SLOC | Cycles | Cyc/SLOC | CL | Radar | Verdict |\n");
        out.append("| :--- | :--- | ---: | ---: | ---: | ---: | :--- | :--- |\n");
        for &s in scopes {
            out.append("| `");
            out.append(crap::pool_slice(pool, s.name_off, s.name_len));
            out.append("` | ");
            out.append(if s.kind == SLOC_SCOPE_STAGE { "stage" } else { "bench" });
            out.append(" | ");
            crap::append_i64(out, s.sloc);
            out.append(" | ");
            append_fixed_x10(out, s.cycles_x10);
            out.append(" | ");
            append_fixed_x100(out, s.cyc_per_sloc_x100);
            out.append(" | ");
            append_fixed_x10(out, s.cl_x10);
            out.append(" | ");
            out.append(sloc_radar_name(s.radar));
            out.append(" | ");
            out.append(sloc_verdict_name(s.verdict));
            out.append(" |\n");
        }
    }
}

fn format_sloc_report_json(
    cfg:      const SlocCliArgs&,
    pool:     const u8[:],
    files:    const FileSlocStats[:],
    dirs:     const DirSlocStats[:],
    dead_fns: const DeadFnCandidate[:],
    scopes:   const CycleSlocRow[:],
    gate_res: const SlocGateResult&,
    out:      u8[>..]&,
) {
    let _ = cfg.show_smells;
    let _ = dirs.len;
    var t_sloc:   i64 = 0;
    var t_stmts:  i64 = 0;
    var t_tokens: i64 = 0;
    var t_comm:   i64 = 0;
    var t_smells: i64 = 0;
    sum_file_totals(files, t_sloc, t_stmts, t_tokens, t_comm, t_smells);

    out.append("{\n  \"verdict\": \"");
    out.append(sloc_verdict_name(gate_res.verdict));
    out.append("\",\n  \"exit_code\": ");
    crap::append_i64(out, gate_res.exit_code);
    out.append(",\n  \"totals\": {\"files\": ");
    crap::append_i64(out, files.len);
    out.append(", \"sloc\": ");
    crap::append_i64(out, t_sloc);
    out.append(", \"stmts\": ");
    crap::append_i64(out, t_stmts);
    out.append(", \"tokens\": ");
    crap::append_i64(out, t_tokens);
    out.append(", \"comments\": ");
    crap::append_i64(out, t_comm);
    out.append(", \"smells\": ");
    crap::append_i64(out, t_smells);
    out.append(", \"dead_fn_candidates\": ");
    crap::append_i64(out, dead_fns.len);
    out.append("},\n  \"self_audit\": {\"delta_sloc\": ");
    crap::append_i64(out, gate_res.audit.delta_sloc);
    out.append(", \"delta_stmts\": ");
    crap::append_i64(out, gate_res.audit.delta_stmts);
    out.append(", \"delta_tokens\": ");
    crap::append_i64(out, gate_res.audit.delta_tokens);
    out.append(", \"delta_comments\": ");
    crap::append_i64(out, gate_res.audit.delta_comments);
    out.append(", \"delta_smells\": ");
    crap::append_i64(out, gate_res.audit.delta_smells);
    out.append(", \"delta_bce_kept\": ");
    crap::append_i64(out, gate_res.audit.delta_bce_kept);
    out.append(", \"packing_violations\": ");
    crap::append_i64(out, gate_res.audit.packing_violations);
    out.append("},\n  \"scopes\": [");

    for i in scopes.len {
        if i > 0 { out.append(", "); }
        let s = scopes[i];
        out.append("{\"name\": \"");
        crap::append_json_escaped(out, crap::pool_slice(pool, s.name_off, s.name_len));
        out.append("\", \"kind\": \"");
        out.append(if s.kind == SLOC_SCOPE_STAGE { "stage" } else { "bench" });
        out.append("\", \"sloc\": ");
        crap::append_i64(out, s.sloc);
        out.append(", \"cycles\": ");
        append_fixed_x10(out, s.cycles_x10);
        out.append(", \"cyc_per_sloc\": ");
        append_fixed_x100(out, s.cyc_per_sloc_x100);
        out.append(", \"cl\": ");
        append_fixed_x10(out, s.cl_x10);
        out.append(", \"radar\": \"");
        out.append(sloc_radar_name(s.radar));
        out.append("\", \"verdict\": \"");
        out.append(sloc_verdict_name(s.verdict));
        out.append("\"}");
    }
    out.append("]\n}\n");
}

fn format_sloc_report_tsv(
    cfg:      const SlocCliArgs&,
    pool:     const u8[:],
    files:    const FileSlocStats[:],
    dirs:     const DirSlocStats[:],
    dead_fns: const DeadFnCandidate[:],
    scopes:   const CycleSlocRow[:],
    gate_res: const SlocGateResult&,
    out:      u8[>..]&,
) {
    let _ = cfg.show_smells;
    let _ = dirs.len;
    let _ = dead_fns.len;
    var t_sloc:   i64 = 0;
    var t_stmts:  i64 = 0;
    var t_tokens: i64 = 0;
    var t_comm:   i64 = 0;
    var t_smells: i64 = 0;
    sum_file_totals(files, t_sloc, t_stmts, t_tokens, t_comm, t_smells);

    out.append("TOTAL\t");
    crap::append_i64(out, files.len);
    out.push('\t');
    crap::append_i64(out, t_sloc);
    out.push('\t');
    crap::append_i64(out, t_stmts);
    out.push('\t');
    crap::append_i64(out, t_comm);
    out.push('\t');
    crap::append_i64(out, t_smells);
    out.push('\t');
    out.append(sloc_verdict_name(gate_res.verdict));
    out.push('\n');

    for &s in scopes {
        out.append("SCOPE\t");
        out.append(crap::pool_slice(pool, s.name_off, s.name_len));
        out.push('\t');
        out.append(if s.kind == SLOC_SCOPE_STAGE { "stage" } else { "bench" });
        out.push('\t');
        crap::append_i64(out, s.sloc);
        out.push('\t');
        append_fixed_x10(out, s.cycles_x10);
        out.push('\t');
        append_fixed_x100(out, s.cyc_per_sloc_x100);
        out.push('\t');
        append_fixed_x10(out, s.cl_x10);
        out.push('\t');
        out.append(sloc_radar_name(s.radar));
        out.push('\t');
        out.append(sloc_verdict_name(s.verdict));
        out.push('\n');
    }
}
