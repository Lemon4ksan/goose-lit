// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/cov_test.goose - Verifies source-to-source branch instrumentation,
// real `.gcrap-cov` collection, LCOV export, and feeding real coverage to `crap`.
//
// RUN: goose %s
// RUN: %lit cov wire/mutate.goose --tests tests/wire_test.goose --out %t.gcrap-cov --lcov %t.info | %FileCheck %s
// RUN: %lit crap wire/mutate.goose --cov %t.gcrap-cov --no-bce | %FileCheck --prefix CRAP %s
// CHECK: Real Branch Coverage:
// CHECK: Saved profile:
// CHECK: Saved LCOV:
// CRAP: === goose-crap risk radar (G-CRAP) ===
// CRAP: lit::mutate_payload_once
// CRAP: Total branch sites:      40

import std;
import lit from "..";

fn main() {
    let sample: const u8[:] = "fn demo(x: i64) -> i64 {\n    if x > 0 {\n        return 1;\n    }\n    return 0;\n}\n";
    var pool:       u8[>..]                 = [];
    var functions:  crap::FunctionInfo[>..] = [];
    var branches:   crap::BranchSite[>..]   = [];
    var call_sites: crap::CallSite[>..]     = [];
    crap::analyze_goose_file_with_calls("demo.goose", sample, pool, functions, branches, call_sites);
    assert(branches.len >= 3);

    var inst: u8[>..] = [];
    let probes = crap::instrument_source_file(sample, 0, branches[..], inst);
    assert(probes >= 3);
    assert(crap::slice_contains(inst[..], "::__gcrap_hit_0("));
    assert(crap::slice_contains(inst[..], "extern fn ::__gcrap_hit_0(id: i32) = \"crap_cov_hit\";"));
}
