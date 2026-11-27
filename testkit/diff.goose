// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Structural diff and hexadecimal byte difference formatting for assertion diagnostics.
namespace lit_internal;

import std;

fn append_hex_byte<B>(out: B&, b: u8) {
    let hi = (b >> 4) & 0xF;
    let lo = b & 0xF;
    out.push(if hi < 10 { '0' + hi } else { 'A' + (hi - 10) });
    out.push(if lo < 10 { '0' + lo } else { 'A' + (lo - 10) });
}

// Byte slice differ displaying first mismatch index, hex dump, and ASCII context
fn format_bytes_diff<B>(out: B&, got: const u8[:], want: const u8[:]) {
    out.append("  len: got ");
    format(out, got.len, ", want ", want.len, "\n");
    let min_len = min(got.len, want.len);
    var diff_idx = -1;
    for i in min_len {
        if got[i] != want[i] {
            diff_idx = i;
            break;
        }
    }
    if diff_idx < 0 && got.len != want.len {
        diff_idx = min_len;
    }
    if diff_idx >= 0 {
        format(out, "  first mismatch at byte [", diff_idx, "]:");
        if diff_idx < got.len {
            out.append(" got 0x");
            append_hex_byte(out, got[diff_idx]);
        } else {
            out.append(" got <EOF>");
        }
        if diff_idx < want.len {
            out.append(", want 0x");
            append_hex_byte(out, want[diff_idx]);
        } else {
            out.append(", want <EOF>");
        }
        out.push('\n');
    }
    format(out, "  got:  \"", got, "\"\n  want: \"", want, "\"");
}

// Compile-time struct diff engine utilizing `const for <N, A> in fields<Val>`
fn diff_struct_fields<Val, B>(out: B&, got: const Val&, want: const Val&) -> bool {
    var has_diff = false;
    const for <N, A> in fields<Val> {
        if got.A != want.A {
            has_diff = true;
            out.append("  field '");
            out.append(N);
            out.append("': got ");
            format(out, got.A);
            out.append(", want ");
            format(out, want.A);
            out.push('\n');
        }
    }
    return has_diff;
}
