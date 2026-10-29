// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: echo hello | %FileCheck %s
// REQUIRES: nonexistent_hardware_feature
import std;

fn main() {
    print("Should be skipped");
}

// CHECK: hello
