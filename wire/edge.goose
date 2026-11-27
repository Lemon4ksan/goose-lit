// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// wire/edge.goose - Page-edge layout and fragmented packet stream verification.
// Conforms to Goose binary slice ABI (const u8[:]).
namespace lit;

import std;

const VIRTUAL_PAGE_SIZE: i64 = 65536;

inline fn lit_internal::is_ascii_space(b: u8) -> bool {
    return b == ' ' || b == '\t' || b == '\r' || b == '\n';
}

fn lit_internal::trim_ascii(s: const u8[:]) -> const u8[:] {
    var cur = s;
    while cur.len > 0 && lit_internal::is_ascii_space(cur[0]) {
        cur = cur[1..];
    }
    while cur.len > 0 && lit_internal::is_ascii_space(cur[cur.len - 1]) {
        cur = cur[..cur.len - 1];
    }
    return cur;
}

inline fn lit_internal::hex_nibble_val(c: u8) -> i32 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// Verifies that a decoder/parser handles all fragmented stream prefixes gracefully.
// For any prefix of length 1..total_len, invokes prefix_checker(prefix).
// Expects prefix_checker to return incomplete_code and not abort or crash.
// Finally verifies the full payload against ok_code.
fn verify_split_stream<F: fn(const u8[:]) -> i64>(
    full_payload:    const u8[:],
    incomplete_code: i64,
    ok_code:         i64,
    out_diag:        u8[>..]&,
) -> bool {
    let total_len = full_payload.len;
    guard total_len > 0 else {
        out_diag.append("verify_split_stream: payload is empty\n");
        return false;
    }

    // Test each prefix 1..(total_len - 1)
    for p_len in 1..total_len {
        let prefix = full_payload[..p_len];
        let code = F(prefix);
        if code != incomplete_code {
            out_diag.append("SPLIT_CHECK FAILED at prefix length ");
            format(out_diag, p_len, "/", total_len, ": returned ");
            format(out_diag, code, ", expected incomplete code ");
            format(out_diag, incomplete_code, "\n");
            return false;
        }
    }

    // Verify full payload
    let full_res = F(full_payload);
    if full_res != ok_code {
        out_diag.append("SPLIT_CHECK FAILED on full payload (len=");
        format(out_diag, total_len, "): returned ");
        format(out_diag, full_res, ", expected ok code ");
        format(out_diag, ok_code, "\n");
        return false;
    }

    out_diag.append("SPLIT_CHECK PASSED: all ");
    format(out_diag, max(0, total_len - 1));
    out_diag.append(" prefixes returned incomplete code ");
    format(out_diag, incomplete_code);
    out_diag.append(", full packet returned ok code ");
    format(out_diag, ok_code, "\n");
    return true;
}

// Parses hex string or quoted ASCII into a byte buffer.
fn parse_packet_payload(input_str: const u8[:], out_bytes: u8[>..]&) -> bool {
    let s = lit_internal::trim_ascii(input_str);
    guard s.len > 0 else { return false; }
    out_bytes.clear();

    if s.len >= 2 && s[0] == '"' && s[s.len - 1] == '"' {
        var inner = s[1..s.len - 1];
        while inner.len > 0 {
            let b = inner[0];
            if b == '\\' && inner.len >= 2 {
                let nb = inner[1];
                if nb == 'n' { out_bytes.push(10); }
                else if nb == 'r' { out_bytes.push(13); }
                else if nb == 't' { out_bytes.push(9); }
                else if nb == '0' { out_bytes.push(0); }
                else if nb == '\\' { out_bytes.push(92); }
                else if nb == '"' { out_bytes.push(34); }
                else { out_bytes.push(nb); }
                inner = inner[2..];
            } else {
                out_bytes.push(b);
                inner = inner[1..];
            }
        }
        return out_bytes.len > 0;
    }

    var clean = s;
    if clean.len >= 2 && clean[0] == '0' && (clean[1] == 'x' || clean[1] == 'X') {
        clean = clean[2..];
    }

    while clean.len > 0 {
        if lit_internal::is_ascii_space(clean[0]) {
            clean = clean[1..];
            continue;
        }
        guard clean.len >= 2 else {
            out_bytes.clear();
            return false;
        }
        let h0 = lit_internal::hex_nibble_val(clean[0]);
        let h1 = lit_internal::hex_nibble_val(clean[1]);
        guard h0 >= 0 && h1 >= 0 else {
            out_bytes.clear();
            return false;
        }
        out_bytes.push(((h0 << 4) | h1) as u8);
        clean = clean[2..];
    }

    return out_bytes.len > 0;
}
