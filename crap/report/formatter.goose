// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Diagnostic terminal table, Markdown, and JSON report formatters for goose-crap.
namespace crap;

import std;
import sys.bytes;
import crap.ast.model;

// Sorts function indices descending by G-CRAP score.
fn sort_functions_by_gcrap(functions: const FunctionInfo[:], order: i32[>..]&) {
    order.clear();
    for fi in functions.len {
        order.push(fi as i32);
    }

    // Insertion sort (deterministic, fast for diagnostic report lists)
    var i: i64 = 1;
    while i < order.len {
        let key_idx = order[i];
        guard key_idx >= 0 && key_idx < functions.len else { i++; continue; }
        let key_score = functions[key_idx].g_crap;
        var j: i64 = i - 1;
        while j >= 0 {
            let cur_idx = order[j];
            guard cur_idx >= 0 && cur_idx < functions.len else { break; }
            if functions[cur_idx].g_crap >= key_score {
                break;
            }
            guard j + 1 < order.len else { break; }
            order[j + 1] = cur_idx;
            j--;
        }
        guard j + 1 >= 0 && j + 1 < order.len else { i++; continue; }
        order[j + 1] = key_idx;
        i++;
    }
}

// Formats terminal summary table and diagnostic triage queues.
fn render_terminal_report(
    pool:      const u8[:],
    functions: const FunctionInfo[:],
    branches:  const BranchSite[:],
    cfg:       const RiskConfig&,
    out:       u8[>..]&,
) {
    var order: i32[>..] = [];
    sort_functions_by_gcrap(functions, order);

    out.append("\n=== goose-crap risk radar (G-CRAP) ===\n\n");
    out.append("| Function                         |   CC |  Cog |   Cov% | bce:keep |     CRAP |   G-CRAP | Archetype          |\n");
    out.append("|----------------------------------|------|------|--------|----------|----------|----------|--------------------|\n");

    var false_positives:     i32 = 0;
    var panic_hazards:       i32 = 0;
    var total_bce_uncovered: i32 = 0;

    for oi in order.len {
        let fi: i64 = order[oi];
        let fn_info = functions[fi];
        if fn_info.ignored { continue; }

        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);

        if fn_info.classic_crap >= cfg.classic_threshold && fn_info.cov_branch >= 0.99 && fn_info.g_crap < 1.0 {
            false_positives++;
        }
        if fn_info.uncovered_bce_keep > 0 {
            panic_hazards++;
            total_bce_uncovered += fn_info.uncovered_bce_keep;
        }

        out.append("| ");
        // Truncate or pad function name to 32 chars
        if name.len > 32 {
            out.append(name[..32]);
        } else {
            append_padded_right(out, name, 32);
        }

        out.append(" | ");
        var cc_buf: u8[..8] = [];
        append_i64(cc_buf, fn_info.cyclomatic_cc);
        append_padded_left(out, cc_buf, 4);

        out.append(" | ");
        var cog_buf: u8[..8] = [];
        append_i64(cog_buf, fn_info.cognitive_cc);
        append_padded_left(out, cog_buf, 4);

        out.append(" | ");
        var cov_buf: u8[..12] = [];
        append_f64_1(cov_buf, fn_info.cov_branch * 100.0);
        cov_buf.push('%');
        append_padded_left(out, cov_buf, 6);

        out.append(" | ");
        var bce_buf: u8[..16] = [];
        append_i64(bce_buf, fn_info.uncovered_bce_keep);
        bce_buf.push('/');
        append_i64(bce_buf, fn_info.total_bce_keep);
        append_padded_left(out, bce_buf, 8);

        out.append(" | ");
        var crap_buf: u8[..16] = [];
        append_f64_1(crap_buf, fn_info.classic_crap);
        append_padded_left(out, crap_buf, 8);

        out.append(" | ");
        var gcrap_buf: u8[..16] = [];
        append_f64_1(gcrap_buf, fn_info.g_crap);
        append_padded_left(out, gcrap_buf, 8);

        out.append(" | ");
        append_padded_right(out, archetype_short(fn_info.archetype), 18);
        out.append(" |\n");
    }

    out.append("\nSummary:\n");
    out.append("  Total functions scanned: ");
    append_u64(out, functions.len as u64);
    out.append("\n  Total branch sites:      ");
    append_u64(out, branches.len as u64);
    out.append("\n  False alarms avoided:    ");
    append_i64(out, false_positives);
    out.append(" (Verified dispatch tables with classic CRAP > 30, G-CRAP = 0.0)\n");
    out.append("  Panic hazard functions:  ");
    append_i64(out, panic_hazards);
    out.append(" (holding ");
    append_i64(out, total_bce_uncovered);
    out.append(" unproven bce:keep in uncovered branches)\n");

    var uninst_generics: i32 = 0;
    var noinline_count:  i32 = 0;
    for oi in order.len {
        let fi: i64 = order[oi];
        if functions[fi].uninstantiated_generic { uninst_generics++; }
        if functions[fi].has_noinline { noinline_count++; }
    }
    if uninst_generics > 0 {
        out.append("  Uninstantiated generics: ");
        append_i64(out, uninst_generics);
        out.append(" (generic declarations never specialized in build)\n");
    }
    if noinline_count > 0 {
        out.append("  Noinline spec functions: ");
        append_i64(out, noinline_count);
        out.append(" (rejected by inliner or marked noinline)\n");
    }
    out.append("\n");
}

