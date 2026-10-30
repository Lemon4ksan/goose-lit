// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: %lit gate %s 50 | %FileCheck %s

import std;
import lit from "..";

fn clean_simple_function(x: i64) -> i64 {
    if x > 10 {
        return x;
    }
    return 0;
}

fn main() {
    let res = clean_simple_function(5);
    assert(res == 0);

    let os_id = crap::native_host_os();
    assert(os_id >= 1 && os_id <= 3);
    let arch_id = crap::native_host_arch();
    assert(arch_id >= 1 && arch_id <= 2);
    let cpus = crap::native_cpu_count();
    assert(cpus >= 1);
}

// CHECK: === Hardware Complexity Gate Evaluation ===
// CHECK: Ceiling: G-CRAP <= 50.0
// CHECK: GATE PASSED: All functions within risk thresholds.
