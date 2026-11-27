// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sloc/scanner.goose - Single-pass SLOC, statement, comment, compiler smell,
// repo-wide dead_fn, multi-entry BCE, and format verification engine.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import crap.ast.model;
import crap.lexer.scanner;
import crap.compiler.bridge;
import sloc.model;

fn sloc_token_text(src: const u8[:], tok: const crap::Token&) -> const u8[:] {
    let start: i64 = tok.start;
    let end:   i64 = start + tok.len;
    guard start >= 0 && end >= start && end <= src.len else { return ""; }
    return src[start..end];
}

fn count_raw_lines(src: const u8[:]) -> i64 {
    guard src.len > 0 else { return 0; }
    var lines: i64 = 0;
    for b in src {
        if b == '\n' {
            lines += 1;
        }
    }
    if src[src.len - 1] != '\n' {
        lines += 1;
    }
    return lines;
}

// Marks bit 2 on every 1-based line touched by // or /* ... */ comments,
// respecting string literals and nested block comments.
fn mark_comment_lines(src: const u8[:], line_flags: u8[>..]&) {
    var i: i64 = 0;
    let n = src.len;
    var line: i64 = 1;

    while i < n {
        let c = src[i];
        if c == '\n' {
            line += 1;
            i += 1;
            continue;
        }
        // Raw string literal: """ ... """
        if c == '"' && i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"' {
            i += 3;
            while i < n {
                if src[i] == '\n' {
                    line += 1;
                    i += 1;
                } else if src[i] == '"' && i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"' {
                    i += 3;
                    break;
                } else {
                    i += 1;
                }
            }
            continue;
        }
        // Quoted string or char literal
        if c == '"' || c == '\'' {
            let quote = c;
            i += 1;
            while i < n {
                let sc = src[i];
                if sc == '\n' {
                    line += 1;
                }
                if sc == '\\' && i + 1 < n {
                    i += 2;
                    continue;
                }
                i += 1;
                if sc == quote {
                    break;
                }
            }
            continue;
        }
        // Line comment
        if c == '/' && i + 1 < n && src[i + 1] == '/' {
            if line < line_flags.len {
                line_flags[line] = line_flags[line] | 2;
            }
            i += 2;
            while i < n && src[i] != '\n' {
                i += 1;
            }
            continue;
        }
        // Nested block comment
        if c == '/' && i + 1 < n && src[i + 1] == '*' {
            if line < line_flags.len {
                line_flags[line] = line_flags[line] | 2;
            }
            i += 2;
            var depth: i32 = 1;
            while i < n && depth > 0 {
                if src[i] == '\n' {
                    line += 1;
                    i += 1;
                    if line < line_flags.len {
                        line_flags[line] = line_flags[line] | 2;
                    }
                } else if src[i] == '/' && i + 1 < n && src[i + 1] == '*' {
                    depth += 1;
                    i += 2;
                } else if src[i] == '*' && i + 1 < n && src[i + 1] == '/' {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            continue;
        }
        i += 1;
    }
}

fn find_matching_close_brace(tokens: const crap::Token[:], open_idx: i64) -> i64 {
    guard open_idx >= 0 && open_idx < tokens.len && tokens[open_idx].kind == crap::TOK_LCURLY else {
        return -1;
    }
    var depth: i64 = 1;
    var k:     i64 = open_idx + 1;
    while k < tokens.len {
        let tk = tokens[k].kind;
        if tk == crap::TOK_LCURLY {
            depth += 1;
        } else if tk == crap::TOK_RCURLY {
            depth -= 1;
            if depth == 0 { return k; }
        }
        k += 1;
    }
    return -1;
}

fn is_sat_helper_name(word: const u8[:]) -> bool {
    return crap::slice_starts_with(word, "add_sat_") ||
        crap::slice_starts_with(word, "sub_sat_") ||
        crap::slice_starts_with(word, "mul_sat_");
}

fn is_manual_while_len(src: const u8[:], tokens: const crap::Token[:], while_idx: i64) -> bool {
    var seen_lt = false;
    var k: i64 = while_idx + 1;
    while k < tokens.len {
        let tk = tokens[k].kind;
        if tk == crap::TOK_LCURLY || tk == crap::TOK_SEMI || tk == crap::TOK_EOF {
            break;
        }
        if tk == crap::TOK_LT {
            seen_lt = true;
        } else if seen_lt && tk == crap::TOK_DOT && k + 1 < tokens.len && tokens[k + 1].kind == crap::TOK_IDENT {
            if sloc_token_text(src, tokens[k + 1]) == "len" {
                return true;
            }
        }
        k += 1;
    }
    return false;
}