// Renders complete Markdown report suitable for CI artifacts or PR comments.
fn render_markdown_report(
    pool:      const u8[:],
    functions: const FunctionInfo[:],
    branches:  const BranchSite[:],
    cfg:       const RiskConfig&,
    out:       u8[>..]&,
) {
    var order: i32[>..] = [];
    sort_functions_by_gcrap(functions, order);

    out.append("# Goose CRAP & Safety Risk Report\n\n");
    out.append("| Function | Location | CC | Cog | Branch Cov | Uncov bce:keep | Classic CRAP | G-CRAP | Archetype |\n");
    out.append("|---|---|---|---|---|---|---|---|---|\n");

    for oi in order.len {
        let fi: i64 = order[oi];
        let fn_info = functions[fi];
        if fn_info.ignored { continue; }

        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);
        let file = pool_slice(pool, fn_info.file_off, fn_info.file_len);

        out.append("| `");
        out.append(name);
        out.append("` | `");
        var short_file: u8[>..] = [];
        short_display_path(file, short_file);
        out.append(short_file);
        out.push(':');
        append_i64(out, fn_info.start_line);
        out.append("` | ");
        append_i64(out, fn_info.cyclomatic_cc);
        out.append(" | ");
        append_i64(out, fn_info.cognitive_cc);
        out.append(" | ");
        append_f64_1(out, fn_info.cov_branch * 100.0);
        out.append("% | ");
        append_i64(out, fn_info.uncovered_bce_keep);
        out.append(" | ");
        append_f64_1(out, fn_info.classic_crap);
        out.append(" | **");
        append_f64_1(out, fn_info.g_crap);
        out.append("** | ");
        out.append(archetype_label(fn_info.archetype));
        if fn_info.uninstantiated_generic {
            out.append(" (uninstantiated generic)");
        } else if fn_info.has_noinline {
            out.append(" (noinline)");
        }
        out.append(" |\n");
    }

    out.append("\n## Uncovered Branch Hotspots (Targeting Fuzz Seeds & Audits)\n\n");
    for oi in order.len {
        let fi: i64 = order[oi];
        let fn_info = functions[fi];
        if fn_info.g_crap < 1.0 { continue; }

        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);
        let file = pool_slice(pool, fn_info.file_off, fn_info.file_len);

        out.append("### `");
        out.append(name);
        out.append("` (G-CRAP = ");
        append_f64_1(out, fn_info.g_crap);
        out.append(")\n");

        for bi in fn_info.branch_count {
            let idx: i64 = fn_info.first_branch + bi;
            if idx < branches.len && !branches[idx].covered {
                let b = branches[idx];
                out.append("- Line ");
                append_i64(out, b.start_line);
                out.append(": `");
                out.append(branch_kind_name(b.kind));
                out.append("` (depth=");
                append_i64(out, b.depth);
                if b.bce_keep > 0 {
                    out.append(", **bce:keep=");
                    append_i64(out, b.bce_keep);
                    out.append("**");
                }
                if b.ovf_ops > 0 {
                    out.append(", ovf_ops=");
                    append_i64(out, b.ovf_ops);
                }
                out.append(")\n");
            }
        }
        out.push('\n');
    }
}

