// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: %lit gate %s 50 | %FileCheck %s

import std;

fn clean_simple_function(x: i64) -> i64 {
    if x > 10 {
        return x;
    }
    return 0;
}

fn main() {
    let res = clean_simple_function(5);
    assert(res == 0);
}

// CHECK: === Hardware Complexity Gate Evaluation ===
// CHECK: Ceiling: G-CRAP <= 50.0
// CHECK: GATE PASSED: All functions within risk thresholds.