fn is_val_copy_for_loop(src: const u8[:], tokens: const crap::Token[:], for_idx: i64) -> bool {
    guard for_idx + 2 < tokens.len else { return false; }
    // Skip `const for`
    if for_idx > 0 && tokens[for_idx - 1].kind == crap::TOK_CONST {
        return false;
    }
    // `for &item in xs` starts with TOK_OTHER '&' -> already by-ref
    if tokens[for_idx + 1].kind != crap::TOK_IDENT {
        return false;
    }
    let var_name = sloc_token_text(src, tokens[for_idx + 1]);
    guard var_name != "_" else { return false; }

    // Find opening '{' of loop body
    var body_open: i64 = -1;
    var k:         i64 = for_idx + 2;
    while k < tokens.len {
        let tk = tokens[k].kind;
        if tk == crap::TOK_LCURLY {
            body_open = k;
            break;
        }
        if tk == crap::TOK_SEMI || tk == crap::TOK_EOF {
            return false;
        }
        k += 1;
    }
    let body_close = find_matching_close_brace(tokens, body_open);
    guard body_close > body_open else { return false; }

    var bi: i64 = body_open + 1;
    while bi + 2 < body_close {
        if tokens[bi].kind == crap::TOK_IDENT &&
           tokens[bi + 1].kind == crap::TOK_DOT &&
           tokens[bi + 2].kind == crap::TOK_IDENT {
            if sloc_token_text(src, tokens[bi]) == var_name {
                return true;
            }
        }
        bi += 1;
    }
    return false;
}

fn is_multiret_inline_fn(tokens: const crap::Token[:], fn_idx: i64) -> bool {
    guard fn_idx > 0 && fn_idx + 2 < tokens.len else { return false; }
    // Walk from fn_idx past parameter list `(...)` to `->` or `{`
    var k:           i64 = fn_idx + 1;
    var paren_depth: i64 = 0;
    var seen_params = false;
    var arrow_idx: i64 = -1;

    while k < tokens.len {
        let tk = tokens[k].kind;
        if tk == crap::TOK_LPAREN {
            paren_depth += 1;
            seen_params = true;
        } else if tk == crap::TOK_RPAREN {
            if paren_depth > 0 { paren_depth -= 1; }
        } else if paren_depth == 0 {
            if seen_params && tk == crap::TOK_ARROW {
                arrow_idx = k;
                break;
            }
            if tk == crap::TOK_LCURLY || tk == crap::TOK_SEMI || tk == crap::TOK_EOF {
                return false;
            }
        }
        k += 1;
    }
    guard arrow_idx > 0 else { return false; }

    var p_dep: i64 = 0;
    var b_dep: i64 = 0;
    var a_dep: i64 = 0;
    var r:     i64 = arrow_idx + 1;
    while r < tokens.len {
        let tk = tokens[r].kind;
        if tk == crap::TOK_LPAREN { p_dep += 1; }
        else if tk == crap::TOK_RPAREN && p_dep > 0 { p_dep -= 1; }
        else if tk == crap::TOK_LBRACKET { b_dep += 1; }
        else if tk == crap::TOK_RBRACKET && b_dep > 0 { b_dep -= 1; }
        else if tk == crap::TOK_LT { a_dep += 1; }
        else if tk == crap::TOK_GT && a_dep > 0 { a_dep -= 1; }
        else if p_dep == 0 && b_dep == 0 && a_dep == 0 {
            if tk == crap::TOK_COMMA { return true; }
            if tk == crap::TOK_LCURLY || tk == crap::TOK_SEMI || tk == crap::TOK_EOF {
                return false;
            }
        }
        r += 1;
    }
    return false;
}