// Renders JSON output for CI automation.
fn render_json_report(
    pool:      const u8[:],
    functions: const FunctionInfo[:],
    branches:  const BranchSite[:],
    out:       u8[>..]&,
) {
    out.append("{\n  \"functions\": [\n");

    for fi in functions.len {
        let fn_info = functions[fi];
        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);
        let file = pool_slice(pool, fn_info.file_off, fn_info.file_len);

        out.append("    {\n");
        out.append("      \"name\": \"");
        out.append(name);
        out.append("\",\n      \"file\": \"");
        var nfile: u8[>..] = [];
        normalize_path(file, nfile);
        out.append(nfile);
        out.append("\",\n      \"line\": ");
        append_i64(out, fn_info.start_line);
        out.append(",\n      \"cyclomatic_cc\": ");
        append_i64(out, fn_info.cyclomatic_cc);
        out.append(",\n      \"cognitive_cc\": ");
        append_i64(out, fn_info.cognitive_cc);
        out.append(",\n      \"effective_cc\": ");
        append_i64(out, fn_info.effective_cc);
        out.append(",\n      \"branch_coverage\": ");
        append_f64_2(out, fn_info.cov_branch);
        out.append(",\n      \"classic_crap\": ");
        append_f64_2(out, fn_info.classic_crap);
        out.append(",\n      \"risk_struct\": ");
        append_f64_2(out, fn_info.risk_struct);
        out.append(",\n      \"risk_safety\": ");
        append_f64_2(out, fn_info.risk_safety);
        out.append(",\n      \"g_crap\": ");
        append_f64_2(out, fn_info.g_crap);
        out.append(",\n      \"uncovered_bce_keep\": ");
        append_i64(out, fn_info.uncovered_bce_keep);
        out.append(",\n      \"total_bce_keep\": ");
        append_i64(out, fn_info.total_bce_keep);
        out.append(",\n      \"specs_count\": ");
        append_i64(out, fn_info.specs_count);
        out.append(",\n      \"max_spec_nodes\": ");
        append_i64(out, fn_info.max_spec_nodes);
        out.append(",\n      \"has_noinline\": ");
        out.append(if fn_info.has_noinline { "true" } else { "false" });
        out.append(",\n      \"uninstantiated_generic\": ");
        out.append(if fn_info.uninstantiated_generic { "true" } else { "false" });
        out.append(",\n      \"archetype\": \"");
        out.append(archetype_short(fn_info.archetype));
        out.append("\"\n    }");
        if fi + 1 < functions.len {
            out.push(',');
        }
        out.push('\n');
    }

    out.append("  ]\n}\n");
}

// Renders GCC-compatible diagnostic warnings (<file>:<line>:<col>: warning: [G-CRAP <score>] ...)
// for IDE integration (VS Code, Zed problem matchers).
fn render_gcc_diagnostics(
    pool:      const u8[:],
    functions: const FunctionInfo[:],
    branches:  const BranchSite[:],
    out:       u8[>..]&,
) {
    for fi in functions.len {
        let fn_info = functions[fi];
        if fn_info.ignored { continue; }

        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);
        let file = pool_slice(pool, fn_info.file_off, fn_info.file_len);

        var nfile: u8[>..] = [];
        normalize_path(file, nfile);

        for bi in fn_info.branch_count {
            let idx: i64 = fn_info.first_branch + bi;
            if idx < branches.len && !branches[idx].covered {
                let b = branches[idx];
                out.append(nfile);
                out.push(':');
                append_i64(out, b.start_line);
                out.append(":5: warning: [G-CRAP ");
                append_f64_1(out, fn_info.g_crap);
                out.append("] uncovered ");
                out.append(branch_class_name(b.classification));
                out.append(" (");
                out.append(branch_kind_name(b.kind));
                out.append(") in '");
                out.append(name);
                out.append("'");
                if b.bce_keep > 0 {
                    out.append(" holding ");
                    append_i64(out, b.bce_keep);
                    out.append(" unproven bce:keep checks");
                }
                if b.ovf_ops > 0 {
                    out.append(", ");
                    append_i64(out, b.ovf_ops);
                    out.append(" overflow hazards");
                }
                out.push('\n');
            }
        }
    }
}

