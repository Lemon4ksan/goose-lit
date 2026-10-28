// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// check/filecheck.goose - Zero-allocation LLVM-style FileCheck verification engine.
// Implements CHECK, CHECK-NEXT, CHECK-NOT, CHECK-LABEL, CHECK-SAME, CHECK-EMPTY,
// CHECK-DAG, CHECK-COUNT, regex wildcards {{...}}, and variable capture [[VAR:regex]] / [[VAR]].
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
    Dag,
    Count,
}

struct CheckRule {
    kind: CheckKind = CheckKind.Check,
    line_no: i64 = 0,
    count: i64 = 1,
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
        Dag => "CHECK-DAG",
        Count => "CHECK-COUNT",
    };
}

struct FileCheckVar {
    name: u8[..64] = [],
    val: u8[..256] = [],
}

struct FileCheckContext {
    vars: FileCheckVar[..64] = [],
}

fn set_var(ctx: FileCheckContext&, name: const u8[:], val: const u8[:]) {
    for i in ctx.vars.len {
        if ctx.vars[i].name[..] == name {
            ctx.vars[i].val.clear();
            for b in val {
                if ctx.vars[i].val.len < ctx.vars[i].val.cap {
                    ctx.vars[i].val.push(b);
                }
            }
            return;
        }
    }
    if ctx.vars.len < ctx.vars.cap {
        var v = FileCheckVar { .. };
        for b in name { if v.name.len < v.name.cap { v.name.push(b); } }
        for b in val { if v.val.len < v.val.cap { v.val.push(b); } }
        ctx.vars.push(v);
    }
}

fn get_var(ctx: const FileCheckContext&, name: const u8[:]) -> const u8[:], bool {
    for i in ctx.vars.len {
        if ctx.vars[i].name[..] == name {
            return ctx.vars[i].val[..], true;
        }
    }
    return "", false;
}