fn scan_tokens_stmts_and_smells(src: const u8[:], tokens: const crap::Token[:], st: FileSlocStats&) {
    var brace_depth: i64 = 0;
    var loop_depth:  i64 = 0;
    var pending_loop = false;
    var loop_braces: u8[64] = [0; 64];
    var paren_depth: i64    = 0;

    for i in tokens.len {
        let tk = tokens[i].kind;
        guard tk != crap::TOK_EOF else { break; }

        if tk == crap::TOK_LPAREN {
            paren_depth += 1;
        } else if tk == crap::TOK_RPAREN && paren_depth > 0 {
            paren_depth -= 1;
        } else if tk == crap::TOK_LCURLY {
            brace_depth += 1;
            if pending_loop && paren_depth == 0 {
                pending_loop = false;
                loop_depth += 1;
                if brace_depth >= 0 && brace_depth < 64 {
                    loop_braces[brace_depth] = 1;
                }
            }
        } else if tk == crap::TOK_RCURLY {
            if brace_depth >= 0 && brace_depth < 64 && loop_braces[brace_depth] == 1 {
                loop_braces[brace_depth] = 0;
                if loop_depth > 0 { loop_depth -= 1; }
            }
            if brace_depth > 0 { brace_depth -= 1; }
        }

        // Logical statements (excludes TOK_ELSE, extern fn, and fn(...) types)
        if tk == crap::TOK_SEMI || tk == crap::TOK_IF || tk == crap::TOK_GUARD ||
           tk == crap::TOK_WHILE || tk == crap::TOK_FOR || tk == crap::TOK_LOOP ||
           tk == crap::TOK_MATCH || tk == crap::TOK_DEFER || tk == crap::TOK_BLOCK ||
           tk == crap::TOK_STRUCT || tk == crap::TOK_ENUM {
            st.stmts += 1;
        } else if tk == crap::TOK_FN {
            let prev_kind = if i > 0 { tokens[i - 1].kind } else { crap::TOK_EOF };
            let next_kind = if i + 1 < tokens.len { tokens[i + 1].kind } else { crap::TOK_EOF };
            let is_decl = prev_kind != crap::TOK_EXTERN &&
                prev_kind != crap::TOK_COLON &&
                prev_kind != crap::TOK_ARROW &&
                next_kind != crap::TOK_LPAREN;
            if is_decl {
                st.stmts += 1;
                if prev_kind == crap::TOK_IDENT && sloc_token_text(src, tokens[i - 1]) == "inline" {
                    if is_multiret_inline_fn(tokens, i) {
                        st.smell_multiret_inline += 1;
                    }
                }
            }
        }

        // Loop smell tracking
        if tk == crap::TOK_WHILE {
            pending_loop = true;
            if is_manual_while_len(src, tokens, i) {
                st.smell_manual_while += 1;
            }
        } else if tk == crap::TOK_FOR {
            let is_const_for = i > 0 && tokens[i - 1].kind == crap::TOK_CONST;
            if !is_const_for {
                pending_loop = true;
                if is_val_copy_for_loop(src, tokens, i) {
                    st.smell_val_copy_for += 1;
                }
            }
        } else if tk == crap::TOK_LOOP {
            pending_loop = true;
        } else if tk == crap::TOK_IDENT {
            let word = sloc_token_text(src, tokens[i]);
            if word == "var" && i + 4 < tokens.len &&
               tokens[i + 1].kind == crap::TOK_IDENT &&
               tokens[i + 2].kind == crap::TOK_COLON &&
               tokens[i + 3].kind == crap::TOK_IDENT &&
               sloc_token_text(src, tokens[i + 3]) == "u64" &&
               (tokens[i + 4].kind == crap::TOK_ASSIGN || tokens[i + 4].kind == crap::TOK_SEMI) {
                st.smell_u64_loop += 1;
            }
            if loop_depth > 0 && i + 1 < tokens.len && tokens[i + 1].kind == crap::TOK_LPAREN {
                if is_sat_helper_name(word) {
                    st.smell_sat_loop += 1;
                }
            }
        }
    }

    st.smells_total = st.smell_u64_loop + st.smell_sat_loop +
        st.smell_val_copy_for + st.smell_manual_while + st.smell_multiret_inline;
}

