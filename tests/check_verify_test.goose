// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/check_verify_test.goose - Verifies parallel `check`, `verify`, and `profile --json/--md`.
//
// RUN: %lit check tests/ --filter "*filecheck*" -j 2 | %FileCheck %s
// RUN: %lit verify tests/pipeline_test.goose | %FileCheck --prefix VERIFY %s
// RUN: %lit profile tests/profile_test.goose --cc gcc --benchtime 5 --json %t.json --md %t.md | %FileCheck --prefix PROF %s
// CHECK: [CHECK OK]
// CHECK: Check Summary: 1/1 passed
// VERIFY: VERIFY PASSED.
// PROF: Bench_Sum

import std;

fn main() {
    print("CHECK_VERIFY_TEST_OK");
}
