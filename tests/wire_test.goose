// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/wire_test.goose - Unit tests for packet edge splitting and mutator.
// RUN: goose check %s
import std;
import lit from "..";

fn dummy_decoder(buf: const u8[:]) -> i64 {
    // Packet is complete only when full 6 bytes are available
    if buf.len < 6 {
        return -1; // incomplete
    }
    return 0; // ok
}

fn dummy_safe_processor(buf: const u8[:]) -> bool {
    // Parser must never crash on any arbitrary byte stream
    guard buf.len >= 2 else { return true; }
    let _ = buf[0];
    let _ = buf[1];
    return true;
}

fn main() {
    var raw_pkt: u8[>..] = [];
    let ok_parse = lit::parse_packet_payload("818511223344", raw_pkt);
    assert(ok_parse && raw_pkt.len == 6);

    // Verify split stream prefix slicing
    var split_diag: u8[>..] = [];
    let ok_split = lit::verify_split_stream(raw_pkt[..], -1, 0, split_diag, dummy_decoder);
    if !ok_split {
        print("FAIL: ", split_diag);
        return;
    }

    // Verify fuzz stream
    var fuzz_diag: u8[>..] = [];
    let ok_fuzz = lit::fuzz_payload_stream(raw_pkt[..], 100, fuzz_diag, dummy_safe_processor);
    if !ok_fuzz {
        print("FAIL: ", fuzz_diag);
        return;
    }

    print("Wire self-test passed!");
}