fn scan_goose_sloc_src(
    rel_path: const u8[:],
    src:      const u8[:],
    pool:     u8[>..]&,
    out_stat: FileSlocStats&,
) {
    var norm: u8[>..] = [];
    crap::normalize_slashes(rel_path, norm);
    var p: const u8[:] = norm[..];
    while crap::slice_starts_with(p, "./") {
        p = p[2..];
    }
    let po, pl = crap::pool_add(pool, p);
    out_stat = FileSlocStats { path_off: po, path_len: pl, .. };
    out_stat.raw_lines = count_raw_lines(src);
    guard out_stat.raw_lines > 0 else { return; }

    var tokens:  crap::Token[>..]      = [];
    var pragmas: crap::LinePragma[>..] = [];
    crap::tokenize_goose(src, tokens, pragmas);

    var line_flags: u8[>..] = [];
    for _ in out_stat.raw_lines + 2 {
        line_flags.push(0);
    }

    for &t in tokens {
        guard t.kind != crap::TOK_EOF else { break; }
        out_stat.tokens += 1;
        var ln: i64 = t.line;
        if ln >= 1 && ln < line_flags.len {
            line_flags[ln] = line_flags[ln] | 1;
        }
        if t.kind == crap::TOK_STRING && t.len > 0 {
            let txt = sloc_token_text(src, t);
            for b in txt {
                if b == '\n' {
                    ln += 1;
                    if ln >= 1 && ln < line_flags.len {
                        line_flags[ln] = line_flags[ln] | 1;
                    }
                }
            }
        }
    }

    mark_comment_lines(src, line_flags);

    for ln in 1..out_stat.raw_lines + 1 {
        let f = line_flags[ln];
        if (f & 1) != 0 {
            out_stat.sloc += 1;
        } else if (f & 2) != 0 {
            out_stat.comment_lines += 1;
        }
    }

    scan_tokens_stmts_and_smells(src, tokens[..], out_stat);

    if out_stat.sloc > 0 {
        out_stat.packing_x100 = (out_stat.stmts * 100 + (out_stat.sloc / 2)) / out_stat.sloc;
        out_stat.tok_density_x100 = (out_stat.tokens * 100 + (out_stat.sloc / 2)) / out_stat.sloc;
    }
}

fn extract_top_dir(rel_path: const u8[:]) -> const u8[:] {
    let slash = crap::slice_index_of_byte(rel_path, '/');
    if slash <= 0 {
        return ".";
    }
    return rel_path[..slash];
}

