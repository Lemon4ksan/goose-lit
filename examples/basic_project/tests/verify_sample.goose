// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/verify_sample.goose - Verifies basic_project packet framing using lit and FileCheck.
// RUN: goose %s | %FileCheck %s

import std;
import sample from "..";

fn main() {
    print("INIT: Starting sample packet verification");

    let wire_bytes: u8[..8] = [0x47, 0x57, 1, 2, 0, 0, 0, 4];

    let hdr, ok = sample::parse_header(wire_bytes[..]);
    if !ok {
        print("ERROR: Failed to parse valid packet header");
        return;
    }

    sample::print_packet_summary(hdr);

    let short_bytes: u8[..4] = [0x47, 0x57, 1, 2];
    let short_hdr, short_ok = sample::parse_header(short_bytes[..]);
    if !short_ok {
        print("REJECT: Short packet correctly rejected");
    }

    print("DONE: All sample assertions passed");
}

// CHECK: INIT: Starting sample packet verification
// CHECK-NEXT: PACKET: magic=18263 ver=1 type=2 len=4
// CHECK-NEXT: REJECT: Short packet correctly rejected
// CHECK-NOT: ERROR
// CHECK: DONE: All sample assertions passed
