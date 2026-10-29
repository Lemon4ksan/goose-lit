// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: echo hello | %FileCheck %s
// XFAIL: *
import std;

fn main() {
    print("This test fails on purpose to verify XFAIL");
}

// CHECK: NONEXISTENT_PATTERN_THAT_FAILS
