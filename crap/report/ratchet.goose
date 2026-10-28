// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// CI Ratchet delta gate and baseline comparator for goose-crap.
// Blocks PRs ONLY when new unproven `bce:keep` panics or increased G-CRAP regressions appear.
namespace crap;

import std;
import os;
import core.bytes;
import crap.ast.model;

struct BaselineEntry {
    name_buf: u8[..128] = [],
    g_crap: f64 = 0.0,
    uncovered_bce_keep: i32 = 0,
    cov_branch: f64 = 0.0,
}

// Saves current scan as a baseline snapshot.
fn save_baseline_file(
    baseline_path: const u8[:],
    pool: const u8[:],
    functions: const FunctionInfo[:],
) -> bool {
    var out: u8[>..] = [];
    out.append("# goose-crap baseline v1\n");

    for fi in functions.len {
        let fn_info = functions[fi];
        let name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);

        out.append(name);
        out.push(' ');
        append_f64_2(out, fn_info.g_crap);
        out.push(' ');
        append_i64(out, fn_info.uncovered_bce_keep);
        out.push(' ');
        append_f64_2(out, fn_info.cov_branch);
        out.push('\n');
    }
    return write_file(baseline_path, out);
}

// Evaluates ratchet gate against previous baseline.
// Returns (violations_count, report_text).
fn check_ratchet_gate(
    baseline_path: const u8[:],
    pool: const u8[:],
    functions: const FunctionInfo[:],
    delta_threshold: f64,
    out: u8[>..]&,
) -> i32 {
    var content: u8[>..] = [];
    guard read_file(baseline_path, content) else {
        out.append("Warning: Could not open baseline file: ");
        out.append(baseline_path);
        out.append("\n");
        return 0;
    }

    var entries: BaselineEntry[>..] = [];
    var line_start: i64 = 0;
    let n = content.len;

    while line_start < n {
        var line_end = n;
        for i in line_start..n {
            if content[i] == '\n' {
                line_end = i;
                break;
            }
        }
        let raw = trim_ascii(content[line_start..line_end]);
        line_start = line_end + 1;

        if raw.len == 0 || raw[0] == '#' { continue; }

        let sp1 = slice_index_of_byte(raw, ' ');
        if sp1 > 0 && sp1 < raw.len {
            let name_part = raw[..sp1];
            let rest1 = trim_ascii(raw[sp1 + 1..]);
            let sp2 = slice_index_of_byte(rest1, ' ');
            if sp2 > 0 && sp2 < rest1.len {
                let gcrap_part = rest1[..sp2];
                let rest2 = trim_ascii(rest1[sp2 + 1..]);
                let sp3 = slice_index_of_byte(rest2, ' ');
                let bce_part = if sp3 > 0 && sp3 <= rest2.len { rest2[..sp3] } else { rest2 };

                let gcrap_val, ok_g = parse_f64_slice(gcrap_part);
                let bce_val, ok_b = parse_i64_slice(bce_part);
                var cov_val: f64 = 0.0;
                if sp3 > 0 && sp3 + 1 <= rest2.len {
                    let rest3 = trim_ascii(rest2[sp3 + 1..]);
                    let cv, ok_c = parse_f64_slice(rest3);
                    if ok_c { cov_val = cv; }
                }
                var entry = BaselineEntry {
                    name_buf: [],
                    g_crap: if ok_g { gcrap_val } else { 0.0 },
                    uncovered_bce_keep: if ok_b { bce_val as i32 } else { 0 },
                    cov_branch: cov_val,
                };
                entry.name_buf.append(name_part);
                entries.push(entry);
            }
        }
    }

    var violations: i32 = 0;
    out.append("=== goose-crap CI Ratchet Gate Evaluation ===\n");

    for fi in functions.len {
        let fn_info = functions[fi];
        let cur_name = pool_slice(pool, fn_info.qual_off, fn_info.qual_len);

        var found = false;
        var prev_bce: i32 = 0;
        var prev_gcrap: f64 = 0.0;

        for ei in entries.len {
            if entries[ei].name_buf == cur_name {
                found = true;
                prev_bce = entries[ei].uncovered_bce_keep;
                prev_gcrap = entries[ei].g_crap;
                break;
            }
        }

        if !found {
            // New function introduced: check if it introduces uncovered bce:keep
            if fn_info.uncovered_bce_keep > 0 {
                violations++;
                out.append("[VIOLATION] New function `");
                out.append(cur_name);
                out.append("` introduces ");
                append_i64(out, fn_info.uncovered_bce_keep);
                out.append(" unproven bce:keep bounds checks without branch coverage!\n");
            }
        } else {
            // Existing function modified: check for regressions
            if fn_info.uncovered_bce_keep > prev_bce {
                violations++;
                out.append("[VIOLATION] Function `");
                out.append(cur_name);
                out.append("` degraded: uncovered bce:keep increased from ");
                append_i64(out, prev_bce);
                out.append(" to ");
                append_i64(out, fn_info.uncovered_bce_keep);
                out.append("!\n");
            } else if fn_info.g_crap > prev_gcrap + delta_threshold && fn_info.cov_branch < 0.99 {
                violations++;
                out.append("[VIOLATION] Function `");
                out.append(cur_name);
                out.append("` G-CRAP score regressed from ");
                append_f64_1(out, prev_gcrap);
                out.append(" to ");
                append_f64_1(out, fn_info.g_crap);
                out.append("!\n");
            }
        }
    }

    if violations == 0 {
        out.append("[OK] Ratchet gate passed cleanly: zero regressions in unproven bce:keep or G-CRAP.\n");
    } else {
        out.append("[FAILED] Ratchet gate detected ");
        append_i64(out, violations);
        out.append(" safety regression(s).\n");
    }

    return violations;
}
