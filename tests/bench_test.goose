// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/bench_test.goose - Microbenchmark and parity verifier test.
// RUN: goose %s | %FileCheck %s
import std;
import lit from "..";

fn target_work() {
    var acc: i64 = 0;
    for i in 100 {
        acc += i * 3;
    }
}

fn baseline_parse(buf: const u8[:]) -> i64 {
    var sum: i64 = 0;
    for b in buf {
        sum += b;
    }
    return sum;
}

fn candidate_parse(buf: const u8[:]) -> i64 {
    var sum: i64 = 0;
    for i in buf.len {
        sum += buf[i];
    }
    return sum;
}

fn main() {
    // 1. Latency budget check (1000000 ns per op is a generous ceiling)
    var bench_diag: u8[>..] = [];
    let ok_budget = lit::verify_latency_budget(1000, 1000000, bench_diag, target_work);
    assert(ok_budget);
    print("BENCH_STATUS: OK");

    // 2. Parity check across slices
    let pkt: const u8[:] = "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n";
    var parity_diag: u8[>..] = [];
    let ok_parity = lit::verify_slice_parity(pkt, parity_diag, baseline_parse, candidate_parse);
    assert(ok_parity);
    print("PARITY_STATUS: BIT-EXACT");
}

// CHECK: BENCH_STATUS: OK
// CHECK: PARITY_STATUS: BIT-EXACT
