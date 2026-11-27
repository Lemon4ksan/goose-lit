// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// wire/inspect.goose - Hexadecimal and SIMD lane inspection for byte slices.
namespace lit;

import std;

inline fn lit_internal::hex_nibble(v: u8) -> u8 {
    let d = v & 0xF;
    return if d < 10 { '0' + d } else { 'A' + (d - 10) };
}

fn lit_internal::append_hex_addr(addr: u64, out: u8[>..]&) {
    var shift: i64 = 60;
    while shift > 12 && ((addr >> (shift as u64)) & 0xF) == 0 {
        shift -= 4;
    }
    while shift >= 0 {
        out.push(lit_internal::hex_nibble(((addr >> (shift as u64)) & 0xF) as u8));
        shift -= 4;
    }
}

// Formats a byte slice as a hex dump with offsets and ASCII representations.
fn format_hexdump(buf: const u8[:], base_addr: i64, out: u8[>..]&) {
    var rem = buf;
    var offset: i64 = 0;

    while rem.len > 0 {
        let cur_addr = (base_addr as! u64) + (offset as! u64);

        // Address prefix [0x0000]
        out.append("[0x");
        lit_internal::append_hex_addr(cur_addr, out);
        out.append("]  ");

        let row_bytes = if rem.len > 16 { 16 } else { rem.len };
        let row = rem[..row_bytes];

        // Hex bytes (16 columns with middle spacing)
        for i in 0..16 {
            if i < row.len {
                let b = row[i];
                out.push(lit_internal::hex_nibble(b >> 4));
                out.push(lit_internal::hex_nibble(b));
                out.push(' ');
            } else {
                out.append("   ");
            }
            if i == 7 {
                out.push(' ');
            }
        }

        // ASCII sidebar
        out.append(" |");
        for b in row {
            if b >= 32 && b <= 126 {
                out.push(b);
            } else {
                out.push('.');
            }
        }
        out.append("|\n");

        rem = rem[row_bytes..];
        offset += 16;
    }
}

// Inspects a 16-byte slice window for a target byte and calculates the 16-bit match bitmask.
fn format_simd_lanes(buf: const u8[:], target_b: u8, base_addr: i64, out: u8[>..]&) -> u32 {
    let win_len = if buf.len > 16 { 16 } else { buf.len };
    let win = buf[..win_len];

    out.append("128-bit SIMD Window [0x");
    lit_internal::append_hex_addr(base_addr as! u64, out);
    out.append("..+16B] target=0x");
    out.push(lit_internal::hex_nibble(target_b >> 4));
    out.push(lit_internal::hex_nibble(target_b));
    out.append(" ('");
    if target_b >= 32 && target_b <= 126 { out.push(target_b); } else { out.push('?'); }
    out.append("'):\n");

    out.append("  Lanes: [ 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15]\n");

    out.append("  Hex:   [");
    for i in 0..16 {
        if i < win.len {
            let b = win[i];
            out.push(lit_internal::hex_nibble(b >> 4));
            out.push(lit_internal::hex_nibble(b));
        } else {
            out.append("..");
        }
        if i + 1 < 16 { out.push(' '); }
    }
    out.append("]\n");

    out.append("  ASCII: [ ");
    for i in 0..16 {
        if i < win.len {
            let b = win[i];
            if b >= 32 && b <= 126 { out.push(b); } else { out.push('.'); }
        } else {
            out.push('.');
        }
        if i + 1 < 16 { out.append("  "); }
    }
    out.append("]\n");

    var bitmask:       u32 = 0;
    var matches_count: u32 = 0;

    out.append("  Match: [ ");
    for i in 0..16 {
        if i < win.len && win[i] == target_b {
            out.push('*');
            bitmask |= (1 << (i as! u32));
            matches_count += 1;
        } else {
            out.push('.');
        }
        if i + 1 < 16 { out.append("  "); }
    }
    out.append("]\n");

    out.append("  SIMD bitmask: ");
    format(out, bitmask as! i64);
    out.append(" (0x");
    out.push(lit_internal::hex_nibble(((bitmask >> 12) & 0xF) as u8));
    out.push(lit_internal::hex_nibble(((bitmask >> 8) & 0xF) as u8));
    out.push(lit_internal::hex_nibble(((bitmask >> 4) & 0xF) as u8));
    out.push(lit_internal::hex_nibble((bitmask & 0xF) as u8));
    out.append(") -> ");
    format(out, matches_count as! i64);
    out.append(" lane match(es)\n");

    return bitmask;
}
