// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/fuzz_cli_test.goose - Verifies `goose-lit fuzz` end-to-end compilation
// against shim/fuzz_driver.c with SanitizerCoverage edge feedback and O(n) check.
//
// RUN: %lit fuzz %s --target 0 --runs 500 --check-complexity | %FileCheck %s
// CHECK: OK SANCOV_EXECS: 500
// CHECK: OK COMPLEXITY_GATE passed=1/1

import std;

export fn lit_fuzz_target_count() -> i32 {
    return 1;
}

export fn lit_fuzz_target_name(target_id: i32, dst: u8[:]) -> i32 {
    guard target_id == 0 && dst.len >= 4 else { return 0; }
    dst[0] = 'e';
    dst[1] = 'c';
    dst[2] = 'h';
    dst[3] = 'o';
    return 4;
}

export fn lit_fuzz_test_one(target_id: i32, raw: const u8[:]) -> u64 {
    guard target_id == 0 else { return 0; }
    var h: u64 = 0xCBF29CE484222325;
    for b in raw {
        h ^= b;
        h *= 0x100000001B3;
        if b == 0x5A {
            h ^= 0x9E3779B97F4A7C15;
        }
    }
    return h;
}

fn main() {
    // Entrypoint hook invoked by fuzz_driver.c via goose_init(argc, argv).
}
