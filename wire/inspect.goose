// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// wire/inspect.goose - Hexadecimal and SIMD lane inspection for byte slices.
namespace lit;

import std;
import sys.bytes;

// Formats a byte slice as a hex dump with offsets and ASCII representations.
fn format_hexdump(buf: const u8[:], base_addr: i64, out: u8[>..]&) {
    let hex_chars = "0123456789ABCDEF";
    let n = buf.len;
    var offset: i64 = 0;

    while offset < n {
        let cur_addr = base_addr + offset;

        // Address prefix [0x0000]
        out.append("[0x");
        out.push(hex_chars[((cur_addr >> 12) & 0xF) as! i64]);
        out.push(hex_chars[((cur_addr >> 8) & 0xF) as! i64]);
        out.push(hex_chars[((cur_addr >> 4) & 0xF) as! i64]);
        out.push(hex_chars[(cur_addr & 0xF) as! i64]);
        out.append("]  ");

        let row_bytes = if (n - offset) < 16 { n - offset } else { 16 };

        // Hex bytes (16 columns with middle spacing)
        for i: i64 in 0..16 {
            if i < row_bytes {
                let b = buf[offset + i];
                out.push(hex_chars[((b >> 4) & 0xF) as! i64]);
                out.push(hex_chars[(b & 0xF) as! i64]);
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
        for i: i64 in 0..row_bytes {
            let b = buf[offset + i];
            if b >= 32 && b <= 126 {
                out.push(b);
            } else {
                out.push('.');
            }
        }
        out.append("|\n");

        offset += 16;
    }
}

// Inspects a 16-byte slice window for a target byte and calculates the 16-bit match bitmask.
fn format_simd_lanes(buf: const u8[:], target_b: u8, base_addr: i64, out: u8[>..]&) -> u32 {
    let hex_chars = "0123456789ABCDEF";
    let window_len = if buf.len < 16 { buf.len } else { 16 };

    out.append("128-bit SIMD Window [0x");
    out.push(hex_chars[((base_addr >> 12) & 0xF) as! i64]);
    out.push(hex_chars[((base_addr >> 8) & 0xF) as! i64]);
    out.push(hex_chars[((base_addr >> 4) & 0xF) as! i64]);
    out.push(hex_chars[(base_addr & 0xF) as! i64]);
    out.append("..+16B] target=0x");
    out.push(hex_chars[((target_b >> 4) & 0xF) as! i64]);
    out.push(hex_chars[(target_b & 0xF) as! i64]);
    out.append(" ('");
    if target_b >= 32 && target_b <= 126 { out.push(target_b); } else { out.push('?'); }
    out.append("'):\n");

    out.append("  Lanes: [ 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15]\n");

    out.append("  Hex:   [");
    for i: i64 in 0..16 {
        if i < window_len {
            let b = buf[i];
            out.push(hex_chars[((b >> 4) & 0xF) as! i64]);
            out.push(hex_chars[(b & 0xF) as! i64]);
        } else {
            out.append("..");
        }
        if i + 1 < 16 { out.push(' '); }
    }
    out.append("]\n");

    out.append("  ASCII: [ ");
    for i: i64 in 0..16 {
        if i < window_len {
            let b = buf[i];
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
    for i: i64 in 0..16 {
        if i < window_len && buf[i] == target_b {
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
    out.push(hex_chars[((bitmask >> 12) & 0xF) as! i64]);
    out.push(hex_chars[((bitmask >> 8) & 0xF) as! i64]);
    out.push(hex_chars[((bitmask >> 4) & 0xF) as! i64]);
    out.push(hex_chars[(bitmask & 0xF) as! i64]);
    out.append(") -> ");
    format(out, matches_count as! i64);
    out.append(" lane match(es)\n");

    return bitmask;
}
