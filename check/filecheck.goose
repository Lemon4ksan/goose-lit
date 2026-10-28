// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// check/filecheck.goose - Zero-allocation LLVM-style FileCheck verification engine.
// Implements CHECK, CHECK-NEXT, CHECK-NOT, CHECK-LABEL, CHECK-SAME, and CHECK-EMPTY.
namespace lit;

import std;
import core.bytes;

enum CheckKind {
    Check,
    Next,
    Not,
    Label,
    Same,
    Empty,
}

struct CheckRule {
    kind: CheckKind = CheckKind.Check,
    line_no: i64 = 0,
    pattern: u8[..512] = [],
}

fn check_kind_name(k: CheckKind) -> const u8[:] {
    return match k {
        Check => "CHECK",
        Next => "CHECK-NEXT",
        Not => "CHECK-NOT",
        Label => "CHECK-LABEL",
        Same => "CHECK-SAME",
        Empty => "CHECK-EMPTY",
    };
}

// Parses FileCheck directives from source comments matching the specified prefix.
// Defaults to prefix "CHECK" (e.g., "// CHECK:", "// CHECK-NEXT:").
fn parse_check_directives(
    source: const u8[:],
    prefix: const u8[:],
    rules: CheckRule[>..]&,
) -> bool {
    var cursor: i64 = 0;
    var line_num: i64 = 1;
    let n = source.len;

    let p_len = prefix.len;

    while cursor < n {
        var next_nl = cursor;
        while next_nl < n && source[next_nl] != '\n' {
            next_nl += 1;
        }

        let line = crap::trim_ascii(source[cursor..next_nl]);
        cursor = next_nl + 1;

        if line.len >= 2 && line[0] == '/' && line[1] == '/' {
            let comment_body = crap::trim_ascii(line[2..]);
            if crap::slice_starts_with(comment_body, prefix) {
                let after_prefix = comment_body[p_len..];
                var k: CheckKind = CheckKind.Check;
                var pat_start: i64 = -1;

                if crap::slice_starts_with(after_prefix, ":") {
                    k = CheckKind.Check;
                    pat_start = 1;
                } else if crap::slice_starts_with(after_prefix, "-NEXT:") {
                    k = CheckKind.Next;
                    pat_start = 6;
                } else if crap::slice_starts_with(after_prefix, "-NOT:") {
                    k = CheckKind.Not;
                    pat_start = 5;
                } else if crap::slice_starts_with(after_prefix, "-LABEL:") {
                    k = CheckKind.Label;
                    pat_start = 7;
                } else if crap::slice_starts_with(after_prefix, "-SAME:") {
                    k = CheckKind.Same;
                    pat_start = 6;
                } else if crap::slice_starts_with(after_prefix, "-EMPTY:") || after_prefix == "-EMPTY" {
                    k = CheckKind.Empty;
                    pat_start = if crap::slice_starts_with(after_prefix, "-EMPTY:") { 7 } else { 6 };
                }

                if pat_start >= 0 {
                    var pat = crap::trim_ascii(after_prefix[pat_start..]);
                    var rule = CheckRule {
                        kind: k,
                        line_no: line_num,
                        pattern: [],
                    };
                    for b in pat {
                        if rule.pattern.len < rule.pattern.cap {
                            rule.pattern.push(b);
                        }
                    }
                    rules.push(rule);
                }
            }
        }

        line_num += 1;
    }

    return rules.len > 0;
}

