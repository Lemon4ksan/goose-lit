// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/alloc_test.goose - Verifies runtime allocation counter, %alloc_hook
// interposition, data-stack growth watermarks, and verify_zero_allocs.
//
// RUN: goose build --cc gcc -O2 --include %alloc_hook -o %t.exe %s && %t.exe | %FileCheck %s
// CHECK: ALLOC_NOTE_TAP: OK
// CHECK: ALLOC_POOL_INTERPOSE: OK
// CHECK: ALLOC_GROWTH_WATERMARK: OK
// CHECK: VERIFY_ZERO_ALLOCS: OK

import std;
import slice_pool;
import lit from "..";

fn test_note_tap() {
    lit::alloc_reset();
    assert(lit::alloc_events() == 0 && lit::alloc_bytes() == 0);

    lit::alloc_note(64);
    lit::alloc_note(16);
    assert(lit::alloc_events() == 2 && lit::alloc_bytes() == 80);

    lit::alloc_disable();
    lit::alloc_note(1);
    assert(lit::alloc_events() == 2 && lit::alloc_bytes() == 80);
    print("ALLOC_NOTE_TAP: OK");
}

fn test_interposed_pool_counting() {
    var pool = slice_pool<u8> {};
    lit::alloc_reset();

    let a = pool.alloc_slice(4);
    let b = pool.alloc_slice(4);
    assert(a.len == 4 && b.len == 4 && lit::alloc_events() == 0);

    pool.free_slice(a);
    assert(lit::alloc_frees() == 1);

    let c = pool.alloc_slice(2);
    assert(c.len == 2 && lit::alloc_events() == 1 && lit::alloc_bytes() == 2);

    pool.free_slice(c);
    assert(lit::alloc_frees() == 2);
    print("ALLOC_POOL_INTERPOSE: OK");
}

fn test_growth_watermark() {
    var probe: u8[>..] = [];
    lit::alloc_reset();

    let mark = lit::alloc_mark(probe);
    assert(lit::alloc_growth(probe, mark) == 0);

    probe.push(65);
    probe.push(66);
    assert(lit::alloc_growth(probe, mark) == 2);
    print("ALLOC_GROWTH_WATERMARK: OK");
}

fn test_verify_zero_allocs() {
    var probe: u8[>..] = [];
    var diag:  u8[>..] = [];
    var acc:   i64     = 0;

    let ok = lit::verify_zero_allocs(probe, diag) {
        for i in 100 {
            acc += i;
        }
    };
    assert(ok && acc == 4950);
    print("VERIFY_ZERO_ALLOCS: OK");
}

fn main() {
    test_note_tap();
    test_interposed_pool_counting();
    test_growth_watermark();
    test_verify_zero_allocs();
}
