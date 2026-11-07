// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// check/filecheck.goose - Zero-allocation LLVM-style FileCheck verification engine.
// Implements CHECK, CHECK-NEXT, CHECK-NOT, CHECK-LABEL, CHECK-SAME, CHECK-EMPTY,
// CHECK-DAG, CHECK-COUNT, regex wildcards {{...}}, and variable capture [[VAR:regex]] / [[VAR]].
namespace lit;

import std;
import sys.bytes;

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
    kind:    CheckKind = CheckKind.Check,
    line_no: i64       = 0,
    count:   i64       = 1,
    pattern: u8[..512] = [],
}

struct FileCheckVar {
    name: u8[..64]  = [],
    val:  u8[..512] = [],
}

struct FileCheckContext {
    vars: FileCheckVar[..64] = [],
}

fn set_var(ctx: FileCheckContext&, name: const u8[:], val: const u8[:]) {
    for i in ctx.vars.len {
        if ctx.vars[i].name[..] == name {
            ctx.vars[i].val.clear();
            let vlen = min(val.len, ctx.vars[i].val.cap);
            ctx.vars[i].val.append(val[..vlen]);
            return;
        }
    }
    guard ctx.vars.len < ctx.vars.cap else { return; }
    var v = FileCheckVar { .. };
    let nlen = min(name.len, v.name.cap);
    v.name.append(name[..nlen]);
    let vlen = min(val.len, v.val.cap);
    v.val.append(val[..vlen]);
    ctx.vars.push(v);
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
    var clean_spec = spec;
    if clean_spec.len >= 3 && clean_spec[0] == '[' && (clean_spec[clean_spec.len - 1] == '+' || clean_spec[clean_spec.len - 1] == '*') {
        clean_spec = clean_spec[..clean_spec.len - 1];
    }
    if clean_spec.len >= 2 && clean_spec[0] == '[' && clean_spec[clean_spec.len - 1] == ']' {
        let inside = clean_spec[1..clean_spec.len - 1];
        var idx: i64 = 0;
        while idx < inside.len {
            if idx + 2 < inside.len && inside[idx + 1] == '-' {
                if c >= inside[idx] && c <= inside[idx + 2] {
                    return true;
                }
                idx += 3;
            } else {
                if inside[idx] == c {
                    return true;
                }
                idx += 1;
            }
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
    NumDef,
    NumExpr,
}

struct PatternSeg {
    kind:       SegKind   = SegKind.Lit,
    text:       u8[..512] = [],
    spec:       u8[..64]  = [],
    num_offset: i64       = 0,
}

inline fn push_seg(
    out_segs:   PatternSeg[..32]&,
    kind:       SegKind,
    text:       const u8[:],
    spec:       const u8[:],
    num_offset: i64 = 0,
) -> bool {
    guard out_segs.len < out_segs.cap else { return false; }
    var seg = PatternSeg { kind: kind, num_offset: num_offset, .. };
    guard text.len <= seg.text.cap && spec.len <= seg.spec.cap else { return false; }
    seg.text.append(text);
    seg.spec.append(spec);
    out_segs.push(seg);
    return true;
}

fn parse_bracket_seg(body: const u8[:], out_segs: PatternSeg[..32]&) -> bool {
    if body.len > 0 && body[0] == '#' {
        let num_body = crap::trim_ascii(body[1..]);
        let colon_pos = crap::slice_index_of_byte(num_body, ':');
        if colon_pos >= 0 {
            let name = crap::trim_ascii(num_body[..colon_pos]);
            var spec = crap::trim_ascii(num_body[colon_pos + 1..]);
            if spec.len == 0 { spec = "[0-9]+"; }
            return push_seg(out_segs, SegKind.NumDef, name, spec);
        }
        let plus_pos = crap::slice_index_of_byte(num_body, '+');
        let minus_pos = crap::slice_index_of_byte(num_body, '-');
        if plus_pos > 0 {
            let name = crap::trim_ascii(num_body[..plus_pos]);
            let off_val, ok = crap::parse_i64_slice(crap::trim_ascii(num_body[plus_pos + 1..]));
            guard ok else { return false; }
            return push_seg(out_segs, SegKind.NumExpr, name, "", off_val);
        }
        if minus_pos > 0 {
            let name = crap::trim_ascii(num_body[..minus_pos]);
            let off_val, ok = crap::parse_i64_slice(crap::trim_ascii(num_body[minus_pos + 1..]));
            guard ok && off_val != -9223372036854775808 else { return false; }
            return push_seg(out_segs, SegKind.NumExpr, name, "", -off_val);
        }
        if num_body.len == 0 {
            return push_seg(out_segs, SegKind.Wildcard, "", "[0-9]+");
        }
        return push_seg(out_segs, SegKind.NumExpr, num_body, "", 0);
    }
    let colon_pos = crap::slice_index_of_byte(body, ':');
    if colon_pos >= 0 {
        return push_seg(out_segs, SegKind.VarDef, body[..colon_pos], body[colon_pos + 1..]);
    }
    return push_seg(out_segs, SegKind.VarUse, body, "");
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
            if rem.len > 0 {
                guard push_seg(out_segs, SegKind.Lit, rem, "") else { return false; }
            }
            break;
        }

        if next_tok > 0 {
            guard push_seg(out_segs, SegKind.Lit, rem[..next_tok], "") else { return false; }
            cur += next_tok;
        }

        if tok_type == 1 {
            let after_open = pat[cur + 2..];
            let close_pos = crap::slice_index_of(after_open, "}}");
            guard close_pos >= 0 else { return false; }
            guard push_seg(out_segs, SegKind.Wildcard, "", after_open[..close_pos]) else { return false; }
            cur += 2 + close_pos + 2;
        } else {
            let after_open = pat[cur + 2..];
            let close_pos = crap::slice_index_of(after_open, "]]");
            guard close_pos >= 0 else { return false; }
            guard parse_bracket_seg(after_open[..close_pos], out_segs) else { return false; }
            cur += 2 + close_pos + 2;
        }
    }
    return true;
}