// Renders valid SARIF 2.1.0 JSON format for GitHub Code Scanning and IDE SARIF viewers.
fn render_sarif_report(
    pool:      const u8[:],
    functions: const FunctionInfo[:],
    branches:  const BranchSite[:],
    out:       u8[>..]&,
) {
    out.append("{\n");
    out.append("  \"$schema\": \"https://json.schemastore.org/sarif-2.1.0.json\",\n");
    out.append("  \"version\": \"2.1.0\",\n");
    out.append("  \"runs\": [\n");
    out.append("    {\n");
    out.append("      \"tool\": {\n");
    out.append("        \"driver\": {\n");
    out.append("          \"name\": \"goose-crap\",\n");
    out.append("          \"version\": \"1.0.0\",\n");
    out.append("          \"informationUri\": \"https://github.com/Lemon4ksan/goose-crap\",\n");
    out.append("          \"rules\": [\n");
    out.append("            {\n");
    out.append("              \"id\": \"GCRAP001\",\n");
    out.append("              \"name\": \"PanicHazardBoundsCheck\",\n");
    out.append("              \"shortDescription\": { \"text\": \"Uncovered branch holding unproven bounds check (bce:keep)\" },\n");
    out.append("              \"defaultConfiguration\": { \"level\": \"error\" }\n");
    out.append("            },\n");
    out.append("            {\n");
    out.append("              \"id\": \"GCRAP002\",\n");
    out.append("              \"name\": \"UntrustedWireFuzzTarget\",\n");
    out.append("              \"shortDescription\": { \"text\": \"High-risk uncovered branch in untrusted wire protocol parser\" },\n");
    out.append("              \"defaultConfiguration\": { \"level\": \"warning\" }\n");
    out.append("            },\n");
    out.append("            {\n");
    out.append("              \"id\": \"GCRAP003\",\n");
    out.append("              \"name\": \"UncoveredBranchRisk\",\n");
    out.append("              \"shortDescription\": { \"text\": \"Uncovered control-flow branch in complex routine\" },\n");
    out.append("              \"defaultConfiguration\": { \"level\": \"note\" }\n");
    out.append("            }\n");
    out.append("          ]\n");
    out.append("        }\n");
    out.append("      },\n");
    out.append("      \"results\": [\n");

    var first_result = true;
    for fi in functions.len {
        let fn_info = functions[fi];
        if fn_info.ignored { continue; }

        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);
        let file = pool_slice(pool, fn_info.file_off, fn_info.file_len);
        var nfile: u8[>..] = [];
        normalize_path(file, nfile);

        for bi in fn_info.branch_count {
            let idx: i64 = fn_info.first_branch + bi;
            if idx < branches.len && !branches[idx].covered {
                let b = branches[idx];

                if !first_result {
                    out.append(",\n");
                }
                first_result = false;

                var rule_id = "GCRAP003";
                var level = "note";
                if b.bce_keep > 0 {
                    rule_id = "GCRAP001";
                    level = "error";
                } else if fn_info.trust_class == TRUST_UNTRUSTED {
                    rule_id = "GCRAP002";
                    level = "warning";
                }

                out.append("        {\n");
                out.append("          \"ruleId\": \"");
                out.append(rule_id);
                out.append("\",\n          \"level\": \"");
                out.append(level);
                out.append("\",\n          \"message\": {\n            \"text\": \"Uncovered ");
                out.append(branch_class_name(b.classification));
                out.append(" (");
                out.append(branch_kind_name(b.kind));
                out.append(") in '");
                out.append(name);
                out.append("' with G-CRAP score ");
                append_f64_1(out, fn_info.g_crap);
                if b.bce_keep > 0 {
                    out.append(" holding ");
                    append_i64(out, b.bce_keep);
                    out.append(" unproven bce:keep");
                }
                out.append("\"\n          },\n");
                out.append("          \"locations\": [\n            {\n              \"physicalLocation\": {\n");
                out.append("                \"artifactLocation\": { \"uri\": \"");
                out.append(nfile);
                out.append("\" },\n                \"region\": { \"startLine\": ");
                append_i64(out, b.start_line);
                out.append(", \"endLine\": ");
                append_i64(out, b.end_line);
                out.append(", \"startColumn\": 1 }\n              }\n            }\n          ]\n        }");
            }
        }
    }

    out.append("\n      ]\n    }\n  ]\n}\n");
}
