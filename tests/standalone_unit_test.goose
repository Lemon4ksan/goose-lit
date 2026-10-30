// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/standalone_unit_test.goose - Verifies execution of standard unit test without // RUN or // CHECK.
import std;
import lit from "..";

fn test_feature(t: lit::T&) {
    lit::assert_eq(t, 25 * 4, 100);
}

fn main() {
    var runner = lit::new_runner("standalone_suite", lit::Verbosity.Silent);
    runner.run_case("feature", test_feature);
    let ok = runner.finish();
    assert(ok);
}