fn resolve_seg_literal(
    seg:        const PatternSeg&,
    local_vars: const FileCheckVar[:],
    ctx:        const FileCheckContext&,
    out_buf:    u8[..512]&,
) -> bool {
    out_buf.clear();
    if seg.kind == SegKind.Lit {
        guard seg.text.len <= out_buf.cap else { return false; }
        out_buf.append(seg.text[..]);
        return true;
    }
    if seg.kind == SegKind.VarUse {
        let name = seg.text[..];
        for i in local_vars.len {
            if local_vars[i].name[..] == name {
                guard local_vars[i].val.len <= out_buf.cap else { return false; }
                out_buf.append(local_vars[i].val[..]);
                return true;
            }
        }
        let v, ok = get_var(ctx, name);
        if ok && v.len <= out_buf.cap {
            out_buf.append(v);
            return true;
        }
        return false;
    }
    if seg.kind == SegKind.NumExpr {
        let name = seg.text[..];
        var val_buf: u8[..64] = [];
        var found_v = false;
        for i in local_vars.len {
            if local_vars[i].name[..] == name {
                for b in local_vars[i].val { if val_buf.len < val_buf.cap { val_buf.push(b); } }
                found_v = true;
                break;
            }
        }
        if !found_v {
            let v, ok = get_var(ctx, name);
            if ok {
                for b in v { if val_buf.len < val_buf.cap { val_buf.push(b); } }
                found_v = true;
            }
        }
        guard found_v else { return false; }
        let base_num, ok_b = crap::parse_i64_slice(val_buf[..]);
        guard ok_b else { return false; }
        format(out_buf, base_num + seg.num_offset);
        return true;
    }
    return false;
}