// Executes FileCheck verification over output stream using parsed rules.
fn run_filecheck(
    output_stream: const u8[:],
    test_source: const u8[:],
    prefix: const u8[:],
    out_diag: u8[>..]&,
) -> bool {
    var rules: CheckRule[>..] = [];
    let pref = if prefix.len > 0 { prefix } else { "CHECK" };
    let has_rules = parse_check_directives(test_source, pref, rules);

    if !has_rules {
        out_diag.append("FileCheck error: no ");
        out_diag.append(pref);
        out_diag.append(": directives found in test file\n");
        return false;
    }

    // Split input stream into lines
    var in_lines_start: i64[>..] = [];
    var in_lines_end: i64[>..] = [];

    var cur: i64 = 0;
    let n = output_stream.len;
    while cur < n {
        let start = cur;
        while cur < n && output_stream[cur] != '\n' {
            cur += 1;
        }
        var end = cur;
        if end > start && output_stream[end - 1] == '\r' {
            end -= 1;
        }
        in_lines_start.push(start);
        in_lines_end.push(end);
        cur += 1; // skip \n
    }

    var in_idx: i64 = 0;
    var last_matched_line: i64 = -1;

    var r_idx: i64 = 0;
    while r_idx < rules.len {
        let rule = rules[r_idx];
        let pat: const u8[:] = rule.pattern[..];

        if rule.kind == CheckKind.Label {
            // CHECK-LABEL resets and searches forward
            var found_idx: i64 = -1;
            var i = in_idx;
            while i < in_lines_start.len {
                let l_str = output_stream[in_lines_start[i]..in_lines_end[i]];
                if crap::slice_contains(l_str, pat) {
                    found_idx = i;
                    break;
                }
                i += 1;
            }

            if found_idx < 0 {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-LABEL] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": expected label '");
                out_diag.append(pat);
                out_diag.append("' not found in stream\n");
                return false;
            }

            last_matched_line = found_idx;
            in_idx = found_idx + 1;
        } else if rule.kind == CheckKind.Check {
            // Find next matching line
            var found_idx: i64 = -1;
            var i = in_idx;
            while i < in_lines_start.len {
                let l_str = output_stream[in_lines_start[i]..in_lines_end[i]];
                if crap::slice_contains(l_str, pat) {
                    found_idx = i;
                    break;
                }
                i += 1;
            }

            if found_idx < 0 {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": pattern '");
                out_diag.append(pat);
                out_diag.append("' not found\n");
                return false;
            }

            last_matched_line = found_idx;
            in_idx = found_idx + 1;
        } else if rule.kind == CheckKind.Next {
            // CHECK-NEXT must match immediately on the very next input line
            let next_target = last_matched_line + 1;
            if next_target >= in_lines_start.len {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-NEXT] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": reached end of input, expected '");
                out_diag.append(pat);
                out_diag.append("'\n");
                return false;
            }

            let l_str = output_stream[in_lines_start[next_target]..in_lines_end[next_target]];
            if !crap::slice_contains(l_str, pat) {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-NEXT] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": next line does not match '");
                out_diag.append(pat);
                out_diag.append("'\n  Actual: '");
                out_diag.append(l_str);
                out_diag.append("'\n");
                return false;
            }

            last_matched_line = next_target;
            in_idx = next_target + 1;
        } else if rule.kind == CheckKind.Same {
            // CHECK-SAME must match on the SAME line as last match
            if last_matched_line < 0 || last_matched_line >= in_lines_start.len {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-SAME] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": no previous line to match against\n");
                return false;
            }

            let l_str = output_stream[in_lines_start[last_matched_line]..in_lines_end[last_matched_line]];
            if !crap::slice_contains(l_str, pat) {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-SAME] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": same line does not contain '");
                out_diag.append(pat);
                out_diag.append("'\n  Actual: '");
                out_diag.append(l_str);
                out_diag.append("'\n");
                return false;
            }
        } else if rule.kind == CheckKind.Empty {
            let next_target = last_matched_line + 1;
            if next_target >= in_lines_start.len {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-EMPTY] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": reached end of input, expected empty line\n");
                return false;
            }

            let l_str = output_stream[in_lines_start[next_target]..in_lines_end[next_target]];
            if crap::trim_ascii(l_str).len != 0 {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-EMPTY] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": expected empty line, got: '");
                out_diag.append(l_str);
                out_diag.append("'\n");
                return false;
            }

            last_matched_line = next_target;
            in_idx = next_target + 1;
        } else if rule.kind == CheckKind.Not {
            // CHECK-NOT: look ahead to find boundary (next CHECK or CHECK-LABEL or EOF)
            var bound_line = in_lines_start.len;
            var next_r = r_idx + 1;
            while next_r < rules.len {
                if rules[next_r].kind == CheckKind.Check || rules[next_r].kind == CheckKind.Label {
                    let next_pat: const u8[:] = rules[next_r].pattern[..];
                    var s_i = in_idx;
                    while s_i < in_lines_start.len {
                        let l_str = output_stream[in_lines_start[s_i]..in_lines_end[s_i]];
                        if crap::slice_contains(l_str, next_pat) {
                            bound_line = s_i;
                            break;
                        }
                        s_i += 1;
                    }
                    break;
                }
                next_r += 1;
            }

            var chk_i = in_idx;
            while chk_i < bound_line {
                let l_str = output_stream[in_lines_start[chk_i]..in_lines_end[chk_i]];
                if crap::slice_contains(l_str, pat) {
                    out_diag.append("FileCheck [");
                    out_diag.append(pref);
                    out_diag.append("-NOT] FAILED on line ");
                    format(out_diag, rule.line_no);
                    out_diag.append(": forbidden pattern '");
                    out_diag.append(pat);
                    out_diag.append("' appeared on input line ");
                    format(out_diag, chk_i + 1);
                    out_diag.append(":\n  '");
                    out_diag.append(l_str);
                    out_diag.append("'\n");
                    return false;
                }
                chk_i += 1;
            }
        }

        r_idx += 1;
    }

    return true;
}
