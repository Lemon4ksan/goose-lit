// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Source-to-source branch probe instrumentation for Goose codebases.
// Injects `__gcrap_hit(id)` calls into branch entries and synthesizes else blocks
// so branch coverage is accurate even at `-O2` without `#line` or macro distortion.
namespace crap;

import std;
import sys.bytes;
import crap.lexer.scanner;
import crap.ast.model;

struct ProbePoint {
    offset:     i64 = 0,
    prefix_off: i32 = 0,
    prefix_len: i32 = 0,
    id:         i32 = -1,
    suffix_off: i32 = 0,
    suffix_len: i32 = 0,
}

// Instruments a Goose source file, writing the rewritten source into `out_src`.
fn instrument_goose_source(
    src:      const u8[:],
    branches: const BranchSite[:],
    out_src:  u8[>..]&,
    file_id:  i64,
) {
    // 1. Locate insertion point for runtime extern declaration (after file header namespace & imports)
    // Per Goose reference §21 / spec §11.1, declarations (including extern fn) follow namespace and imports.
    var tokens:  Token[>..]      = [];
    var pragmas: LinePragma[>..] = [];
    tokenize_goose(src, tokens, pragmas);

    var extern_insert_pos: i64 = 0;
    var ti:                i64 = 0;
    while ti < tokens.len {
        let tk = tokens[ti].kind;
        if tk == TOK_NAMESPACE || tk == TOK_IMPORT {
            var k = ti + 1;
            while k < tokens.len && tokens[k].kind != TOK_SEMI {
                k++;
            }
            if k < tokens.len && tokens[k].kind == TOK_SEMI {
                extern_insert_pos = tokens[k].start + 1;
                while extern_insert_pos < src.len &&
                      (src[extern_insert_pos] == ' ' || src[extern_insert_pos] == '\t' ||
                       src[extern_insert_pos] == '\r' || src[extern_insert_pos] == '\n') {
                          extern_insert_pos++;
                      }
                ti = k + 1;
                continue;
            }
        }
        break;
    }

    var fn_name: u8[>..] = [];
    fn_name.append("__gcrap_hit");
    if file_id >= 0 {
        fn_name.push('_');
        append_i64(fn_name, file_id);
    }

    out_src.append(src[..extern_insert_pos]);
    out_src.append("\nextern fn ");
    out_src.append(fn_name);
    out_src.append("(id: i32) = \"crap_cov_hit\";\n");

    // 2. Build list of probe injection points
    var probe_pool: u8[>..]         = [];
    var points:     ProbePoint[>..] = [];

    var pfx_std: u8[>..] = [];
    pfx_std.append(" ");
    pfx_std.append(fn_name);
    pfx_std.append("(");
    let pfx_std_off, pfx_std_len = pool_add(probe_pool, pfx_std);
    let sfx_std_off, sfx_std_len = pool_add(probe_pool, "); ");

    var pfx_synth: u8[>..] = [];
    pfx_synth.append(" else { ");
    pfx_synth.append(fn_name);
    pfx_synth.append("(");
    let pfx_synth_off, pfx_synth_len = pool_add(probe_pool, pfx_synth);
    let sfx_synth_off, sfx_synth_len = pool_add(probe_pool, "); } ");

    var pfx_arm: u8[>..] = [];
    pfx_arm.append("{ ");
    pfx_arm.append(fn_name);
    pfx_arm.append("(");
    let pfx_arm_off, pfx_arm_len = pool_add(probe_pool, pfx_arm);
    let sfx_arm_off, sfx_arm_len = pool_add(probe_pool, "); ");

    let pfx_close_off, pfx_close_len = pool_add(probe_pool, " }");
    let sfx_empty_off, sfx_empty_len = pool_add(probe_pool, "");

    for bi in branches.len {
        let b = branches[bi];
        let p_off: i64 = b.probe_byte_offset;
        guard p_off >= extern_insert_pos && p_off <= src.len else { continue; }

        if b.kind == BRANCH_IF_ELSE && b.needs_synth_else {
            points.push(ProbePoint {
                offset:     p_off,
                prefix_off: pfx_synth_off,
                prefix_len: pfx_synth_len,
                id:         b.branch_id,
                suffix_off: sfx_synth_off,
                suffix_len: sfx_synth_len,
            });
        } else if b.kind == BRANCH_MATCH_ARM && b.body_close_offset >= 0 {
            points.push(ProbePoint {
                offset:     p_off,
                prefix_off: pfx_arm_off,
                prefix_len: pfx_arm_len,
                id:         b.branch_id,
                suffix_off: sfx_arm_off,
                suffix_len: sfx_arm_len,
            });
            let c_off: i64 = b.body_close_offset;
            if c_off >= p_off && c_off <= src.len {
                points.push(ProbePoint {
                    offset:     c_off,
                    prefix_off: pfx_close_off,
                    prefix_len: pfx_close_len,
                    id:         -1,
                    suffix_off: sfx_empty_off,
                    suffix_len: sfx_empty_len,
                });
            }
        } else {
            points.push(ProbePoint {
                offset:     p_off,
                prefix_off: pfx_std_off,
                prefix_len: pfx_std_len,
                id:         b.branch_id,
                suffix_off: sfx_std_off,
                suffix_len: sfx_std_len,
            });
        }
    }

    // 3. Sort probe points by offset ascending (insertion sort)
    var i: i64 = 1;
    while i < points.len {
        let key = points[i];
        var j: i64 = i - 1;
        while j >= 0 && points[j].offset > key.offset {
            points[j + 1] = points[j];
            j--;
        }
        points[j + 1] = key;
        i++;
    }

    // 4. Stream source and inject probes
    var cur_pos = extern_insert_pos;

    for pi in points.len {
        let p = points[pi];
        let p_off = p.offset;
        if p_off >= cur_pos && p_off <= src.len {
            out_src.append(src[cur_pos..p_off]);
            cur_pos = p_off;

            let pfx = pool_slice(probe_pool, p.prefix_off, p.prefix_len);
            out_src.append(pfx);

            if p.id >= 0 {
                append_i64(out_src, p.id);
            }

            let sfx = pool_slice(probe_pool, p.suffix_off, p.suffix_len);
            out_src.append(sfx);
        }
    }

    if cur_pos < src.len {
        out_src.append(src[cur_pos..]);
    }
}