fn match_pattern_in_line(line: const u8[:], pat: const u8[:], ctx: FileCheckContext&, out_end_pos: i64& = 0) -> bool {
    out_end_pos = 0;
    if !crap::slice_contains(pat, "{{") && !crap::slice_contains(pat, "[[") {
        let idx = crap::slice_index_of(line, pat);
        if idx >= 0 {
            out_end_pos = idx + pat.len;
            return true;
        }
        return false;
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
            } else if seg.kind == SegKind.NumExpr {
                let name = seg.text[..];
                var val_buf: u8[..64] = [];
                var found_v = false;
                for i in local_vars.len {
                    if local_vars[i].name[..] == name {
                        for b in local_vars[i].val { if val_buf.len < val_buf.cap { val_buf.push(b); } }
                        found_v = true;
                        break;
                    }
                }
                if !found_v {
                    let v, ok = get_var(ctx, name);
                    if ok {
                        for b in v { if val_buf.len < val_buf.cap { val_buf.push(b); } }
                        found_v = true;
                    }
                }
                if !found_v {
                    match_ok = false;
                    break;
                }
                let base_num, ok_b = crap::parse_i64_slice(val_buf[..]);
                if !ok_b {
                    match_ok = false;
                    break;
                }
                let target_num = base_num + seg.num_offset;
                var num_buf: u8[..32] = [];
                format(num_buf, target_num);
                if !crap::slice_starts_with(line[pos..], num_buf[..]) {
                    match_ok = false;
                    break;
                }
                let end_num_pos = pos + num_buf.len;
                if end_num_pos < line.len && crap::is_ascii_digit(line[end_num_pos]) {
                    match_ok = false;
                    break;
                }
                pos = end_num_pos;
            } else {
                let is_card_any = (seg.spec[..] == ".*" || seg.spec[..] == ".+" || seg.spec[..] == "*");
                let is_at_least_one = (seg.spec[..] != ".*" && seg.spec[..] != "*");
                let capture_start = pos;

                var next_lit_buf: u8[..512] = [];
                let has_next_lit = if s_idx + 1 < segs.len {
                    resolve_seg_literal(segs[s_idx + 1], local_vars[..], ctx, next_lit_buf)
                } else {
                    false
                };

                if has_next_lit {
                    let next_lit = next_lit_buf[..];
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

                if seg.kind == SegKind.VarDef || seg.kind == SegKind.NumDef {
                    guard local_vars.len < local_vars.cap else {
                        match_ok = false;
                        break;
                    }
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
            out_end_pos = pos;
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
    rules:  CheckRule[>..]&,
) -> bool {
    var cursor:   i64 = 0;
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
                var k:         CheckKind = CheckKind.Check;
                var pat_start: i64       = -1;
                var count_val: i64       = 1;

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
                    let pat = crap::trim_ascii(after_prefix[pat_start..]);
                    var rule = CheckRule {
                        kind:    k,
                        line_no: line_num,
                        count:   count_val,
                        pattern: [],
                    };
                    let plen = min(pat.len, rule.pattern.cap);
                    rule.pattern.append(pat[..plen]);
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
    test_source:   const u8[:],
    prefix:        const u8[:],
    out_diag:      u8[>..]&,
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
    var in_lines_end:   i64[>..] = [];

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

    var in_idx:            i64 = 0;
    var last_matched_line: i64 = -1;
    var last_matched_col:  i64 = 0;
    var ctx = FileCheckContext { .. };
    var claimed: i64[>..] = [];

    var r_idx: i64 = 0;
    while r_idx < rules.len {
        let rule = rules[r_idx];
        let pat: const u8[:] = rule.pattern[..];

        // Calculate current section boundary (bounded by next CHECK-LABEL)
        var section_end_line = in_lines_start.len;
        var next_lbl = r_idx + 1;
        while next_lbl < rules.len {
            if rules[next_lbl].kind == CheckKind.Label {
                let lbl_pat: const u8[:] = rules[next_lbl].pattern[..];
                var s_i = in_idx;
                while s_i < in_lines_start.len {
                    let l_str = output_stream[in_lines_start[s_i]..in_lines_end[s_i]];
                    var dummy_col: i64 = 0;
                    if match_pattern_in_line(l_str, lbl_pat, ctx, dummy_col) {
                        section_end_line = s_i;
                        break;
                    }
                    s_i += 1;
                }
                break;
            }
            next_lbl += 1;
        }

        if rule.kind == CheckKind.Label {
            var found_idx: i64 = -1;
            var i = in_idx;
            var end_c: i64 = 0;
            while i < in_lines_start.len {
                let l_str = output_stream[in_lines_start[i]..in_lines_end[i]];
                if match_pattern_in_line(l_str, pat, ctx, end_c) {
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
            last_matched_col = end_c;
            in_idx = found_idx + 1;
        } else if rule.kind == CheckKind.Check {
            var found_idx: i64 = -1;
            var i = in_idx;
            var end_c: i64 = 0;
            while i < section_end_line {
                let l_str = output_stream[in_lines_start[i]..in_lines_end[i]];
                if match_pattern_in_line(l_str, pat, ctx, end_c) {
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
                out_diag.append("' not found within current section\n");
                return false;
            }

            last_matched_line = found_idx;
            last_matched_col = end_c;
            in_idx = found_idx + 1;
        } else if rule.kind == CheckKind.Next {
            let next_target = last_matched_line + 1;
            if next_target >= section_end_line || next_target >= in_lines_start.len {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-NEXT] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": reached end of section/input, expected '");
                out_diag.append(pat);
                out_diag.append("'\n");
                return false;
            }

            let l_str = output_stream[in_lines_start[next_target]..in_lines_end[next_target]];
            var end_c: i64 = 0;
            if !match_pattern_in_line(l_str, pat, ctx, end_c) {
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
            last_matched_col = end_c;
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

            let full_line = output_stream[in_lines_start[last_matched_line]..in_lines_end[last_matched_line]];
            let search_slice = if last_matched_col < full_line.len { full_line[last_matched_col..] } else { "" };
            var sub_end_col: i64 = 0;
            if !match_pattern_in_line(search_slice, pat, ctx, sub_end_col) {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-SAME] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": same line does not contain '");
                out_diag.append(pat);
                out_diag.append("' after previous match\n  Actual remainder: '");
                out_diag.append(search_slice);
                out_diag.append("'\n");
                return false;
            }
            last_matched_col += sub_end_col;
        } else if rule.kind == CheckKind.Empty {
            let next_target = last_matched_line + 1;
            if next_target >= section_end_line || next_target >= in_lines_start.len {
                out_diag.append("FileCheck [");
                out_diag.append(pref);
                out_diag.append("-EMPTY] FAILED on line ");
                format(out_diag, rule.line_no);
                out_diag.append(": reached end of section/input, expected empty line\n");
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
            last_matched_col = 0;
            in_idx = next_target + 1;
        } else if rule.kind == CheckKind.Not {
            var bound_line = section_end_line;
            var check_same_line = false;
            var same_limit_col: i64 = -1;
            var next_r = r_idx + 1;
            while next_r < rules.len {
                let nk = rules[next_r].kind;
                if nk == CheckKind.Not {
                    next_r += 1;
                    continue;
                }
                if nk == CheckKind.Same {
                    check_same_line = true;
                    bound_line = in_idx;
                    if last_matched_line >= 0 && last_matched_line < in_lines_start.len {
                        let full_line = output_stream[in_lines_start[last_matched_line]..in_lines_end[last_matched_line]];
                        let rem_slice = if last_matched_col < full_line.len { full_line[last_matched_col..] } else { "" };
                        let same_pat: const u8[:] = rules[next_r].pattern[..];
                        var same_end: i64 = 0;
                        var tmp_ctx = ctx;
                        if match_pattern_in_line(rem_slice, same_pat, tmp_ctx, same_end) {
                            same_limit_col = last_matched_col + same_end - same_pat.len;
                            if same_limit_col < last_matched_col {
                                same_limit_col = last_matched_col + same_end;
                            }
                        } else {
                            same_limit_col = full_line.len;
                        }
                    }
                    break;
                }
                if nk == CheckKind.Next || nk == CheckKind.Empty {
                    bound_line = min(bound_line, in_idx + 1);
                    break;
                }
                if nk == CheckKind.Check || nk == CheckKind.Label || nk == CheckKind.Count || nk == CheckKind.Dag {
                    let next_pat: const u8[:] = rules[next_r].pattern[..];
                    var s_i = in_idx;
                    var tmp_ctx = ctx;
                    while s_i < bound_line {
                        let l_str = output_stream[in_lines_start[s_i]..in_lines_end[s_i]];
                        var dummy_col: i64 = 0;
                        if match_pattern_in_line(l_str, next_pat, tmp_ctx, dummy_col) {
                            bound_line = s_i;
                            break;
                        }
                        s_i += 1;
                    }
                    break;
                }
                next_r += 1;
            }

            if check_same_line && last_matched_line >= 0 && last_matched_line < in_lines_start.len {
                let full_line = output_stream[in_lines_start[last_matched_line]..in_lines_end[last_matched_line]];
                let end_col = if same_limit_col >= last_matched_col && same_limit_col <= full_line.len { same_limit_col } else { full_line.len };
                let rem_slice = if last_matched_col < end_col { full_line[last_matched_col..end_col] } else { "" };
                var dummy_col: i64 = 0;
                if match_pattern_in_line(rem_slice, pat, ctx, dummy_col) {
                    out_diag.append("FileCheck [");
                    out_diag.append(pref);
                    out_diag.append("-NOT] FAILED on line ");
                    format(out_diag, rule.line_no);
                    out_diag.append(": forbidden pattern '");
                    out_diag.append(pat);
                    out_diag.append("' appeared on input line ");
                    format(out_diag, last_matched_line + 1);
                    out_diag.append(":\n  '");
                    out_diag.append(full_line);
                    out_diag.append("'\n");
                    return false;
                }
            }

            var chk_i = in_idx;
            while chk_i < bound_line {
                let l_str = output_stream[in_lines_start[chk_i]..in_lines_end[chk_i]];
                var dummy_col: i64 = 0;
                if match_pattern_in_line(l_str, pat, ctx, dummy_col) {
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

            let bound_line = section_end_line;

            claimed.clear();
            var max_matched_line = in_idx - 1;
            var max_matched_col: i64 = 0;

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
                        var dag_col: i64 = 0;
                        if match_pattern_in_line(l_str, d_pat, ctx, dag_col) {
                            found_dag_line = l_i;
                            claimed.push(l_i);
                            if l_i > max_matched_line {
                                max_matched_line = l_i;
                                max_matched_col = dag_col;
                            } else if l_i == max_matched_line && dag_col > max_matched_col {
                                max_matched_col = dag_col;
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
            last_matched_col = max_matched_col;
            in_idx = max_matched_line + 1;
            r_idx = dag_end;
            continue;
        } else if rule.kind == CheckKind.Count {
            let count_needed = rule.count;
            var found_count: i64 = 0;
            var cur_i = in_idx;
            while cur_i < section_end_line && found_count < count_needed {
                let l_str = output_stream[in_lines_start[cur_i]..in_lines_end[cur_i]];
                var end_c: i64 = 0;
                if match_pattern_in_line(l_str, pat, ctx, end_c) {
                    found_count += 1;
                    last_matched_line = cur_i;
                    last_matched_col = end_c;
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
