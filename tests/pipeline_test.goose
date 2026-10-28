// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/pipeline_test.goose - Verifies lit pipeline execution with %FileCheck.
// RUN: goose %s | %FileCheck %s
import std;

fn main() {
    print("INIT: Starting engine");
    print("CHANNEL: 0x4A status=READY");
    print("METRIC: ops_per_sec=1420000");
    print("DONE: Shutdown cleanly");
}

// CHECK: INIT: Starting engine
// CHECK-NEXT: CHANNEL: 0x4A status=READY
// CHECK-NOT: PANIC
// CHECK: METRIC: ops_per_sec=1420000
// CHECK-NEXT: DONE: Shutdown cleanly
