// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// testkit/profile.goose - Hardware cycle-accurate stage profiler & testing.B benchmark suite.
namespace lit;

import std;

extern fn prof_rdtsc() -> u64 = "lit_rdtsc";
extern fn prof_reset() = "lit_prof_reset";
extern fn prof_record(stage_id: i32, cycles: u64) = "lit_prof_record";
extern fn prof_total_cycles(stage_id: i32) -> u64 = "lit_prof_total_cycles";
extern fn prof_sample_count(stage_id: i32) -> u64 = "lit_prof_sample_count";
extern fn prof_min_cycles(stage_id: i32) -> u64 = "lit_prof_min_cycles";
extern fn prof_max_cycles(stage_id: i32) -> u64 = "lit_prof_max_cycles";
extern fn prof_avg_cycles(stage_id: i32) -> f64 = "lit_prof_avg_cycles";
extern fn prof_print_summary() = "lit_prof_print_summary";

extern fn prof_enter(name: const u8[:]) -> i64 = "lit_prof_enter";
extern fn prof_leave(span_tok: i64) = "lit_prof_leave";
extern fn prof_stage_count() -> i32 = "lit_prof_stage_count";
extern fn prof_find_stage(name: const u8[:]) -> i32 = "lit_prof_find_stage";
extern fn prof_stage_self_cycles(stage_id: i32) -> u64 = "lit_prof_stage_self_cycles";
extern fn prof_stage_p50_cycles(stage_id: i32) -> u64 = "lit_prof_stage_p50_cycles";
extern fn prof_stage_p99_cycles(stage_id: i32) -> u64 = "lit_prof_stage_p99_cycles";
extern fn prof_stage_net_bytes(stage_id: i32) -> i64 = "lit_prof_stage_net_bytes";
extern fn prof_stage_scratch_bytes(stage_id: i32) -> i64 = "lit_prof_stage_scratch_bytes";
extern fn prof_stage_peak_bytes(stage_id: i32) -> i64 = "lit_prof_stage_peak_bytes";
extern fn prof_stage_pool_allocs(stage_id: i32) -> i64 = "lit_prof_stage_pool_allocs";
extern fn prof_stage_pool_frees(stage_id: i32) -> i64 = "lit_prof_stage_pool_frees";

extern fn native_bench_begin_suite(suite_name: const u8[:], default_target_ns: i64) = "lit_bench_begin_suite";
extern fn native_bench_should_run(bench_name: const u8[:]) -> i32 = "lit_bench_should_run";
extern fn native_bench_begin_pass(bench_name: const u8[:], pass_idx: i32, target_ns: i64) -> i64 = "lit_bench_begin_pass";
extern fn native_bench_end_pass(pass_idx: i32, cur_n: i64, target_ns: i64) -> i64 = "lit_bench_end_pass";
extern fn native_bench_reset_timer() = "lit_bench_reset_timer";
extern fn native_bench_stop_timer() = "lit_bench_stop_timer";
extern fn native_bench_start_timer() = "lit_bench_start_timer";
extern fn native_bench_set_bytes(n_bytes: i64) = "lit_bench_set_bytes";
extern fn native_bench_mark_has_sub() = "lit_bench_mark_has_sub";
extern fn native_bench_consume_has_sub() -> i32 = "lit_bench_consume_has_sub";
extern fn native_bench_report_metric(val: f64, unit: const u8[:]) = "lit_bench_report_metric";
extern fn native_bench_commit(bench_name: const u8[:], final_n: i64, bytes_per_op: i64) = "lit_bench_commit";
extern fn native_bench_print_report() = "lit_bench_print_report";

inline fn prof_span<F: fn()>(name: const u8[:]) {
    let tok = prof_enter(name);
    defer prof_leave(tok);
    F();
}

struct Bench {
    name:         u8[..64] = [],
    n:            i64      = 1,
    bytes_per_op: i64      = 0,
    target_ns:    i64      = 50000000,
    pass_kind:    i32      = 0,
}

struct BenchSuite {
    suite_name: u8[..64] = [],
    target_ns:  i64      = 50000000,
}

