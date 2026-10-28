// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/filecheck_test.goose - Unit tests for FileCheck engine.
// RUN: goose check %s
import std;
import lit from "..";

fn main() {
    let sample_output = """
        Entering main loop
        Parsed 42 items
        Status: OK
        Leaving main loop
        """;

    let test_file = """
        // CHECK: Entering main loop
        // CHECK-NEXT: Parsed 42 items
        // CHECK-NOT: ERROR
        // CHECK: Status: OK
        // CHECK: Leaving main loop
        """;

    var diag: u8[>..] = [];
    let ok = lit::run_filecheck(sample_output, test_file, "CHECK", diag);
    if !ok {
        print("FAIL: ", diag);
        return;
    }

    print("FileCheck self-test passed!");
}
