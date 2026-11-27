// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Source-to-source branch coverage instrumentor for Goose files.
// Inserts `crap_cov_hit(branch_id)` probes into shadow copies without touching working trees.
namespace crap;

import std;
import sys.bytes;
import crap.ast.model;

let COV_EDIT_SYNTH_ELSE: u8 = 1;
let COV_EDIT_ARM_CLOSE:  u8 = 2;
let COV_EDIT_STMT:       u8 = 3;
let COV_EDIT_ARM_OPEN:   u8 = 4;

struct CovEdit {
    offset:     i32  = 0,
    priority:   i32  = 0,
    kind:       u8   = 0,
    branch_id:  i32  = 0,
    close_semi: bool = false,
}

fn is_ident_byte(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

// Returns true if the expression at `off` starts with a control-flow keyword (`return`, `break`, `continue`).
fn arm_starts_with_cf_stmt(src: const u8[:], off: i64) -> bool {
    var p = off;
    while p < src.len && is_ascii_space(src[p]) {
        p++;
    }
    let rest = src[p..];
    if slice_starts_with(rest, "return") && (rest.len == 6 || !is_ident_byte(rest[6])) {
        return true;
    }
    if slice_starts_with(rest, "break") && (rest.len == 5 || !is_ident_byte(rest[5])) {
        return true;
    }
    if slice_starts_with(rest, "continue") && (rest.len == 8 || !is_ident_byte(rest[8])) {
        return true;
    }
    return false;
}

fn sort_cov_edits(edits: CovEdit[>..]&) {
    for i in 1..edits.len {
        let key = edits[i];
        var j = i - 1;
        while j >= 0 {
            let cur = edits[j];
            let swap = (cur.offset > key.offset) ||
                (cur.offset == key.offset && cur.priority > key.priority);
            if !swap {
                break;
            }
            edits[j + 1] = cur;
            j--;
        }
        edits[j + 1] = key;
    }
}

fn emit_cov_edit(edit: const CovEdit&, file_idx: i32, out: u8[>..]&) {
    if edit.kind == COV_EDIT_SYNTH_ELSE {
        out.append(" else { ::__gcrap_hit_");
        format(out, file_idx);
        out.append("(");
        format(out, edit.branch_id);
        out.append("); }");
        return;
    }
    if edit.kind == COV_EDIT_ARM_OPEN {
        out.append("{ ::__gcrap_hit_");
        format(out, file_idx);
        out.append("(");
        format(out, edit.branch_id);
        out.append("); ");
        return;
    }
    if edit.kind == COV_EDIT_ARM_CLOSE {
        if edit.close_semi {
            out.append("; }");
        } else {
            out.append(" }");
        }
        return;
    }
    out.append(" ::__gcrap_hit_");
    format(out, file_idx);
    out.append("(");
    format(out, edit.branch_id);
    out.append("); ");
}

// Instruments `src` with branch hit probes for `file_branches` into `out`.
// Returns the number of branch probes emitted.
fn instrument_source_file(
    src:           const u8[:],
    file_idx:      i32,
    file_branches: const BranchSite[:],
    out:           u8[>..]&,
) -> i64 {
    if file_branches.len == 0 {
        out.append(src);
        return 0;
    }

    var edits:       CovEdit[>..] = [];
    var probe_count: i64          = 0;

    for bi in file_branches.len {
        let b = file_branches[bi];
        guard b.probe_byte_offset >= 0 && b.probe_byte_offset <= src.len else { continue; }

        if b.needs_synth_else {
            edits.push(CovEdit {
                offset:    b.probe_byte_offset,
                priority:  0,
                kind:      COV_EDIT_SYNTH_ELSE,
                branch_id: b.branch_id,
            });
            probe_count++;
            continue;
        }

        if b.kind == BRANCH_MATCH_ARM && b.body_close_offset > b.probe_byte_offset &&
            b.body_close_offset <= src.len {
            let off_i = b.probe_byte_offset as i64;
            let is_braced = off_i > 0 && src[off_i - 1] == '{';
            if is_braced {
                edits.push(CovEdit {
                    offset:    b.probe_byte_offset,
                    priority:  2,
                    kind:      COV_EDIT_STMT,
                    branch_id: b.branch_id,
                });
            } else {
                edits.push(CovEdit {
                    offset:    b.probe_byte_offset,
                    priority:  3,
                    kind:      COV_EDIT_ARM_OPEN,
                    branch_id: b.branch_id,
                });
                edits.push(CovEdit {
                    offset:     b.body_close_offset,
                    priority:   1,
                    kind:       COV_EDIT_ARM_CLOSE,
                    branch_id:  b.branch_id,
                    close_semi: arm_starts_with_cf_stmt(src, off_i),
                });
            }
            probe_count++;
            continue;
        }

        var off = b.probe_byte_offset;
        if b.kind == BRANCH_GUARD_PASS && off < src.len && src[off] == ';' {
            off += 1;
        }
        edits.push(CovEdit {
            offset:    off,
            priority:  2,
            kind:      COV_EDIT_STMT,
            branch_id: b.branch_id,
        });
        probe_count++;
    }

    if probe_count == 0 {
        out.append(src);
        return 0;
    }

    sort_cov_edits(edits);

    var cursor: i64 = 0;
    for ei in edits.len {
        let ed = edits[ei];
        let ed_off = ed.offset as i64;
        if ed_off > cursor && ed_off <= src.len {
            out.append(src[cursor..ed_off]);
            cursor = ed_off;
        }
        emit_cov_edit(ed, file_idx, out);
    }
    if cursor < src.len {
        out.append(src[cursor..]);
    }

    out.append("\nextern fn ::__gcrap_hit_");
    format(out, file_idx);
    out.append("(id: i32) = \"crap_cov_hit\";\n");
    return probe_count;
}