fn match_spec_char(spec: const u8[:], c: u8) -> bool {
    if spec == ".*" || spec == ".+" || spec == "*" {
        return true;
    }
    if spec == "[0-9]+" || spec == "\\d+" || spec == "[0-9]" || spec == "\\d" {
        return c >= '0' && c <= '9';
    }
    if spec == "[0-9a-fA-F]+" || spec == "[0-9a-f]+" || spec == "[0-9A-F]+" || spec == "\\x+" {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
    if spec == "[a-zA-Z0-9_-]+" || spec == "[a-zA-Z0-9_]+" || spec == "\\w+" {
        return crap::is_ident_cont(c) || c == '-';
    }
    if spec == "[a-zA-Z]+" {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }
    if spec == "[ \\t]+" || spec == "\\s+" {
        return c == ' ' || c == '\t';
    }
    if spec.len >= 2 && spec[0] == '[' && spec[spec.len - 1] == ']' {
        let inside = spec[1..spec.len - 1];
        for b in inside {
            if b == c { return true; }
        }
        return false;
    }
    return true;
}

enum SegKind {
    Lit,
    Wildcard,
    VarDef,
    VarUse,
}

struct PatternSeg {
    kind: SegKind = SegKind.Lit,
    text: u8[..128] = [],
    spec: u8[..64] = [],
}

fn parse_pattern_segs(pat: const u8[:], out_segs: PatternSeg[..32]&) -> bool {
    out_segs.clear();
    var cur: i64 = 0;
    let n = pat.len;

    while cur < n {
        let rem = pat[cur..];
        let next_w = crap::slice_index_of(rem, "{{");
        let next_v = crap::slice_index_of(rem, "[[");

        var next_tok: i64 = -1;
        var tok_type: i64 = 0;

        if next_w >= 0 && next_v >= 0 {
            if next_w < next_v { next_tok = next_w; tok_type = 1; }
            else { next_tok = next_v; tok_type = 2; }
        } else if next_w >= 0 {
            next_tok = next_w; tok_type = 1;
        } else if next_v >= 0 {
            next_tok = next_v; tok_type = 2;
        }

        if next_tok < 0 {
            var seg = PatternSeg { kind: SegKind.Lit, .. };
            for b in rem {
                if seg.text.len < seg.text.cap { seg.text.push(b); }
            }
            if seg.text.len > 0 && out_segs.len < out_segs.cap {
                out_segs.push(seg);
            }
            break;
        }

        if next_tok > 0 {
            var lit_seg = PatternSeg { kind: SegKind.Lit, .. };
            for b in rem[..next_tok] {
                if lit_seg.text.len < lit_seg.text.cap { lit_seg.text.push(b); }
            }
            if out_segs.len < out_segs.cap {
                out_segs.push(lit_seg);
            }
            cur += next_tok;
        }

        if tok_type == 1 {
            let after_open = pat[cur + 2..];
            let close_pos = crap::slice_index_of(after_open, "}}");
            guard close_pos >= 0 else { return false; }
            let spec_str = after_open[..close_pos];
            var seg = PatternSeg { kind: SegKind.Wildcard, .. };
            for b in spec_str {
                if seg.spec.len < seg.spec.cap { seg.spec.push(b); }
            }
            if out_segs.len < out_segs.cap {
                out_segs.push(seg);
            }
            cur += 2 + close_pos + 2;
        } else {
            let after_open = pat[cur + 2..];
            let close_pos = crap::slice_index_of(after_open, "]]");
            guard close_pos >= 0 else { return false; }
            let body = after_open[..close_pos];
            let colon_pos = crap::slice_index_of_byte(body, ':');
            if colon_pos >= 0 {
                let name = body[..colon_pos];
                let spec = body[colon_pos + 1..];
                var seg = PatternSeg { kind: SegKind.VarDef, .. };
                for b in name { if seg.text.len < seg.text.cap { seg.text.push(b); } }
                for b in spec { if seg.spec.len < seg.spec.cap { seg.spec.push(b); } }
                if out_segs.len < out_segs.cap { out_segs.push(seg); }
            } else {
                var seg = PatternSeg { kind: SegKind.VarUse, .. };
                for b in body { if seg.text.len < seg.text.cap { seg.text.push(b); } }
                if out_segs.len < out_segs.cap { out_segs.push(seg); }
            }
            cur += 2 + close_pos + 2;
        }
    }
    return true;
}

fn match_pattern_in_line(line: const u8[:], pat: const u8[:], ctx: FileCheckContext&) -> bool {
    if !crap::slice_contains(pat, "{{") && !crap::slice_contains(pat, "[[") {
        return crap::slice_contains(line, pat);
    }

    var segs: PatternSeg[..32] = [];
    if !parse_pattern_segs(pat, segs) || segs.len == 0 {
        return false;
    }

    var start_col: i64 = 0;
    while start_col <= line.len {
        var pos = start_col;
        var s_idx: i64 = 0;
        var match_ok = true;
        var local_vars: FileCheckVar[..16] = [];

        while s_idx < segs.len {
            let seg = segs[s_idx];
            if seg.kind == SegKind.Lit {
                let lit_str = seg.text[..];
                if !crap::slice_starts_with(line[pos..], lit_str) {
                    match_ok = false;
                    break;
                }
                pos += lit_str.len;
            } else if seg.kind == SegKind.VarUse {
                let name = seg.text[..];
                var matched_use = false;
                for i in local_vars.len {
                    if local_vars[i].name[..] == name {
                        let val = local_vars[i].val[..];
                        if crap::slice_starts_with(line[pos..], val) {
                            pos += val.len;
                            matched_use = true;
                        }
                        break;
                    }
                }
                if !matched_use {
                    let v, ok = get_var(ctx, name);
                    if ok && crap::slice_starts_with(line[pos..], v) {
                        pos += v.len;
                        matched_use = true;
                    }
                }
                if !matched_use {
                    match_ok = false;
                    break;
                }
            } else {
                let is_card_any = (seg.spec[..] == ".*" || seg.spec[..] == ".+" || seg.spec[..] == "*");
                let is_at_least_one = (seg.spec[..] != ".*" && seg.spec[..] != "*");
                let capture_start = pos;

                if s_idx + 1 < segs.len && segs[s_idx + 1].kind == SegKind.Lit {
                    let next_lit = segs[s_idx + 1].text[..];
                    var found_anchor = false;
                    var search_p = if is_at_least_one { pos + 1 } else { pos };
                    while search_p <= line.len {
                        if crap::slice_starts_with(line[search_p..], next_lit) {
                            var all_match = true;
                            if !is_card_any {
                                for c in line[pos..search_p] {
                                    if !match_spec_char(seg.spec[..], c) {
                                        all_match = false;
                                        break;
                                    }
                                }
                            }
                            if all_match {
                                if !is_at_least_one || search_p > pos {
                                    pos = search_p;
                                    found_anchor = true;
                                    break;
                                }
                            }
                        }
                        search_p += 1;
                    }
                    if !found_anchor {
                        match_ok = false;
                        break;
                    }
                } else {
                    var count: i64 = 0;
                    while pos < line.len && match_spec_char(seg.spec[..], line[pos]) {
                        pos += 1;
                        count += 1;
                    }
                    if is_at_least_one && count == 0 {
                        match_ok = false;
                        break;
                    }
                }

                if seg.kind == SegKind.VarDef {
                    let captured = line[capture_start..pos];
                    var lv = FileCheckVar { .. };
                    for b in seg.text[..] { if lv.name.len < lv.name.cap { lv.name.push(b); } }
                    for b in captured { if lv.val.len < lv.val.cap { lv.val.push(b); } }
                    local_vars.push(lv);
                }
            }
            s_idx += 1;
        }

        if match_ok {
            for lv in local_vars {
                set_var(ctx, lv.name[..], lv.val[..]);
            }
            return true;
        }

        start_col += 1;
    }

    return false;
}

// Parses FileCheck directives from source comments matching the specified prefix.
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
                var count_val: i64 = 1;

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
                } else if crap::slice_starts_with(after_prefix, "-DAG:") {
                    k = CheckKind.Dag;
                    pat_start = 5;
                } else if crap::slice_starts_with(after_prefix, "-COUNT-") {
                    let num_part = after_prefix[7..];
                    let colon_i = crap::slice_index_of_byte(num_part, ':');
                    if colon_i > 0 {
                        let c_num, ok = crap::parse_i64_slice(num_part[..colon_i]);
                        if ok && c_num > 0 {
                            k = CheckKind.Count;
                            count_val = c_num;
                            pat_start = 7 + colon_i + 1;
                        }
                    }
                }

                if pat_start >= 0 {
                    var pat = crap::trim_ascii(after_prefix[pat_start..]);
                    var rule = CheckRule {
                        kind: k,
                        line_no: line_num,
                        count: count_val,
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
        cur += 1;
    }

    var in_idx: i64 = 0;
    var last_matched_line: i64 = -1;
    var ctx = FileCheckContext { .. };

    var r_idx: i64 = 0;
    while r_idx < rules.len {
        let rule = rules[r_idx];
        let pat: const u8[:] = rule.pattern[..];

        if rule.kind == CheckKind.Label {
            var found_idx: i64 = -1;
            var i = in_idx;
            while i < in_lines_start.len {
                let l_str = output_stream[in_lines_start[i]..in_lines_end[i]];
                if match_pattern_in_line(l_str, pat, ctx) {
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
            var found_idx: i64 = -1;
            var i = in_idx;
            while i < in_lines_start.len {
                let l_str = output_stream[in_lines_start[i]..in_lines_end[i]];
                if match_pattern_in_line(l_str, pat, ctx) {
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
            if !match_pattern_in_line(l_str, pat, ctx) {
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
            if last_matched_line < 0 || last_matched_line >= in_lines_start.len {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-SAME] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": no previous line to match against\n");
                return false;
            }

            let l_str = output_stream[in_lines_start[last_matched_line]..in_lines_end[last_matched_line]];
            if !match_pattern_in_line(l_str, pat, ctx) {
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
            var bound_line = in_lines_start.len;
            var next_r = r_idx + 1;
            while next_r < rules.len {
                if rules[next_r].kind == CheckKind.Check || rules[next_r].kind == CheckKind.Label {
                    let next_pat: const u8[:] = rules[next_r].pattern[..];
                    var s_i = in_idx;
                    while s_i < in_lines_start.len {
                        let l_str = output_stream[in_lines_start[s_i]..in_lines_end[s_i]];
                        if match_pattern_in_line(l_str, next_pat, ctx) {
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
                if match_pattern_in_line(l_str, pat, ctx) {
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
        } else if rule.kind == CheckKind.Dag {
            var dag_end = r_idx;
            while dag_end < rules.len && rules[dag_end].kind == CheckKind.Dag {
                dag_end += 1;
            }

            var bound_line = in_lines_start.len;
            var next_r = dag_end;
            while next_r < rules.len {
                if rules[next_r].kind == CheckKind.Check || rules[next_r].kind == CheckKind.Label {
                    let next_pat: const u8[:] = rules[next_r].pattern[..];
                    var s_i = in_idx;
                    while s_i < in_lines_start.len {
                        let l_str = output_stream[in_lines_start[s_i]..in_lines_end[s_i]];
                        if match_pattern_in_line(l_str, next_pat, ctx) {
                            bound_line = s_i;
                            break;
                        }
                        s_i += 1;
                    }
                    break;
                }
                next_r += 1;
            }

            var claimed: i64[>..] = [];
            var max_matched_line = in_idx - 1;

            var d_i = r_idx;
            while d_i < dag_end {
                let d_rule = rules[d_i];
                let d_pat: const u8[:] = d_rule.pattern[..];
                var found_dag_line: i64 = -1;

                var l_i = in_idx;
                while l_i < bound_line {
                    var already_claimed = false;
                    for c_line in claimed {
                        if c_line == l_i { already_claimed = true; break; }
                    }
                    if !already_claimed {
                        let l_str = output_stream[in_lines_start[l_i]..in_lines_end[l_i]];
                        if match_pattern_in_line(l_str, d_pat, ctx) {
                            found_dag_line = l_i;
                            claimed.push(l_i);
                            if l_i > max_matched_line {
                                max_matched_line = l_i;
                            }
                            break;
                        }
                    }
                    l_i += 1;
                }

                if found_dag_line < 0 {
                    out_diag.append("FileCheck [");
                    out_diag.append(pref);
                    out_diag.append("-DAG] FAILED on line ");
                    format(out_diag, d_rule.line_no);
                    out_diag.append(": pattern '");
                    out_diag.append(d_pat);
                    out_diag.append("' not found in DAG block\n");
                    return false;
                }

                d_i += 1;
            }

            last_matched_line = max_matched_line;
            in_idx = max_matched_line + 1;
            r_idx = dag_end;
            continue;
        } else if rule.kind == CheckKind.Count {
            let count_needed = rule.count;
            var found_count: i64 = 0;
            var cur_i = in_idx;
            while cur_i < in_lines_start.len && found_count < count_needed {
                let l_str = output_stream[in_lines_start[cur_i]..in_lines_end[cur_i]];
                if match_pattern_in_line(l_str, pat, ctx) {
                    found_count += 1;
                    last_matched_line = cur_i;
                }
                cur_i += 1;
            }

            if found_count < count_needed {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-COUNT] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": expected ");
                format(out_diag, count_needed);
                out_diag.append(" matches for '");
                out_diag.append(pat);
                out_diag.append("', found ");
                format(out_diag, found_count);
                out_diag.append("\n");
                return false;
            }

            in_idx = last_matched_line + 1;
        }

        r_idx += 1;
    }

    return true;
}
