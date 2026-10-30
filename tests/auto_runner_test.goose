// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/auto_runner_test.goose - Verifies auto-discovery and execution without // RUN: directive.
import std;
import lit from "..";

fn test_math(t: lit::T&) {
    lit::assert_eq(t, 10 * 10, 100);
}

fn main() {
    var runner = lit::new_runner("auto_runner_suite", lit::Verbosity.Golden);
    runner.run_case("math", test_math);
    let ok = runner.finish();
    assert(ok);
    print("AUTO_RUNNER: SUCCESS");
}

// CHECK: [PASS] math
// CHECK: AUTO_RUNNER: SUCCESS
