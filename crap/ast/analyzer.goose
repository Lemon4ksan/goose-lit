// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// AST structural scanner and control-flow complexity analyzer for Goose codebases.
// Computes McCabe cyclomatic complexity, Sonar/Goose cognitive complexity,
// branch sites, and overflow operation counts.
namespace crap;

import std;
import sys.bytes;
import crap.lexer.scanner;
import crap.ast.model;

fn is_ascii_alpha(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

fn has_segment_keyword(s: const u8[:], kw: const u8[:]) -> bool {
    guard s.len >= kw.len && kw.len > 0 else { return false; }
    let limit = s.len - kw.len;
    var i: i64 = 0;
    while i <= limit {
        if s[i..i + kw.len] == kw {
            let left_ok = (i == 0) || !is_ascii_alpha(s[i - 1]);
            let right_idx = i + kw.len;
            let right_ok = (right_idx == s.len) || !is_ascii_alpha(s[right_idx]);
            if left_ok && right_ok {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

fn is_untrusted_path_or_ns(path: const u8[:], ns: const u8[:]) -> bool {
    if has_segment_keyword(path, "untrusted") || has_segment_keyword(ns, "untrusted") { return true; }
    if has_segment_keyword(path, "wire") || has_segment_keyword(ns, "wire") { return true; }
    if has_segment_keyword(path, "input") || has_segment_keyword(ns, "input") { return true; }
    if has_segment_keyword(path, "external") || has_segment_keyword(ns, "external") { return true; }
    if has_segment_keyword(path, "codec") || has_segment_keyword(ns, "codec") { return true; }
    if has_segment_keyword(path, "parse") || has_segment_keyword(ns, "parse") { return true; }
    if has_segment_keyword(path, "net") || has_segment_keyword(ns, "net") { return true; }
    if has_segment_keyword(path, "io") || has_segment_keyword(ns, "io") { return true; }
    if has_segment_keyword(path, "security") || has_segment_keyword(ns, "security") { return true; }
    if has_segment_keyword(path, "auth") || has_segment_keyword(ns, "auth") { return true; }
    return false;
}

fn find_matching_rcurly(tokens: const Token[:], open_idx: i64) -> i64 {
    guard open_idx >= 0 && open_idx < tokens.len && tokens[open_idx].kind == TOK_LCURLY else {
        return -1;
    }
    var nest: i32 = 1;
    var k:    i64 = open_idx + 1;
    while k < tokens.len {
        if tokens[k].kind == TOK_LCURLY {
            nest += 1;
        } else if tokens[k].kind == TOK_RCURLY {
            nest -= 1;
            if nest == 0 {
                return k;
            }
        }
        k += 1;
    }
    return -1;
}

fn find_block_body_open(tokens: const Token[:], start_idx: i64) -> i64 {
    var p_nest: i32 = 0;
    var b_nest: i32 = 0;
    var k:      i64 = start_idx;
    while k < tokens.len {
        let tk = tokens[k].kind;
        if tk == TOK_SEMI && p_nest == 0 && b_nest == 0 {
            return -1;
        }
        if tk == TOK_LPAREN {
            p_nest += 1;
        } else if tk == TOK_RPAREN {
            if p_nest > 0 { p_nest -= 1; }
        } else if tk == TOK_LBRACKET {
            b_nest += 1;
        } else if tk == TOK_RBRACKET {
            if b_nest > 0 { b_nest -= 1; }
        } else if tk == TOK_LCURLY {
            if p_nest > 0 || b_nest > 0 {
                let close_c = find_matching_rcurly(tokens, k);
                if close_c > k {
                    k = close_c + 1;
                    continue;
                }
            } else {
                let close_c = find_matching_rcurly(tokens, k);
                if close_c > k && close_c + 1 < tokens.len {
                    let next_after = tokens[close_c + 1].kind;
                    if next_after == TOK_DOT || next_after == TOK_OTHER ||
                       next_after == TOK_ANDAND || next_after == TOK_OROR || next_after == TOK_LCURLY {
                        k = close_c + 1;
                        continue;
                    }
                }
                return k;
            }
        }
        k += 1;
    }
    return -1;
}

fn is_generic_call_after_ident(tokens: const Token[:], ident_idx: i64) -> bool {
    guard ident_idx + 1 < tokens.len && tokens[ident_idx + 1].kind == TOK_LT else {
        return false;
    }
    var angle: i32 = 1;
    var k:     i64 = ident_idx + 2;
    while k < tokens.len && angle > 0 {
        let tk = tokens[k].kind;
        if tk == TOK_SEMI || tk == TOK_LCURLY || tk == TOK_RCURLY {
            return false;
        }
        if tk == TOK_LT {
            angle += 1;
        } else if tk == TOK_GT {
            angle -= 1;
        } else if tk == TOK_SHL {
            angle += 2;
        }
        k += 1;
    }
    return angle == 0 && k < tokens.len && tokens[k].kind == TOK_LPAREN;
}

fn find_nested_fn_body_range(tokens: const Token[:], fn_tok_idx: i64) -> i64, i64 {
    if fn_tok_idx > 0 && (tokens[fn_tok_idx - 1].kind == TOK_EXTERN || tokens[fn_tok_idx - 1].kind == TOK_COLON) {
        return -1, -1;
    }
    if fn_tok_idx >= 2 && tokens[fn_tok_idx - 1].kind == TOK_STRING && tokens[fn_tok_idx - 2].kind == TOK_EXTERN {
        return -1, -1;
    }
    var k: i64 = fn_tok_idx + 1;
    guard k < tokens.len else { return -1, -1; }
    if tokens[k].kind == TOK_COLONCOLON {
        k += 1;
    } else if k + 2 < tokens.len && tokens[k].kind == TOK_IDENT && tokens[k + 1].kind == TOK_COLONCOLON {
        k += 2;
    }
    guard k < tokens.len && tokens[k].kind == TOK_IDENT else { return -1, -1; }
    k += 1;

    var p_nest: i32 = 0;
    var a_nest: i32 = 0;
    while k < tokens.len {
        let tk = tokens[k].kind;
        if tk == TOK_LPAREN {
            p_nest += 1;
        } else if tk == TOK_RPAREN {
            if p_nest > 0 { p_nest -= 1; }
        } else if tk == TOK_LT && p_nest == 0 {
            a_nest += 1;
        } else if tk == TOK_GT && p_nest == 0 && a_nest > 0 {
            a_nest -= 1;
        } else if tk == TOK_LCURLY && p_nest == 0 && a_nest == 0 {
            let close_k = find_matching_rcurly(tokens, k);
            return k, close_k;
        } else if tk == TOK_SEMI && p_nest == 0 && a_nest == 0 {
            return -1, -1;
        }
        k += 1;
    }
    return -1, -1;
}

// Parses and analyzes all functions and branch sites in a single .goose source file,
// with interprocedural call site recording for trust taint propagation.
fn analyze_goose_file_with_calls(
    file_path:  const u8[:],
    src:        const u8[:],
    pool:       u8[>..]&,
    functions:  FunctionInfo[>..]&,
    branches:   BranchSite[>..]&,
    call_sites: CallSite[>..]&,
) {
    var tokens:  Token[>..]      = [];
    var pragmas: LinePragma[>..] = [];
    tokenize_goose(src, tokens, pragmas);

    let file_off, file_len = pool_add(pool, file_path);

    var cur_ns_off:  i32     = -1;
    var cur_ns_len:  i32     = 0;
    var ns_name:     u8[>..] = [];
    var fn_name_buf: u8[>..] = [];
    var qual_buf:    u8[>..] = [];

    var tok_idx: i64 = 0;
    let num_tokens = tokens.len;

    while tok_idx < num_tokens {
        let t = tokens[tok_idx];

        // Track namespace declaration: namespace <name>;
        if t.kind == TOK_NAMESPACE && tok_idx + 1 < num_tokens {
            tok_idx++;
            ns_name.clear();
            while tok_idx < num_tokens && tokens[tok_idx].kind != TOK_SEMI {
                let nt = tokens[tok_idx];
                if nt.kind == TOK_IDENT || nt.kind == TOK_DOT || nt.kind == TOK_COLONCOLON {
                    let st: i64 = nt.start;
                    let en: i64 = nt.start + nt.len;
                    ns_name.append(src[st..en]);
                }
                tok_idx++;
            }
            if ns_name.len > 0 {
                cur_ns_off, cur_ns_len = pool_add(pool, ns_name);
            }
            if tok_idx < num_tokens && tokens[tok_idx].kind == TOK_SEMI {
                tok_idx++;
            }
            continue;
        }

        // Skip `extern "lib" { ... }` blocks (Goose spec §7.10 / §24)
        if t.kind == TOK_EXTERN && tok_idx + 2 < num_tokens &&
           tokens[tok_idx + 1].kind == TOK_STRING && tokens[tok_idx + 2].kind == TOK_LCURLY {
            tok_idx += 3;
            var ext_nest: i32 = 1;
            while tok_idx < num_tokens && ext_nest > 0 {
                if tokens[tok_idx].kind == TOK_LCURLY {
                    ext_nest++;
                } else if tokens[tok_idx].kind == TOK_RCURLY {
                    ext_nest--;
                }
                tok_idx++;
            }
            continue;
        }

        // Check for function declaration: [qualifiers] fn <name> | fn ::<name> | fn <ns>::<name>
        if t.kind == TOK_FN {
            // Make sure it is not `extern fn` or `extern "sym" fn` or a `: fn(...)` type annotation
            if tok_idx > 0 && (tokens[tok_idx - 1].kind == TOK_EXTERN || tokens[tok_idx - 1].kind == TOK_COLON) {
                tok_idx++;
                continue;
            }
            if tok_idx >= 2 && tokens[tok_idx - 1].kind == TOK_STRING && tokens[tok_idx - 2].kind == TOK_EXTERN {
                tok_idx++;
                continue;
            }

            tok_idx++;
            guard tok_idx < num_tokens else { break; }

            var explicit_ns_off: i32 = -1;
            var explicit_ns_len: i32 = 0;
            var force_global_ns = false;

            if tokens[tok_idx].kind == TOK_COLONCOLON {
                force_global_ns = true;
                tok_idx++;
            } else if tok_idx + 2 < num_tokens &&
                      tokens[tok_idx].kind == TOK_IDENT &&
                      tokens[tok_idx + 1].kind == TOK_COLONCOLON {
                let ns_tok = tokens[tok_idx];
                let ns_st: i64 = ns_tok.start;
                let ns_en: i64 = ns_tok.start + ns_tok.len;
                explicit_ns_off, explicit_ns_len = pool_add(pool, src[ns_st..ns_en]);
                tok_idx += 2;
            }

            guard tok_idx < num_tokens else { break; }
            let name_tok = tokens[tok_idx];
            guard name_tok.kind == TOK_IDENT else { continue; }

            let fn_st: i64 = name_tok.start;
            let fn_en: i64 = name_tok.start + name_tok.len;
            fn_name_buf.clear();
            fn_name_buf.append(src[fn_st..fn_en]);
            tok_idx++;

            // Case function variant parameter or name: e.g. `fn eval(e: Expr.Add&)`
            // Build qualified name: ns::name or name
            qual_buf.clear();
            if !force_global_ns {
                if explicit_ns_off >= 0 && explicit_ns_len > 0 {
                    qual_buf.append(pool_slice(pool, explicit_ns_off, explicit_ns_len));
                    qual_buf.append("::");
                } else if cur_ns_off >= 0 && cur_ns_len > 0 {
                    qual_buf.append(pool_slice(pool, cur_ns_off, cur_ns_len));
                    qual_buf.append("::");
                }
            }
            qual_buf.append(fn_name_buf);
            let name_off, name_len = pool_add(pool, fn_name_buf);
            let qual_off, qual_len = pool_add(pool, qual_buf);

            let fn_start_line = t.line;

            // Scan signature until opening '{' of function body (tracking nested braces for default literals)
            var is_generic = false;
            var takes_wire_slice = false;
            var has_float_sig = false;
            var has_int_sig = false;
            var body_open_offset: i32 = -1;
            var sig_paren_nest:   i32 = 0;
            var sig_angle_nest:   i32 = 0;
            var sig_seen_params = false;
            var sig_in_return = false;

            while tok_idx < num_tokens {
                let st = tokens[tok_idx];
                if st.kind == TOK_LT && !sig_seen_params && sig_paren_nest == 0 {
                    is_generic = true;
                    sig_angle_nest++;
                } else if st.kind == TOK_LT && sig_angle_nest > 0 {
                    sig_angle_nest++;
                } else if st.kind == TOK_GT && sig_angle_nest > 0 {
                    sig_angle_nest--;
                } else if st.kind == TOK_LPAREN {
                    sig_paren_nest++;
                    if sig_angle_nest == 0 {
                        sig_seen_params = true;
                    }
                } else if st.kind == TOK_RPAREN {
                    if sig_paren_nest > 0 {
                        sig_paren_nest--;
                    }
                } else if st.kind == TOK_ARROW && sig_paren_nest == 0 && sig_angle_nest == 0 {
                    sig_in_return = true;
                } else if sig_angle_nest == 0 && sig_paren_nest == 1 && !sig_in_return && st.kind == TOK_IDENT {
                    let prev_k = if tok_idx > 0 { tokens[tok_idx - 1].kind } else { TOK_EOF };
                    let next_k = if tok_idx + 1 < num_tokens { tokens[tok_idx + 1].kind } else { TOK_EOF };
                    if (prev_k == TOK_LPAREN || prev_k == TOK_COMMA || prev_k == TOK_IDENT) &&
                       (next_k == TOK_COMMA || next_k == TOK_RPAREN) {
                        is_generic = true;
                    }
                }
                if sig_angle_nest == 0 && st.kind == TOK_IDENT {
                    let id_st: i64 = st.start;
                    let id_en: i64 = st.start + st.len;
                    let id_s = src[id_st..id_en];
                    if id_s == "f32" || id_s == "f64" {
                        has_float_sig = true;
                    } else if id_s == "i8" || id_s == "i16" || id_s == "i32" || id_s == "i64" ||
                              id_s == "u8" || id_s == "u16" || id_s == "u32" || id_s == "u64" ||
                              id_s == "isize" || id_s == "usize" {
                        has_int_sig = true;
                    }
                }
                // Check if parameter (not return type) has wire byte slice: u8[:] or const u8[:]
                if !sig_in_return && sig_paren_nest > 0 && sig_angle_nest == 0 &&
                   st.kind == TOK_LBRACKET && tok_idx + 2 < num_tokens &&
                   tokens[tok_idx + 1].kind == TOK_COLON && tokens[tok_idx + 2].kind == TOK_RBRACKET {
                    takes_wire_slice = true;
                }
                if st.kind == TOK_LCURLY && sig_paren_nest == 0 && sig_angle_nest == 0 {
                    body_open_offset = st.start;
                    break;
                }
                if st.kind == TOK_SEMI && sig_paren_nest == 0 && sig_angle_nest == 0 {
                    // Function declaration without body (interface/extern)
                    break;
                }
                tok_idx++;
            }

            guard body_open_offset >= 0 && tok_idx < num_tokens else { continue; }

            // Check inline pragmas around function start
            var is_untrusted = false;
            var is_trusted = false;
            var is_ignored = false;
            for p in pragmas {
                if p.line >= fn_start_line - 3 && p.line <= fn_start_line + 1 {
                    if p.kind == PRAGMA_CRAP_UNTRUSTED { is_untrusted = true; }
                    if p.kind == PRAGMA_CRAP_TRUSTED { is_trusted = true; }
                    if p.kind == PRAGMA_CRAP_IGNORE { is_ignored = true; }
                }
            }

            let ns_slice = if cur_ns_off >= 0 { pool_slice(pool, cur_ns_off, cur_ns_len) } else { "" };
            var trust_class: u8 = TRUST_TRUSTED;
            if (is_untrusted || takes_wire_slice || is_untrusted_path_or_ns(file_path, ns_slice)) && !is_trusted {
                trust_class = TRUST_UNTRUSTED;
            }

            let fn_idx = functions.len as i32;
            let first_branch_idx = branches.len as i32;

            // Add default function entry branch
            let fn_entry_id = branches.len as i32;
            branches.push(BranchSite {
                branch_id:         fn_entry_id,
                func_idx:          fn_idx,
                kind:              BRANCH_FN_ENTRY,
                classification:    BRANCH_CLASS_DEFAULT,
                parent_branch:     -1,
                depth:             1,
                start_line:        fn_start_line,
                end_line:          fn_start_line,
                probe_byte_offset: body_open_offset + 1,
                body_close_offset: -1,
                needs_synth_else:  false,
                bce_keep:          0,
                bce_elide:         0,
                ovf_ops:           0,
                hits:              0,
                covered:           false,
            });

            let fn_open_tok = tok_idx;
            let fn_close_tok = find_matching_rcurly(tokens[..], fn_open_tok);
            guard fn_close_tok > fn_open_tok else {
                tok_idx++;
                continue;
            }

            // Active branch stack and exact closing token stack (or negative match-close token for unbraced match arms)
            var b_stack:           i32[>..] = [];
            var close_stack:       i32[>..] = [];
            var arm_paren_stack:   i32[>..] = [];
            var arm_bracket_stack: i32[>..] = [];

            b_stack.push(fn_entry_id);
            close_stack.push(fn_close_tok as i32);
            arm_paren_stack.push(0);
            arm_bracket_stack.push(0);

            // Walk function body tokens and compute CC & Cognitive Complexity
            var cyclomatic:       i32 = 1;
            var cognitive:        i32 = 0;
            var block_nest:       i32 = 1;
            var max_depth:        i32 = 0;
            var match_count:      i32 = 0;
            var match_arms_count: i32 = 0;
            var loops_count:      i32 = 0;
            var guards_count:     i32 = 0;
            var total_ovf:        i32 = 0;
            var bracket_nest:     i32 = 0;
            var paren_nest:       i32 = 0;

            // Tracking boolean chain sequence and block-level match / closing brace state (1-indexed by block_nest)
            var last_bool_op: u8 = 0;
            var in_guard = false;
            var block_close_stack: i32[>..]  = [];
            var is_match_brace:    bool[>..] = [];
            var match_paren_at:    i32[>..]  = [];
            var match_bracket_at:  i32[>..]  = [];
            block_close_stack.push(0);
            block_close_stack.push(fn_close_tok as i32);
            is_match_brace.push(false);
            is_match_brace.push(false);
            match_paren_at.push(0);
            match_paren_at.push(0);
            match_bracket_at.push(0);
            match_bracket_at.push(0);

            var pending_match_open_tok:     i64 = -1;
            var pending_const_for_open_tok: i64 = -1;

            var body_idx: i64 = fn_open_tok + 1;

            while body_idx <= fn_close_tok && block_nest > 0 {
                let bt = tokens[body_idx];

                // Skip nested `fn` declarations inside the outer function body so their tokens do not
                // corrupt the outer function's metrics; the outer `tok_idx` loop will visit them next.
                if bt.kind == TOK_FN {
                    let prev_bt = if body_idx > 0 { tokens[body_idx - 1].kind } else { TOK_EOF };
                    let prev2_bt = if body_idx > 1 { tokens[body_idx - 2].kind } else { TOK_EOF };
                    if prev_bt != TOK_EXTERN && prev_bt != TOK_COLON &&
                       !(prev_bt == TOK_STRING && prev2_bt == TOK_EXTERN) {
                        let n_open, n_close = find_nested_fn_body_range(tokens[..], body_idx);
                        if n_open > body_idx && n_close > n_open {
                            body_idx = n_close + 1;
                            continue;
                        }
                    }
                }

                if bt.kind == TOK_LCURLY {
                    block_nest++;
                    max_depth = max(max_depth, block_nest);
                    let cur_close = find_matching_rcurly(tokens[..], body_idx) as i32;
                    var is_m = false;
                    if body_idx == pending_match_open_tok {
                        is_m = true;
                        pending_match_open_tok = -1;
                    } else if is_match_brace[is_match_brace.len - 1] && body_idx == pending_const_for_open_tok {
                        is_m = true;
                        pending_const_for_open_tok = -1;
                    }
                    block_close_stack.push(cur_close);
                    is_match_brace.push(is_m);
                    match_paren_at.push(paren_nest);
                    match_bracket_at.push(bracket_nest);
                } else if bt.kind == TOK_RCURLY {
                    // Close any unbraced match arms whose enclosing match block terminates at this `}`
                    while b_stack.len > 1 && close_stack[b_stack.len - 1] == -(body_idx as i32) {
                        let closed_arm = b_stack[b_stack.len - 1];
                        branches[closed_arm as i64].end_line = bt.line;
                        let _ = b_stack.pop();
                        let _ = close_stack.pop();
                        let _ = arm_paren_stack.pop();
                        let _ = arm_bracket_stack.pop();
                    }

                    if block_close_stack.len > 1 {
                        let _ = block_close_stack.pop();
                        let _ = is_match_brace.pop();
                        let _ = match_paren_at.pop();
                        let _ = match_bracket_at.pop();
                    }
                    block_nest--;

                    // Close active branches that terminate at this exact `}` token index
                    while b_stack.len > 1 && close_stack[b_stack.len - 1] == (body_idx as i32) {
                        let closed_bid = b_stack[b_stack.len - 1];
                        branches[closed_bid as i64].end_line = bt.line;
                        if branches[closed_bid as i64].kind != BRANCH_MATCH_ARM {
                            branches[closed_bid as i64].body_close_offset = bt.start + 1;
                        }
                        let _ = b_stack.pop();
                        let _ = close_stack.pop();
                        let _ = arm_paren_stack.pop();
                        let _ = arm_bracket_stack.pop();

                        if branches[closed_bid as i64].kind == BRANCH_IF_THEN {
                            let has_else = (body_idx + 1 < num_tokens && tokens[body_idx + 1].kind == TOK_ELSE);
                            if !has_else {
                                let synth_id = branches.len as i32;
                                let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                                branches.push(BranchSite {
                                    branch_id:         synth_id,
                                    func_idx:          fn_idx,
                                    kind:              BRANCH_IF_ELSE,
                                    classification:    BRANCH_CLASS_IF_ELSE,
                                    parent_branch:     parent_b,
                                    depth:             block_nest,
                                    start_line:        bt.line,
                                    end_line:          bt.line,
                                    probe_byte_offset: bt.start + 1,
                                    body_close_offset: bt.start + 1,
                                    needs_synth_else:  true,
                                    bce_keep:          0,
                                    bce_elide:         0,
                                    ovf_ops:           0,
                                    hits:              0,
                                    covered:           false,
                                });
                            }
                        } else if branches[closed_bid as i64].kind == BRANCH_GUARD_FAIL {
                            let pass_id = branches.len as i32;
                            let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                            let p_depth = block_nest + 1;
                            branches.push(BranchSite {
                                branch_id:         pass_id,
                                func_idx:          fn_idx,
                                kind:              BRANCH_GUARD_PASS,
                                classification:    BRANCH_CLASS_DEFAULT,
                                parent_branch:     parent_b,
                                depth:             p_depth,
                                start_line:        bt.line,
                                end_line:          bt.line,
                                probe_byte_offset: bt.start + 1,
                                body_close_offset: bt.start + 1,
                                needs_synth_else:  false,
                                bce_keep:          0,
                                bce_elide:         0,
                                ovf_ops:           0,
                                hits:              0,
                                covered:           false,
                            });
                            let enc_close = if block_close_stack.len > 0 {
                                block_close_stack[block_close_stack.len - 1]
                            } else {
                                fn_close_tok as i32
                            };
                            b_stack.push(pass_id);
                            close_stack.push(enc_close);
                            arm_paren_stack.push(paren_nest);
                            arm_bracket_stack.push(bracket_nest);
                        } else if branches[closed_bid as i64].kind == BRANCH_LOOP_BODY {
                            let exit_id = branches.len as i32;
                            let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                            var exit_probe: i32 = bt.start + 1;
                            if body_idx + 1 < num_tokens && tokens[body_idx + 1].kind == TOK_SEMI {
                                exit_probe = tokens[body_idx + 1].start + 1;
                            }
                            branches.push(BranchSite {
                                branch_id:         exit_id,
                                func_idx:          fn_idx,
                                kind:              BRANCH_LOOP_EXIT,
                                classification:    BRANCH_CLASS_DEFAULT,
                                parent_branch:     parent_b,
                                depth:             block_nest,
                                start_line:        bt.line,
                                end_line:          bt.line,
                                probe_byte_offset: exit_probe,
                                body_close_offset: exit_probe,
                                needs_synth_else:  false,
                                bce_keep:          0,
                                bce_elide:         0,
                                ovf_ops:           0,
                                hits:              0,
                                covered:           false,
                            });
                        }
                    }

                    if block_nest == 0 || body_idx == fn_close_tok {
                        branches[fn_entry_id as i64].end_line = bt.line;
                        branches[fn_entry_id as i64].body_close_offset = bt.start + 1;
                        break;
                    }
                } else if bt.kind == TOK_IF {
                    in_guard = false;
                    let is_else_if = (body_idx > 0 && tokens[body_idx - 1].kind == TOK_ELSE);
                    cyclomatic++;
                    if is_else_if {
                        cognitive += 1;
                    } else {
                        cognitive += (1 + (block_nest - 1));
                    }
                    let body_open_k = find_block_body_open(tokens[..], body_idx + 1);
                    let body_close_k = if body_open_k >= 0 { find_matching_rcurly(tokens[..], body_open_k) } else { -1 };
                    let probe_off: i32 = if body_open_k >= 0 { tokens[body_open_k].start + 1 } else { bt.start };

                    let bid = branches.len as i32;
                    let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                    branches.push(BranchSite {
                        branch_id:         bid,
                        func_idx:          fn_idx,
                        kind:              BRANCH_IF_THEN,
                        classification:    BRANCH_CLASS_DEFAULT,
                        parent_branch:     parent_b,
                        depth:             block_nest + 1,
                        start_line:        bt.line,
                        end_line:          bt.line,
                        probe_byte_offset: probe_off,
                        body_close_offset: -1,
                        needs_synth_else:  false,
                        bce_keep:          0,
                        bce_elide:         0,
                        ovf_ops:           0,
                        hits:              0,
                        covered:           false,
                    });
                    if body_close_k > body_open_k {
                        b_stack.push(bid);
                        close_stack.push(body_close_k as i32);
                        arm_paren_stack.push(paren_nest);
                        arm_bracket_stack.push(bracket_nest);
                    }
                    last_bool_op = 0;
                } else if bt.kind == TOK_ELSE {
                    if in_guard {
                        in_guard = false;
                        let body_open_k = find_block_body_open(tokens[..], body_idx + 1);
                        let body_close_k = if body_open_k >= 0 { find_matching_rcurly(tokens[..], body_open_k) } else { -1 };
                        let probe_off: i32 = if body_open_k >= 0 { tokens[body_open_k].start + 1 } else { bt.start };

                        let bid = branches.len as i32;
                        let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                        branches.push(BranchSite {
                            branch_id:         bid,
                            func_idx:          fn_idx,
                            kind:              BRANCH_GUARD_FAIL,
                            classification:    BRANCH_CLASS_GUARD_CHECK,
                            parent_branch:     parent_b,
                            depth:             block_nest + 1,
                            start_line:        bt.line,
                            end_line:          bt.line,
                            probe_byte_offset: probe_off,
                            body_close_offset: -1,
                            needs_synth_else:  false,
                            bce_keep:          0,
                            bce_elide:         0,
                            ovf_ops:           0,
                            hits:              0,
                            covered:           false,
                        });
                        if body_close_k > body_open_k {
                            b_stack.push(bid);
                            close_stack.push(body_close_k as i32);
                            arm_paren_stack.push(paren_nest);
                            arm_bracket_stack.push(bracket_nest);
                        }
                    } else if body_idx + 1 < num_tokens && tokens[body_idx + 1].kind != TOK_IF {
                        cognitive += 1;
                        let body_open_k = find_block_body_open(tokens[..], body_idx + 1);
                        let body_close_k = if body_open_k >= 0 { find_matching_rcurly(tokens[..], body_open_k) } else { -1 };
                        let probe_off: i32 = if body_open_k >= 0 { tokens[body_open_k].start + 1 } else { bt.start };

                        let bid = branches.len as i32;
                        let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                        branches.push(BranchSite {
                            branch_id:         bid,
                            func_idx:          fn_idx,
                            kind:              BRANCH_IF_ELSE,
                            classification:    BRANCH_CLASS_IF_ELSE,
                            parent_branch:     parent_b,
                            depth:             block_nest + 1,
                            start_line:        bt.line,
                            end_line:          bt.line,
                            probe_byte_offset: probe_off,
                            body_close_offset: -1,
                            needs_synth_else:  false,
                            bce_keep:          0,
                            bce_elide:         0,
                            ovf_ops:           0,
                            hits:              0,
                            covered:           false,
                        });
                        if body_close_k > body_open_k {
                            b_stack.push(bid);
                            close_stack.push(body_close_k as i32);
                            arm_paren_stack.push(paren_nest);
                            arm_bracket_stack.push(bracket_nest);
                        }
                    }
                    last_bool_op = 0;
                } else if bt.kind == TOK_GUARD {
                    in_guard = true;
                    guards_count++;
                    cyclomatic++;
                    cognitive += 1;
                    last_bool_op = 0;
                } else if bt.kind == TOK_SEMI {
                    // Statement-form guard without else (Goose ref §16 / spec §6.4):
                    // `guard cond;` guards the rest of the block without an else block
                    if in_guard && paren_nest == 0 && bracket_nest == 0 {
                        in_guard = false;
                        let pass_id = branches.len as i32;
                        let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                        let p_depth = block_nest + 1;
                        branches.push(BranchSite {
                            branch_id:         pass_id,
                            func_idx:          fn_idx,
                            kind:              BRANCH_GUARD_PASS,
                            classification:    BRANCH_CLASS_DEFAULT,
                            parent_branch:     parent_b,
                            depth:             p_depth,
                            start_line:        bt.line,
                            end_line:          bt.line,
                            probe_byte_offset: bt.start + 1,
                            body_close_offset: bt.start + 1,
                            needs_synth_else:  false,
                            bce_keep:          0,
                            bce_elide:         0,
                            ovf_ops:           0,
                            hits:              0,
                            covered:           false,
                        });
                        let enc_close = if block_close_stack.len > 0 {
                            block_close_stack[block_close_stack.len - 1]
                        } else {
                            fn_close_tok as i32
                        };
                        b_stack.push(pass_id);
                        close_stack.push(enc_close);
                        arm_paren_stack.push(paren_nest);
                        arm_bracket_stack.push(bracket_nest);
                    }
                    last_bool_op = 0;
                } else if bt.kind == TOK_WHILE || bt.kind == TOK_FOR || bt.kind == TOK_LOOP {
                    // Compile-time `const for` (Goose ref §16 / spec §6.5) expands at compile-time;
                    // skip runtime loop probes and complexity inflation
                    let is_const_for = (bt.kind == TOK_FOR && body_idx > 0 && tokens[body_idx - 1].kind == TOK_CONST);
                    if is_const_for {
                        pending_const_for_open_tok = find_block_body_open(tokens[..], body_idx + 1);
                        last_bool_op = 0;
                    } else {
                        loops_count++;
                        cyclomatic++;
                        cognitive += (1 + (block_nest - 1));
                        let body_open_k = find_block_body_open(tokens[..], body_idx + 1);
                        let body_close_k = if body_open_k >= 0 { find_matching_rcurly(tokens[..], body_open_k) } else { -1 };
                        let probe_off: i32 = if body_open_k >= 0 { tokens[body_open_k].start + 1 } else { bt.start };

                        let bid = branches.len as i32;
                        let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                        branches.push(BranchSite {
                            branch_id:         bid,
                            func_idx:          fn_idx,
                            kind:              BRANCH_LOOP_BODY,
                            classification:    BRANCH_CLASS_DEFAULT,
                            parent_branch:     parent_b,
                            depth:             block_nest + 1,
                            start_line:        bt.line,
                            end_line:          bt.line,
                            probe_byte_offset: probe_off,
                            body_close_offset: -1,
                            needs_synth_else:  false,
                            bce_keep:          0,
                            bce_elide:         0,
                            ovf_ops:           0,
                            hits:              0,
                            covered:           false,
                        });
                        if body_close_k > body_open_k {
                            b_stack.push(bid);
                            close_stack.push(body_close_k as i32);
                            arm_paren_stack.push(paren_nest);
                            arm_bracket_stack.push(bracket_nest);
                        }
                        last_bool_op = 0;
                    }
                } else if bt.kind == TOK_MATCH {
                    match_count++;
                    cognitive += (1 + (block_nest - 1));
                    pending_match_open_tok = find_block_body_open(tokens[..], body_idx + 1);
                    last_bool_op = 0;
                } else if bt.kind == TOK_FATARROW {
                    // In Goose, => is used for match arms (Goose ref §9 / spec §8),
                    // but also in trailing function blocks { a, b => ... } (Goose ref §18 / spec §7.6).
                    // Only treat as BRANCH_MATCH_ARM if we are inside an active match block!
                    let in_match = (block_nest > 0 && block_nest < is_match_brace.len && is_match_brace[block_nest]);
                    if in_match {
                        let cur_match_close = block_close_stack[block_nest];
                        // Pop any preceding unbraced match arm in the same match block
                        while b_stack.len > 1 && close_stack[b_stack.len - 1] == -cur_match_close {
                            let _ = b_stack.pop();
                            let _ = close_stack.pop();
                            let _ = arm_paren_stack.pop();
                            let _ = arm_bracket_stack.pop();
                        }

                        match_arms_count++;
                        cyclomatic++;
                        let is_braced = (body_idx + 1 < num_tokens && tokens[body_idx + 1].kind == TOK_LCURLY);
                        var arm_probe:      i32 = bt.start + 2;
                        var arm_close:      i32 = -1;
                        var arm_end_line:   i32 = bt.line;
                        var braced_close_k: i64 = -1;

                        if is_braced {
                            arm_probe = tokens[body_idx + 1].start + 1;
                            braced_close_k = find_matching_rcurly(tokens[..], body_idx + 1);
                        } else {
                            arm_probe = if body_idx + 1 < num_tokens { tokens[body_idx + 1].start } else { bt.start + 2 };
                            var a = body_idx + 1;
                            var p_nest: i32 = 0;
                            var b_nest: i32 = 0;
                            var c_nest: i32 = 0;
                            while a < num_tokens {
                                let tk = tokens[a].kind;
                                if tk == TOK_LPAREN {
                                    p_nest++;
                                } else if tk == TOK_RPAREN {
                                    if p_nest > 0 { p_nest--; }
                                } else if tk == TOK_LBRACKET {
                                    b_nest++;
                                } else if tk == TOK_RBRACKET {
                                    if b_nest > 0 { b_nest--; }
                                } else if tk == TOK_LCURLY {
                                    c_nest++;
                                } else if tk == TOK_RCURLY {
                                    if c_nest > 0 {
                                        c_nest--;
                                    } else {
                                        break;
                                    }
                                } else if tk == TOK_COMMA {
                                    if p_nest == 0 && b_nest == 0 && c_nest == 0 {
                                        break;
                                    }
                                }
                                arm_end_line = tokens[a].line;
                                a++;
                            }
                            if a < num_tokens {
                                arm_close = tokens[a].start;
                                arm_end_line = tokens[a].line;
                            }
                        }

                        let bid = branches.len as i32;
                        let parent_b = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                        let p_depth = block_nest;
                        branches.push(BranchSite {
                            branch_id:         bid,
                            func_idx:          fn_idx,
                            kind:              BRANCH_MATCH_ARM,
                            classification:    BRANCH_CLASS_SPEC_MATCH,
                            parent_branch:     parent_b,
                            depth:             p_depth,
                            start_line:        bt.line,
                            end_line:          if is_braced { bt.line } else { arm_end_line },
                            probe_byte_offset: arm_probe,
                            body_close_offset: arm_close,
                            needs_synth_else:  false,
                            bce_keep:          0,
                            bce_elide:         0,
                            ovf_ops:           0,
                            hits:              0,
                            covered:           false,
                        });
                        if is_braced {
                            if braced_close_k > body_idx {
                                b_stack.push(bid);
                                close_stack.push(braced_close_k as i32);
                                arm_paren_stack.push(paren_nest);
                                arm_bracket_stack.push(bracket_nest);
                            }
                        } else {
                            b_stack.push(bid);
                            close_stack.push(-cur_match_close);
                            arm_paren_stack.push(match_paren_at[block_nest]);
                            arm_bracket_stack.push(match_bracket_at[block_nest]);
                        }
                    }
                    last_bool_op = 0;
                } else if bt.kind == TOK_COMMA {
                    if b_stack.len > 1 && close_stack[b_stack.len - 1] < 0 &&
                       paren_nest == arm_paren_stack[b_stack.len - 1] &&
                       bracket_nest == arm_bracket_stack[b_stack.len - 1] {
                        let closed_bid = b_stack[b_stack.len - 1];
                        branches[closed_bid as i64].end_line = bt.line;
                        let _ = b_stack.pop();
                        let _ = close_stack.pop();
                        let _ = arm_paren_stack.pop();
                        let _ = arm_bracket_stack.pop();
                    }
                } else if bt.kind == TOK_RETURN {
                    // Check if non-local unwinding: return ... from <label>;
                    var s = body_idx + 1;
                    var has_from = false;
                    while s < num_tokens && tokens[s].kind != TOK_SEMI && tokens[s].kind != TOK_RCURLY {
                        if tokens[s].kind == TOK_FROM {
                            has_from = true;
                            break;
                        }
                        s++;
                    }
                    if has_from {
                        cognitive += 1;
                        cyclomatic++;
                    }
                } else if bt.kind == TOK_LPAREN {
                    paren_nest++;
                } else if bt.kind == TOK_RPAREN {
                    if paren_nest > 0 {
                        paren_nest--;
                    }
                } else if bt.kind == TOK_ANDAND || bt.kind == TOK_OROR {
                    cyclomatic++;
                    if last_bool_op != bt.kind {
                        cognitive += 1;
                        last_bool_op = bt.kind;
                    }
                } else if bt.kind == TOK_QUESTION {
                    // Goose optional type suffix T? (Goose ref §10 / spec §3.8); not a ternary or error op.
                    last_bool_op = 0;
                } else if (bt.kind == TOK_BREAK || bt.kind == TOK_CONTINUE) && block_nest > 2 {
                    cognitive += 1;
                } else if bt.kind == TOK_IDENT {
                    // Record function call site (including generic calls `callee<T>(...)`)
                    if (body_idx == 0 || tokens[body_idx - 1].kind != TOK_FN) &&
                       body_idx + 1 < num_tokens &&
                       (tokens[body_idx + 1].kind == TOK_LPAREN || is_generic_call_after_ident(tokens[..], body_idx)) {
                        let has_qual_prefix = body_idx >= 2 &&
                            tokens[body_idx - 1].kind == TOK_COLONCOLON &&
                            tokens[body_idx - 2].kind == TOK_IDENT;
                        let c_st: i64 = if has_qual_prefix {
                            tokens[body_idx - 2].start
                        } else {
                            bt.start
                        };
                        let c_en: i64 = bt.start + bt.len;
                        let callee_slice = src[c_st..c_en];
                        let c_off, c_len = pool_add(pool, callee_slice);
                        call_sites.push(CallSite {
                            caller_idx:      fn_idx,
                            callee_name_off: c_off,
                            callee_name_len: c_len,
                            line:            bt.line,
                        });
                    }
                } else if bt.kind == TOK_LBRACKET {
                    bracket_nest++;
                } else if bt.kind == TOK_RBRACKET {
                    if bracket_nest > 0 {
                        bracket_nest--;
                    }
                } else if bt.kind == TOK_PLUS || bt.kind == TOK_MINUS || bt.kind == TOK_MUL ||
                           bt.kind == TOK_SHL || bt.kind == TOK_PLUSEQ || bt.kind == TOK_MINUSEQ ||
                           bt.kind == TOK_MULEQ || bt.kind == TOK_SHLEQ || bt.kind == TOK_INC ||
                           bt.kind == TOK_DEC || bt.kind == TOK_DIV || bt.kind == TOK_MOD ||
                           bt.kind == TOK_DIVEQ || bt.kind == TOK_MODEQ {
                    let prev_k = if body_idx > 0 { tokens[body_idx - 1].kind } else { TOK_EOF };
                    let is_unary_op = (bt.kind == TOK_MINUS || bt.kind == TOK_PLUS) && (
                        prev_k != TOK_IDENT && prev_k != TOK_NUMBER && prev_k != TOK_STRING &&
                        prev_k != TOK_RPAREN && prev_k != TOK_RBRACKET && prev_k != TOK_RCURLY
                    );
                    var is_float_arith = (has_float_sig && !has_int_sig && !takes_wire_slice);
                    if !is_float_arith && bracket_nest == 0 {
                        if body_idx > 0 && tokens[body_idx - 1].kind == TOK_NUMBER {
                            let n_st: i64 = tokens[body_idx - 1].start;
                            let n_en: i64 = n_st + tokens[body_idx - 1].len;
                            if slice_index_of_byte(src[n_st..n_en], '.') >= 0 {
                                is_float_arith = true;
                            }
                        }
                        if !is_float_arith && body_idx + 1 < num_tokens && tokens[body_idx + 1].kind == TOK_NUMBER {
                            let n_st: i64 = tokens[body_idx + 1].start;
                            let n_en: i64 = n_st + tokens[body_idx + 1].len;
                            if slice_index_of_byte(src[n_st..n_en], '.') >= 0 {
                                is_float_arith = true;
                            }
                        }
                    }
                    if !is_unary_op && (!is_float_arith || bracket_nest > 0) {
                        let is_div = bt.kind == TOK_DIV || bt.kind == TOK_MOD ||
                            bt.kind == TOK_DIVEQ || bt.kind == TOK_MODEQ;
                        let weight: i32 = if bracket_nest > 0 { 3 } else if is_div { 2 } else { 1 };
                        total_ovf += weight;
                        let active_bid = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                        if active_bid >= 0 && active_bid < branches.len {
                            branches[active_bid].ovf_ops += weight;
                        }
                    }
                } else if bt.kind == TOK_AS && body_idx + 1 < num_tokens && tokens[body_idx + 1].kind == TOK_BANG {
                    // Truncating cast 'as!'
                    total_ovf += 2;
                    let active_bid = if b_stack.len > 0 { b_stack[b_stack.len - 1] } else { -1 };
                    if active_bid >= 0 && active_bid < branches.len {
                        branches[active_bid].ovf_ops += 2;
                    }
                }

                body_idx++;
            }

            let fn_end_line = if fn_close_tok < num_tokens { tokens[fn_close_tok].line } else { fn_start_line };
            let total_fn_branches = (branches.len as i32) - first_branch_idx;

            // Map trusted-bounds audit pragmas to enclosing branch sites
            for p in pragmas {
                if p.kind == PRAGMA_CRAP_TRUSTED_BOUNDS && p.line >= fn_start_line && p.line <= fn_end_line {
                    for bi in total_fn_branches {
                        let b_idx: i64 = first_branch_idx + bi;
                        if b_idx < branches.len {
                            let b_st = branches[b_idx].start_line;
                            let b_en = branches[b_idx].end_line;
                            if p.line >= b_st && p.line <= b_en {
                                branches[b_idx].trusted_bounds = true;
                            }
                        }
                    }
                }
            }

            let effective_cc = max(1, cognitive);

            functions.push(FunctionInfo {
                func_idx:         fn_idx,
                name_off:         name_off,
                name_len:         name_len,
                qual_off:         qual_off,
                qual_len:         qual_len,
                file_off:         file_off,
                file_len:         file_len,
                start_line:       fn_start_line,
                end_line:         fn_end_line,
                body_open_offset: body_open_offset,

                cyclomatic_cc: cyclomatic,
                cognitive_cc:  cognitive,
                effective_cc:  effective_cc,
                max_depth:     max_depth,
                match_blocks:  match_count,
                match_arms:    match_arms_count,
                loops_count:   loops_count,
                guards_count:  guards_count,

                first_branch:     first_branch_idx,
                branch_count:     total_fn_branches,
                covered_branches: 0,
                cov_branch:       0.0,

                total_bce_keep:     0,
                total_bce_elide:    0,
                uncovered_bce_keep: 0,
                total_ovf_ops:      total_ovf,
                uncovered_ovf_ops:  0,
                specs_count:        0,
                max_spec_nodes:     0,
                compiler_nest:      0,
                has_noinline:       false,

                trust_class:            trust_class,
                taint_depth:            if trust_class == TRUST_UNTRUSTED { 0 } else { -1 },
                takes_wire_slice:       takes_wire_slice,
                is_generic:             is_generic,
                uninstantiated_generic: false,
                ignored:                is_ignored,

                classic_crap:  0.0,
                risk_struct:   0.0,
                risk_safety:   0.0,
                g_crap:        0.0,
                fuzz_priority: 0.0,
                archetype:     ARCHETYPE_LOW_PRIORITY,
            });

            tok_idx = fn_open_tok + 1;
            continue;
        }

        tok_idx++;
    }
}

// Iterative BFS over the interprocedural call graph to propagate untrusted taint.
fn propagate_trust_taint(
    functions: FunctionInfo[>..]&,
    calls:     const CallSite[:],
    pool:      const u8[:],
) {
    var queue: i32[>..] = [];

    // 1. Seed queue with initial untrusted roots
    for fi in functions.len {
        if functions[fi].trust_class == TRUST_UNTRUSTED {
            functions[fi].taint_depth = 0;
            queue.push(fi as i32);
        }
    }

    // 2. Iterative BFS over call graph
    var head: i64 = 0;
    while head < queue.len {
        let u_idx = queue[head];
        head++;
        let u_depth = functions[u_idx as i64].taint_depth;
        let caller_qname = pool_slice(pool, functions[u_idx as i64].qual_off, functions[u_idx as i64].qual_len);
        let caller_colons = slice_index_of(caller_qname, "::");
        let caller_ns = if caller_colons > 0 { caller_qname[..caller_colons] } else { "" };

        for ci in calls.len {
            let c = calls[ci];
            if c.caller_idx == u_idx {
                let callee_name = pool_slice(pool, c.callee_name_off, c.callee_name_len);
                let is_qual_call = slice_index_of(callee_name, "::") >= 0;

                // Pass 1: Prefer exact qualified name or same-namespace non-ignored callee
                var matched_any = false;
                for fi in functions.len {
                    if functions[fi].ignored { continue; }
                    let s_name = pool_slice(pool, functions[fi].name_off, functions[fi].name_len);
                    let q_name = pool_slice(pool, functions[fi].qual_off, functions[fi].qual_len);
                    let f_colons = slice_index_of(q_name, "::");
                    let f_ns = if f_colons > 0 { q_name[..f_colons] } else { "" };

                    let exact_match = if is_qual_call {
                        callee_name == q_name
                    } else {
                        callee_name == s_name && f_ns == caller_ns
                    };

                    if exact_match {
                        matched_any = true;
                        let next_depth = u_depth + 1;
                        if functions[fi].trust_class != TRUST_UNTRUSTED {
                            functions[fi].trust_class = TRUST_UNTRUSTED;
                            functions[fi].taint_depth = next_depth;
                            queue.push(fi as i32);
                        } else if functions[fi].taint_depth < 0 || next_depth < functions[fi].taint_depth {
                            functions[fi].taint_depth = next_depth;
                            queue.push(fi as i32);
                        }
                    }
                }

                // Pass 2: Fallback to any non-ignored callee matching short or qualified name
                if !matched_any {
                    for fi in functions.len {
                        if functions[fi].ignored { continue; }
                        let s_name = pool_slice(pool, functions[fi].name_off, functions[fi].name_len);
                        let q_name = pool_slice(pool, functions[fi].qual_off, functions[fi].qual_len);

                        if callee_name == s_name || callee_name == q_name {
                            let next_depth = u_depth + 1;
                            if functions[fi].trust_class != TRUST_UNTRUSTED {
                                functions[fi].trust_class = TRUST_UNTRUSTED;
                                functions[fi].taint_depth = next_depth;
                                queue.push(fi as i32);
                            } else if functions[fi].taint_depth < 0 || next_depth < functions[fi].taint_depth {
                                functions[fi].taint_depth = next_depth;
                                queue.push(fi as i32);
                            }
                        }
                    }
                }
            }
        }
    }
}
