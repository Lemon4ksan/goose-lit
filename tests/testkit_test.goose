// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/testkit_test.goose - Integrated in-process unit testkit verification.
// RUN: goose %s | %FileCheck %s
import std;
import lit from "..";

struct Person {
    id:   i64,
    age:  i32,
    role: u8[..32] = [],
}

struct SpyParam {
    val: i64 = 0,
}

struct TableRow {
    input:  i64,
    expect: i64,
}

fn test_basic_assertions(t: lit::T&) {
    lit::assert_true(t, 1 == 1, "equality holds");
    lit::assert_false(t, 1 == 2, "inequality holds");
    lit::assert_ok(t, true);
    lit::assert_eq(t, 40 + 2, 42, "sum 42");
    lit::assert_ne(t, 10, 20);
    lit::assert_gt(t, 100, 50);
    lit::assert_ge(t, 50, 50);
    lit::assert_lt(t, 25, 30);
    lit::assert_le(t, 30, 30);
    lit::assert_in_delta(t, 3.14159, 3.14, 0.01);

    let hello: const u8[:] = "hello world";
    lit::assert_contains(t, hello, "world");
    lit::assert_not_contains(t, hello, "galaxy");

    let bytes_a: const u8[:] = "header: content";
    let bytes_b: const u8[:] = "header: content";
    lit::assert_bytes_eq(t, bytes_a, bytes_b);

    var p1 = Person { id: 1, age: 30, role: [] };
    p1.role.append("admin");
    var p2 = Person { id: 1, age: 30, role: [] };
    p2.role.append("admin");
    lit::assert_struct_eq(t, p1, p2);

    let nums_a = [3, 1, 4, 1, 5];
    let nums_b = [1, 5, 3, 4, 1];
    lit::assert_elements_match(t, nums_a[..], nums_b[..]);

    lit::require_true(t, true);
    lit::require_false(t, false);
    lit::require_ok(t, true);
    lit::require_eq(t, nums_a.len, 5);
    lit::require_bytes_eq(t, bytes_a, bytes_b);
    lit::require_ne(t, 1, 2);
    lit::require_gt(t, 5, 2);
    lit::require_ge(t, 5, 5);
    lit::require_lt(t, 2, 5);
    lit::require_le(t, 5, 5);

    lit::assert_true(t, lit::is_ok(t));
    lit::assert_true(t, lit::is_passed(t));
    lit::assert_false(t, lit::is_failed(t));
    lit::assert_false(t, lit::is_aborted(t));
    lit::assert_false(t, lit::is_skipped(t));
    lit::assert_gt(t, lit::count(t), 0);
    lit::assert_eq(t, lit::failures_len(t), 0);

    var scratch_t = lit::new_test("scratch_lifecycle");
    lit::fail_now(scratch_t, "boom", "detail");
    lit::assert_true(t, lit::is_failed(scratch_t) && lit::is_aborted(scratch_t));
    lit::assert_eq(t, lit::failures_len(scratch_t), 1);

    var skip_t = lit::new_test("scratch_skip");
    lit::skip(skip_t, "not applicable");
    lit::assert_true(t, lit::is_skipped(skip_t) && lit::is_aborted(skip_t));
}

fn balanced_push_pop(buf: u8[>..]&) {
    buf.push('x');
    buf.pop();
}

fn test_mocks_and_fuzzing(t: lit::T&) {
    // Mock clock
    var clock = lit::new_mock_clock(1000);
    lit::assert_eq(t, clock.now_us, 1000);
    lit::advance_us(clock, 500);
    lit::advance_ms(clock, 5);
    lit::assert_eq(t, clock.now_us, 6500);
    lit::advance_sec(clock, 2);
    lit::assert_eq(t, clock.now_us, 2006500);
    lit::advance_days(clock, 1);
    lit::assert_gt(t, clock.now_us, 2006500);

    // Mock monotonic clock
    var mono = lit::new_mock_mono_clock(500);
    lit::advance_ns(mono, 250);
    lit::assert_eq(t, mono.now_ns, 750);

    // Fuzz RNG
    var rng = lit::new_fuzz_rng(12345);
    let r_val = lit::next_range(rng, 10, 20);
    lit::assert_ge(t, r_val, 10);
    lit::assert_lt(t, r_val, 20);
    let _ = lit::next_bool(rng);
    var rnd_s: u8[..16] = [];
    lit::next_ascii_string(rng, rnd_s, 12);
    lit::assert_eq(t, rnd_s.len, 12);

    // Balanced data-stack check
    var diag:        u8[>..] = [];
    var scratch_arr: u8[>..] = [];
    lit::assert_true(t, lit::assert_balanced(scratch_arr, diag, balanced_push_pop));

    // Test Spy
    var s = lit::spy<SpyParam, bool>(true);
    let ret1 = lit::record_call(s, SpyParam { val: 42 });
    lit::assert_true(t, ret1);
    lit::assert_eq(t, s.call_count, 1);
    lit::assert_eq(t, s.last_args.val, 42);
    lit::reset_spy(s);
    lit::assert_eq(t, s.call_count, 0);
}

fn sub_add_case(sub: lit::T&) {
    lit::assert_eq(sub, 5 + 5, 10);
}

fn sub_table_case(sub: lit::T&, row: const TableRow&, idx: i64) {
    lit::assert_eq(sub, row.input * 2, row.expect);
}

fn test_subtests_and_tables(t: lit::T&) {
    // Subtest
    lit::run(t, "sub_add", sub_add_case);

    // Table-driven subtests
    let rows = [
        TableRow { input: 1, expect: 2 },
        TableRow { input: 3, expect: 6 },
        TableRow { input: 10, expect: 20 },
    ];

    lit::run_table(t, "double_table", rows[..], sub_table_case);
}

fn main() {
    var runner = lit::new_runner("lit_unit_suite", lit::Verbosity.Golden);
    runner.run_case("basic_assertions", test_basic_assertions);
    runner.run_case("mocks_and_fuzzing", test_mocks_and_fuzzing);
    runner.run_case("subtests_and_tables", test_subtests_and_tables);

    let all_passed = runner.finish();
    if all_passed {
        print("ALL_UNIT_TESTS: PASSED");
    }
}

// CHECK: [PASS] basic_assertions
// CHECK: [PASS] mocks_and_fuzzing
// CHECK: [PASS] subtests_and_tables
// CHECK: SUITE: lit_unit_suite | PASS: 3/3 | FAIL: 0
// CHECK: ALL_UNIT_TESTS: PASSED