struct BenchPostPassSchedule {
    steady_state_n: i64 = 1,
    watermark_n:    i64 = 1,
}

fn copy_bounded_name(dst: u8[..64]&, src: const u8[:]) {
    dst.clear();
    let n = min(src.len, dst.cap);
    if n > 0 {
        dst.append(src[..n]);
    }
}

fn append_bounded_name(dst: u8[..64]&, src: const u8[:]) {
    let rem = dst.cap - dst.len;
    let n = min(src.len, rem);
    if n > 0 {
        dst.append(src[..n]);
    }
}

inline fn execute_bench_passes<F: fn(Bench&)>(b: Bench&) {
    var cur_n: i64 = 1;
    while true {
        let _ = native_bench_begin_pass(b.name[..], 0, b.target_ns);
        b.n = cur_n;
        b.pass_kind = 0;
        F(b);
        let res_n = native_bench_end_pass(0, cur_n, b.target_ns);
        if res_n > 0 {
            cur_n = res_n;
            break;
        }
        cur_n = if res_n < 0 { 0 - res_n } else { 1 };
    }

    let schedule = BenchPostPassSchedule { steady_state_n: cur_n, watermark_n: 1 };
    const for <N, A> in fields<BenchPostPassSchedule> {
        let pass_idx: i32 = if N == "steady_state_n" { 1 } else { 2 };
        let pass_n = schedule.A;
        let _ = native_bench_begin_pass(b.name[..], pass_idx, b.target_ns);
        b.n = pass_n;
        b.pass_kind = pass_idx;
        F(b);
        let _ = native_bench_end_pass(pass_idx, pass_n, b.target_ns);
    }
    native_bench_commit(b.name[..], cur_n, b.bytes_per_op);
}

fn new_bench_suite(suite_name: const u8[:], target_ms: i64 = 50) -> BenchSuite {
    let eff_ns = max(target_ms, 1) * 1000000;
    var s = BenchSuite { target_ns: eff_ns, .. };
    copy_bounded_name(s.suite_name, suite_name);
    native_bench_begin_suite(suite_name, eff_ns);
    return s;
}

fn bench<F: fn(Bench&)>(suite: BenchSuite&, case_name: const u8[:]) {
    guard native_bench_should_run(case_name) != 0 else { return; }
    let _ = native_bench_consume_has_sub();
    var b = Bench { target_ns: suite.target_ns, .. };
    copy_bounded_name(b.name, case_name);
    execute_bench_passes(b) { it => F(it); };

    if native_bench_consume_has_sub() != 0 {
        b.n = 0;
        b.pass_kind = 3;
        F(b);
    }
}

fn bench_run<F: fn(Bench&)>(parent: Bench&, sub_name: const u8[:]) {
    if parent.pass_kind != 3 {
        native_bench_mark_has_sub();
        return;
    }
    var full_name: u8[..64] = [];
    copy_bounded_name(full_name, parent.name[..]);
    append_bounded_name(full_name, "/");
    append_bounded_name(full_name, sub_name);
    guard native_bench_should_run(full_name[..]) != 0 else { return; }

    var b = Bench { target_ns: parent.target_ns, .. };
    copy_bounded_name(b.name, full_name[..]);
    execute_bench_passes(b) { it => F(it); };
}

inline fn bench_reset_timer(b: Bench&) {
    let _ = b.n;
    native_bench_reset_timer();
}

inline fn bench_stop_timer(b: Bench&) {
    let _ = b.n;
    native_bench_stop_timer();
}

inline fn bench_start_timer(b: Bench&) {
    let _ = b.n;
    native_bench_start_timer();
}

inline fn bench_set_bytes(b: Bench&, n_bytes: i64) {
    b.bytes_per_op = n_bytes;
    native_bench_set_bytes(n_bytes);
}

inline fn bench_report_metric(b: Bench&, val: f64, unit: const u8[:]) {
    let _ = b.n;
    native_bench_report_metric(val, unit);
}

inline fn finish_bench_suite(suite: const BenchSuite&) {
    let _ = suite.target_ns;
    native_bench_print_report();
}
