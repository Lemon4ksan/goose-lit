// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// wire/edge.goose - Page-edge layout and fragmented packet stream verification.
// Conforms to Goose binary slice ABI (const u8[:]).
namespace lit;

import std;
import sys.bytes;

const VIRTUAL_PAGE_SIZE: i64 = 65536;

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
    var p_len: i64 = 1;
    while p_len < total_len {
        let prefix = full_payload[..p_len];
        let code = F(prefix);
        if code != incomplete_code {
            out_diag.append("SPLIT_CHECK FAILED at prefix length ");
            format(out_diag, p_len, "/", total_len, ": returned ");
            format(out_diag, code, ", expected incomplete code ");
            format(out_diag, incomplete_code, "\n");
            return false;
        }
        p_len += 1;
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
    format(out_diag, if total_len > 1 { total_len - 1 } else { 0 });
    out_diag.append(" prefixes returned incomplete code ");
    format(out_diag, incomplete_code);
    out_diag.append(", full packet returned ok code ");
    format(out_diag, ok_code, "\n");
    return true;
}

// Parses hex string or quoted ASCII into a byte buffer.
fn parse_packet_payload(input_str: const u8[:], out_bytes: u8[>..]&) -> bool {
    let s = crap::trim_ascii(input_str);
    guard s.len > 0 else { return false; }
    out_bytes.clear();

    if s.len >= 2 && s[0] == '"' && s[s.len - 1] == '"' {
        let inner = s[1..s.len - 1];
        var i: i64 = 0;
        while i < inner.len {
            let b = inner[i];
            if b == '\\' && i + 1 < inner.len {
                let nb = inner[i + 1];
                if nb == 'n' { out_bytes.push(10); i += 2; }
                else if nb == 'r' { out_bytes.push(13); i += 2; }
                else if nb == 't' { out_bytes.push(9); i += 2; }
                else if nb == '0' { out_bytes.push(0); i += 2; }
                else if nb == '\\' { out_bytes.push(92); i += 2; }
                else if nb == '"' { out_bytes.push(34); i += 2; }
                else { out_bytes.push(nb); i += 2; }
            } else {
                out_bytes.push(b);
                i += 1;
            }
        }
        return out_bytes.len > 0;
    }

    var clean = s;
    if clean.len >= 2 && clean[0] == '0' && (clean[1] == 'x' || clean[1] == 'X') {
        clean = clean[2..];
    }

    var i: i64 = 0;
    while i < clean.len {
        if clean[i] == ' ' || clean[i] == '\t' || clean[i] == '\r' || clean[i] == '\n' {
            i += 1;
            continue;
        }
        if i + 1 >= clean.len { break; }

        var h0: u8 = 0;
        var h1: u8 = 0;
        let c0 = clean[i];
        let c1 = clean[i + 1];

        if c0 >= '0' && c0 <= '9' { h0 = c0 - '0'; }
        else if c0 >= 'a' && c0 <= 'f' { h0 = c0 - 'a' + 10; }
        else if c0 >= 'A' && c0 <= 'F' { h0 = c0 - 'A' + 10; }
        else { break; }

        if c1 >= '0' && c1 <= '9' { h1 = c1 - '0'; }
        else if c1 >= 'a' && c1 <= 'f' { h1 = c1 - 'a' + 10; }
        else if c1 >= 'A' && c1 <= 'F' { h1 = c1 - 'A' + 10; }
        else { break; }

        out_bytes.push((h0 << 4) | h1);
        i += 2;
    }

    return out_bytes.len > 0;
}
