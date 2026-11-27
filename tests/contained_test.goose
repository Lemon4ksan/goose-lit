// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/contained_test.goose - Verifies contained-thread panic/abort sandboxing in compiled mode.
// RUN: goose build -O0 %s -o %t && %t | %FileCheck %s
import std;
import lit from "..";

thread_fn clean_worker(_: i64) {
    let x = 2 + 2;
    assert(x == 4);
}

thread_fn abort_worker(_: i64) {
    assert(false);
}

fn main() {
    var diag: u8[>..] = [];
    let w1 = thread_spawn_contained(clean_worker, 0);
    assert(lit::wait_contained_result(w1, diag));

    let w2 = thread_spawn_contained(abort_worker, 0);
    assert(lit::expect_contained_abort(w2, "assert", diag));

    print("CONTAINED_SANDBOX: OK");
}

// CHECK: CONTAINED_SANDBOX: OK
