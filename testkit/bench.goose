// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// testkit/bench.goose - Microbenchmark harness, latency budget gates, and parity verifier.
namespace lit;

import std;
import core.time;
import core.bytes;

// Verifies that average execution time does not exceed the specified nanosecond budget.
fn verify_latency_budget<F: fn()>(
    iterations:    i64,
    max_ns_per_op: i64,
    out_diag:      u8[>..]&,
) -> bool {
    guard iterations > 0 else {
        out_diag.append("verify_latency_budget: iterations must be > 0\n");
        return false;
    }

    // Warm-up pass
    let warmup = if iterations > 100 { 100 } else { iterations };
    for _ in warmup {
        F();
    }

    let t0 = monotonic_now().nanos;
    for _ in iterations {
        F();
    }
    let t1 = monotonic_now().nanos;

    let total_ns = (t1 - t0) as! i64;
    let avg_ns = if total_ns > 0 { total_ns / iterations } else { 0 };

    out_diag.append("BENCH: ");
    format(out_diag, iterations, " iters, avg = ", avg_ns, " ns/op (budget <= ", max_ns_per_op, " ns/op)\n");

    if avg_ns > max_ns_per_op {
        out_diag.append("LATENCY BUDGET EXCEEDED: measured ");
        format(out_diag, avg_ns, " ns/op > ceiling ");
        format(out_diag, max_ns_per_op, " ns/op\n");
        return false;
    }

    return true;
}

// Verifies bit-exact output parity between two function implementations over an input slice.
fn verify_slice_parity<F1: fn(const u8[:]) -> i64, F2: fn(const u8[:]) -> i64>(
    input:    const u8[:],
    out_diag: u8[>..]&,
) -> bool {
    let r1 = F1(input);
    let r2 = F2(input);

    if r1 != r2 {
        out_diag.append("PARITY MISMATCH: baseline returned ");
        format(out_diag, r1, ", candidate returned ");
        format(out_diag, r2, " for input len=");
        format(out_diag, input.len, "\n");
        return false;
    }

    out_diag.append("PARITY OK: bit-exact match (res=");
    format(out_diag, r1, ")\n");
    return true;
}