fn scan_sloc_files(
    paths_blob: const u8[:],
    pool:       u8[>..]&,
    files:      FileSlocStats[>..]&,
    dirs:       DirSlocStats[>..]&,
) {
    var src_buf: u8[>..] = [];
    var start:   i64     = 0;
    while start < paths_blob.len {
        let rel_nl = crap::slice_index_of_byte(paths_blob[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { paths_blob.len };
        let fpath = crap::trim_ascii(paths_blob[start..end]);
        start = end + 1;
        guard fpath.len > 0 else { continue; }

        src_buf.clear();
        guard read_file(fpath, src_buf) else { continue; }

        var st = FileSlocStats { .. };
        scan_goose_sloc_src(fpath, src_buf[..], pool, st);
        files.push(st);

        let norm_path = crap::pool_slice(pool[..], st.path_off, st.path_len);
        let dir_name = extract_top_dir(norm_path);
        var found_dir = false;
        for &d in dirs {
            if crap::pool_slice(pool[..], d.dir_off, d.dir_len) == dir_name {
                d.files += 1;
                d.sloc += st.sloc;
                d.stmts += st.stmts;
                d.tokens += st.tokens;
                d.comment_lines += st.comment_lines;
                d.smells_total += st.smells_total;
                found_dir = true;
                break;
            }
        }
        if !found_dir {
            let doff, dlen = crap::pool_add(pool, dir_name);
            dirs.push(DirSlocStats {
                dir_off:       doff,
                dir_len:       dlen,
                files:         1,
                sloc:          st.sloc,
                stmts:         st.stmts,
                tokens:        st.tokens,
                comment_lines: st.comment_lines,
                smells_total:  st.smells_total,
            });
        }
    }
}

// Open-addressed u64 hash set for O(1) repo-wide call-site lookup.
fn hash_set_insert(table: u64[>..]&, h_raw: u64) {
    let h = h_raw | 1;
    guard table.len > 0 else { return; }
    let mask = (table.len as u64) - 1;
    var idx = (h & mask) as i64;
    for _ in table.len {
        let cur = table[idx];
        if cur == 0 {
            table[idx] = h;
            return;
        }
        if cur == h {
            return;
        }
        idx = ((idx as u64 + 1) & mask) as i64;
    }
}

fn hash_set_contains(table: const u64[:], h_raw: u64) -> bool {
    let h = h_raw | 1;
    guard table.len > 0 else { return false; }
    let mask = (table.len as u64) - 1;
    var idx = (h & mask) as i64;
    for _ in table.len {
        let cur = table[idx];
        if cur == 0 { return false; }
        if cur == h { return true; }
        idx = ((idx as u64 + 1) & mask) as i64;
    }
    return false;
}

fn fnv1a_name_hash(s: const u8[:]) -> u64 {
    var h: u64 = 14695981039346656037;
    for b in s {
        h = (h ^ b) * 1099511628211;
    }
    return h ^ ((s.len as u64) * 1099511628211);
}

fn collect_calls_in_tokens(src: const u8[:], tokens: const crap::Token[:], raw_hashes: u64[>..]&) {
    for i in tokens.len {
        guard tokens[i].kind == crap::TOK_IDENT else { continue; }
        let prev_kind = if i > 0 { tokens[i - 1].kind } else { crap::TOK_EOF };
        // Exclude function declarations (`fn foo`, `fn ::foo`, `fn ns::foo`)
        if prev_kind == crap::TOK_FN {
            continue;
        }
        if prev_kind == crap::TOK_COLONCOLON {
            if i >= 2 && tokens[i - 2].kind == crap::TOK_FN {
                continue;
            }
            if i >= 3 && tokens[i - 3].kind == crap::TOK_FN {
                continue;
            }
        }
        let next_kind = if i + 1 < tokens.len { tokens[i + 1].kind } else { crap::TOK_EOF };
        let is_call = next_kind == crap::TOK_LPAREN ||
            next_kind == crap::TOK_LT ||
            prev_kind == crap::TOK_COLONCOLON ||
            (prev_kind == crap::TOK_DOT && next_kind == crap::TOK_LPAREN);
        if is_call {
            let word = sloc_token_text(src, tokens[i]);
            if word.len > 0 {
                raw_hashes.push(fnv1a_name_hash(word));
            }
        }
    }
}

fn collect_repo_dead_fns(
    scan_root:           const u8[:],
    shipping_paths_blob: const u8[:],
    pool:                u8[>..]&,
    out_dead:            DeadFnCandidate[>..]&,
) {
    // 1. Gather call-site hashes across ALL repo files (including tests, bench, examples, tools)
    var all_paths: u8[>..] = [];
    let root = if scan_root.len > 0 { scan_root } else { "." };
    crap::collect_goose_files_filtered(root, true, "", all_paths);

    var raw_hashes: u64[>..]              = [];
    var src_buf:    u8[>..]               = [];
    var tokens:     crap::Token[>..]      = [];
    var pragmas:    crap::LinePragma[>..] = [];

    var start: i64 = 0;
    while start < all_paths.len {
        let rel_nl = crap::slice_index_of_byte(all_paths[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { all_paths.len };
        let fpath = crap::trim_ascii(all_paths[start..end]);
        start = end + 1;
        guard fpath.len > 0 else { continue; }
        src_buf.clear();
        guard read_file(fpath, src_buf) else { continue; }
        tokens.clear();
        pragmas.clear();
        crap::tokenize_goose(src_buf[..], tokens, pragmas);
        collect_calls_in_tokens(src_buf[..], tokens[..], raw_hashes);
    }

    // Build open-addressed table sized to power-of-2 >= 4 * raw_hashes.len (min 1024)
    var cap: i64 = 1024;
    while cap < raw_hashes.len * 4 && cap < 1048576 {
        cap *= 2;
    }
    var called_set: u64[>..] = [];
    for _ in cap {
        called_set.push(0);
    }
    for h in raw_hashes {
        hash_set_insert(called_set, h);
    }

    // 2. Check every shipping function declaration against called_set
    var norm_path: u8[>..] = [];
    start = 0;
    while start < shipping_paths_blob.len {
        let rel_nl = crap::slice_index_of_byte(shipping_paths_blob[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { shipping_paths_blob.len };
        let fpath = crap::trim_ascii(shipping_paths_blob[start..end]);
        start = end + 1;
        guard fpath.len > 0 else { continue; }
        src_buf.clear();
        guard read_file(fpath, src_buf) else { continue; }
        tokens.clear();
        pragmas.clear();
        crap::tokenize_goose(src_buf[..], tokens, pragmas);

        norm_path.clear();
        crap::normalize_slashes(fpath, norm_path);
        var fp: const u8[:] = norm_path[..];
        while crap::slice_starts_with(fp, "./") {
            fp = fp[2..];
        }
        let foff, flen = crap::pool_add(pool, fp);

        for i in tokens.len {
            guard tokens[i].kind == crap::TOK_FN && i + 1 < tokens.len else { continue; }
            let prev_kind = if i > 0 { tokens[i - 1].kind } else { crap::TOK_EOF };
            guard prev_kind != crap::TOK_EXTERN && prev_kind != crap::TOK_COLON && prev_kind != crap::TOK_ARROW else {
                continue;
            }
            if prev_kind == crap::TOK_IDENT && sloc_token_text(src_buf[..], tokens[i - 1]) == "export" {
                continue;
            }
            var name_idx = i + 1;
            if tokens[name_idx].kind == crap::TOK_COLONCOLON && name_idx + 1 < tokens.len {
                name_idx += 1;
            } else if tokens[name_idx].kind == crap::TOK_IDENT &&
                      name_idx + 2 < tokens.len &&
                      tokens[name_idx + 1].kind == crap::TOK_COLONCOLON {
                name_idx += 2;
            }
            guard tokens[name_idx].kind == crap::TOK_IDENT else { continue; }
            let fname = sloc_token_text(src_buf[..], tokens[name_idx]);
            guard fname.len > 0 && fname != "main" && !crap::slice_starts_with(fname, "test_") else {
                continue;
            }
            if !hash_set_contains(called_set[..], fnv1a_name_hash(fname)) {
                let noff, nlen = crap::pool_add(pool, fname);
                out_dead.push(DeadFnCandidate {
                    file_off: foff,
                    file_len: flen,
                    name_off: noff,
                    name_len: nlen,
                    line:     tokens[i].line,
                });
            }
        }
    }
}

fn attach_multi_entry_bce(
    entries_blob: const u8[:],
    pool:         const u8[:],
    files:        FileSlocStats[>..]&,
) -> bool {
    var any_ok = false;
    var bce_out:  u8[>..]  = [];
    var file_buf: u8[>..]  = [];
    var run_kept: i64[>..] = [];
    var run_elid: i64[>..] = [];
    for _ in files.len {
        run_kept.push(0);
        run_elid.push(0);
    }

    var start: i64 = 0;
    while start < entries_blob.len {
        let rel_nl = crap::slice_index_of_byte(entries_blob[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { entries_blob.len };
        let entry = crap::trim_ascii(entries_blob[start..end]);
        start = end + 1;
        guard entry.len > 0 && (file_exists(entry) || is_dir(entry)) else { continue; }

        bce_out.clear();
        let rc = crap::run_goose_bce_lines(entry, bce_out);
        guard rc == 0 else { continue; }

        if !any_ok {
            any_ok = true;
            for &f in files {
                f.bce_kept = 0;
                f.bce_elided = 0;
            }
        }
        for idx in files.len {
            run_kept[idx] = 0;
            run_elid[idx] = 0;
        }

        var lstart: i64 = 0;
        while lstart < bce_out.len {
            let nl = crap::slice_index_of_byte(bce_out[lstart..], '\n');
            let lend = if nl >= 0 { lstart + nl } else { bce_out.len };
            let raw_line = bce_out[lstart..lend];
            lstart = lend + 1;

            file_buf.clear();
            var lnum:   i32 = 0;
            var elided: i32 = 0;
            var kept:   i32 = 0;
            if crap::parse_bce_line(raw_line, file_buf, lnum, elided, kept) {
                for fi in files.len {
                    let fpath = crap::pool_slice(pool, files[fi].path_off, files[fi].path_len);
                    if crap::paths_match(fpath, file_buf[..]) {
                        run_kept[fi] += kept;
                        run_elid[fi] += elided;
                        break;
                    }
                }
            }
        }

        for fi in files.len {
            if run_kept[fi] > files[fi].bce_kept {
                files[fi].bce_kept = run_kept[fi];
            }
            if run_elid[fi] > files[fi].bce_elided {
                files[fi].bce_elided = run_elid[fi];
            }
        }
    }
    return any_ok;
}

fn check_goose_format_files(paths_blob: const u8[:], failed_out: u8[>..]&) -> i64 {
    var fails:   i64     = 0;
    var tmp_out: u8[>..] = [];
    var start:   i64     = 0;
    while start < paths_blob.len {
        let rel_nl = crap::slice_index_of_byte(paths_blob[start..], '\n');
        let end = if rel_nl >= 0 { start + rel_nl } else { paths_blob.len };
        let fpath = crap::trim_ascii(paths_blob[start..end]);
        start = end + 1;
        guard fpath.len > 0 else { continue; }
        tmp_out.clear();
        let rc = crap::exec_argv_capture("goose", "format", "--check", fpath, 0, tmp_out);
        if rc != 0 {
            fails += 1;
            failed_out.append(fpath);
            failed_out.push('\n');
        }
    }
    return fails;
}
