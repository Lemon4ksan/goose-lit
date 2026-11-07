// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// wire/mutate.goose - High-speed zero-allocation binary mutator and fuzz harness.
namespace lit;

import std;
import sys.bytes;

// Fast deterministic 64-bit pseudo-random number generator
fn xorshift64_step(state: u64&) -> u64 {
    var x = state;
    if x == 0 {
        x = 0x9E3779B97F4A7C15;
    }
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state = x;
    return x;
}

// Applies one randomized mutation to a clone of the payload buffer:
// 0: single bit flip
// 1: boundary byte injection (0x00, 0xFF, 0x7F, 0x80)
// 2: 16-bit extreme injection (0xFFFF, 0x7FFF, 0x8000, 0x0000)
// 3: 32-bit extreme injection (0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x00000000)
// 4: byte swap or bit flip fallback
fn mutate_payload_once(buf: u8[>..]&, rng: u64&) {
    let n = buf.len;
    guard n > 0 else { return; }

    let mode = xorshift64_step(rng) % 5;

    if mode == 0 {
        // Bit flip
        let pos = (xorshift64_step(rng) % (n as! u64)) as! i64;
        let bit = (1 << ((xorshift64_step(rng) % 8) as u32)) as u8;
        buf[pos] ^= bit;
    } else if mode == 1 {
        // Boundary byte
        let pos = (xorshift64_step(rng) % (n as! u64)) as! i64;
        let choice = xorshift64_step(rng) % 4;
        let b: u8 = if choice == 0 { 0x00 } else if choice == 1 { 0xFF } else if choice == 2 { 0x7F } else { 0x80 };
        buf[pos] = b;
    } else if mode == 2 && n >= 2 {
        // 16-bit extreme
        let pos = (xorshift64_step(rng) % ((n - 1) as! u64)) as! i64;
        let choice = xorshift64_step(rng) % 4;
        if choice == 0 {
            buf[pos] = 0xFF; buf[pos + 1] = 0xFF;
        } else if choice == 1 {
            buf[pos] = 0x7F; buf[pos + 1] = 0xFF;
        } else if choice == 2 {
            buf[pos] = 0x80; buf[pos + 1] = 0x00;
        } else {
            buf[pos] = 0x00; buf[pos + 1] = 0x00;
        }
    } else if mode == 3 && n >= 4 {
        // 32-bit extreme
        let pos = (xorshift64_step(rng) % ((n - 3) as! u64)) as! i64;
        let choice = xorshift64_step(rng) % 4;
        if choice == 0 {
            buf[pos] = 0xFF; buf[pos + 1] = 0xFF; buf[pos + 2] = 0xFF; buf[pos + 3] = 0xFF;
        } else if choice == 1 {
            buf[pos] = 0x7F; buf[pos + 1] = 0xFF; buf[pos + 2] = 0xFF; buf[pos + 3] = 0xFF;
        } else if choice == 2 {
            buf[pos] = 0x80; buf[pos + 1] = 0x00; buf[pos + 2] = 0x00; buf[pos + 3] = 0x00;
        } else {
            buf[pos] = 0x00; buf[pos + 1] = 0x00; buf[pos + 2] = 0x00; buf[pos + 3] = 0x00;
        }
    } else {
        if n >= 2 {
            let p1 = (xorshift64_step(rng) % (n as! u64)) as! i64;
            let p2 = (p1 + 1 + ((xorshift64_step(rng) % ((n - 1) as! u64)) as! i64)) % n;
            if buf[p1] != buf[p2] {
                let tmp = buf[p1];
                buf[p1] = buf[p2];
                buf[p2] = tmp;
            } else {
                let bit = (1 << ((xorshift64_step(rng) % 8) as u32)) as u8;
                buf[p1] ^= bit;
            }
        } else {
            let bit = (1 << ((xorshift64_step(rng) % 8) as u32)) as u8;
            buf[0] ^= bit;
        }
    }
}

// Runs iterative mutation fuzzing on a seed packet using a caller-provided target function.
// The target function must accept const u8[:] and return true if safely processed/rejected.
// Returns false immediately if target reports failure or crashes.
fn fuzz_payload_stream<F: fn(const u8[:]) -> bool>(
    seed:     const u8[:],
    runs:     i64,
    out_diag: u8[>..]&,
) -> bool {
    guard seed.len > 0 else {
        out_diag.append("fuzz_payload_stream: seed is empty\n");
        return false;
    }
    guard runs > 0 else {
        out_diag.append("fuzz_payload_stream: runs must be > 0\n");
        return false;
    }

    var rng:     u64     = 0x9E3779B97F4A7C15;
    var mut_buf: u8[>..] = [];

    var it: i64 = 0;
    while it < runs {
        mut_buf.clear();
        mut_buf.append(seed);

        // Apply 1 to 3 mutations
        let mut_count = 1 + (xorshift64_step(rng) % 3);
        for _ in mut_count {
            mutate_payload_once(mut_buf, rng);
        }

        let ok = F(mut_buf[..]);
        if !ok {
            out_diag.append("MUTATE_FUZZ FAILED on iteration ");
            format(out_diag, it + 1, "/", runs, "\n");
            out_diag.append("  Mutated payload hex: ");
            for b in mut_buf {
                let hex_chars = "0123456789ABCDEF";
                out_diag.push(hex_chars[((b >> 4) & 0xF) as! i64]);
                out_diag.push(hex_chars[(b & 0xF) as! i64]);
            }
            out_diag.append("\n");
            return false;
        }

        it += 1;
    }

    out_diag.append("MUTATE_FUZZ PASSED: ");
    format(out_diag, runs);
    out_diag.append(" iterations completed without violations\n");
    return true;
}
