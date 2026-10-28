// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/inspect_test.goose - Verifies hex dump formatting and 128-bit SIMD lane inspection.
// RUN: goose %s | %FileCheck %s
import std;
import lit from "..";

fn main() {
    let sample = "GET /api/v2/orders HTTP/1.1\r\n";

    // Format hex dump
    var dump_out: u8[>..] = [];
    lit::format_hexdump(sample, 0x1000, dump_out);
    print(dump_out[..]);

    // Format 128-bit SIMD lane inspection for '/' (ASCII 47)
    var simd_out: u8[>..] = [];
    let mask = lit::format_simd_lanes(sample, 47, 0x1000, simd_out);
    print(simd_out[..]);
    print("RETURNED_MASK: ", mask);
}

// CHECK: [0x1000]  47 45 54 20 2F 61 70 69  2F 76 32 2F 6F 72 64 65  |GET /api/v2/orde|
// CHECK-NEXT: [0x1010]  72 73 20 48 54 54 50 2F  31 2E 31 0D 0A           |rs HTTP/1.1..|
// CHECK: 128-bit SIMD Window [0x1000..+16B] target=0x2F ('/')
// CHECK: Match: [ .  .  .  .  *  .  .  .  *  .  .  *  .  .  .  .]
// CHECK: SIMD bitmask: 2320 (0x0910) -> 3 lane match(es)
// CHECK: RETURNED_MASK: 2320
