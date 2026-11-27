// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s | %FileCheck %s

import std;
import os;
import cli from "..";

fn test_cycle2_bug1_specs_blob_sname_hijack_and_leaky_state() {
    var pool:      u8[>..]                 = [];
    var functions: crap::FunctionInfo[>..] = [];
    var branches:  crap::BranchSite[>..]   = [];

    let f1_off, f1_len = crap::pool_add(pool, "mod_a.goose");
    let q1_off, q1_len = crap::pool_add(pool, "mod_a::transform");
    let s1_off, s1_len = crap::pool_add(pool, "transform");

    let f2_off, f2_len = crap::pool_add(pool, "mod_b.goose");
    let q2_off, q2_len = crap::pool_add(pool, "mod_b::transform");
    let s2_off, s2_len = crap::pool_add(pool, "transform");

    let q3_off, q3_len = crap::pool_add(pool, "global_entry");

    branches.push(crap::BranchSite {
        branch_id:  0,
        func_idx:   0,
        kind:       crap::BRANCH_FN_ENTRY,
        depth:      1,
        start_line: 1,
        end_line:   5,
        covered:    false,
    });
    branches.push(crap::BranchSite {
        branch_id:  1,
        func_idx:   1,
        kind:       crap::BRANCH_IF_THEN,
        depth:      2,
        start_line: 10,
        end_line:   15,
        bce_keep:   2,
        covered:    false,
    });
    branches.push(crap::BranchSite {
        branch_id:  2,
        func_idx:   2,
        kind:       crap::BRANCH_FN_ENTRY,
        depth:      1,
        start_line: 20,
        end_line:   25,
        covered:    false,
    });

    functions.push(crap::FunctionInfo {
        func_idx:     0,
        name_off:     s1_off,
        name_len:     s1_len,
        qual_off:     q1_off,
        qual_len:     q1_len,
        file_off:     f1_off,
        file_len:     f1_len,
        start_line:   1,
        end_line:     5,
        first_branch: 0,
        branch_count: 1,
        is_generic:   true,
    });
    functions.push(crap::FunctionInfo {
        func_idx:       1,
        name_off:       s2_off,
        name_len:       s2_len,
        qual_off:       q2_off,
        qual_len:       q2_len,
        file_off:       f2_off,
        file_len:       f2_len,
        start_line:     10,
        end_line:       15,
        first_branch:   1,
        branch_count:   1,
        total_bce_keep: 2,
        is_generic:     true,
    });
    functions.push(crap::FunctionInfo {
        func_idx:     2,
        name_off:     q3_off,
        name_len:     q3_len,
        qual_off:     q3_off,
        qual_len:     q3_len,
        file_off:     f2_off,
        file_len:     f2_len,
        start_line:   20,
        end_line:     25,
        first_branch: 2,
        branch_count: 1,
        is_generic:   true,
    });

    let specs_blob = "// spec nodes 450, nest 9, noinline\n// spec inline\nfn transform<i64>(x: i64) -> i64 {\n// spec nodes 120, nest 3\nfn ::global_entry<i64>(x: i64) -> i64 {\n";

    crap::apply_specs_blob(specs_blob, pool, functions);

    assert(functions[0].specs_count == 1);
    assert(functions[0].max_spec_nodes == 0);
    assert(functions[0].compiler_nest == 0);
    assert(!functions[0].uninstantiated_generic);

    assert(functions[1].specs_count == 1);
    assert(!functions[1].uninstantiated_generic);

    assert(functions[2].specs_count == 1);
    assert(functions[2].max_spec_nodes == 120);
    assert(functions[2].compiler_nest == 3);
    assert(!functions[2].uninstantiated_generic);

    var cfg = crap::default_risk_config();
    crap::aggregate_coverage_metrics(cfg, functions, branches);
    crap::compute_crap_metrics(cfg, functions, branches);

    assert(functions[1].uncovered_bce_keep == 2);
    assert(functions[1].archetype == crap::ARCHETYPE_PANIC_HAZARD);

    print("CYCLE2_BUG1_SPECS_HIJACK_AND_LEAK_FIXED");
}

fn test_cycle2_bug2_ratchet_stateless_duplicate_bypass_and_parse_fallback() {
    let v2_path = ".tmp_swarm_ghost_c2_v2.baseline";
    write_file(v2_path, "# goose-crap baseline v2\nexpr.goose 10 eval 80.00 3 0.00\nexpr.goose 50 eval 5.00 0 1.00\n");

    var pool: u8[>..] = [];
    let f_off, f_len = crap::pool_add(pool, "expr.goose");
    let n_off, n_len = crap::pool_add(pool, "eval");

    let regressed_eval_line50 = crap::FunctionInfo {
        name_off:           n_off,
        name_len:           n_len,
        qual_off:           n_off,
        qual_len:           n_len,
        file_off:           f_off,
        file_len:           f_len,
        start_line:         50,
        cov_branch:         0.0,
        uncovered_bce_keep: 3,
        g_crap:             75.0,
    };

    let grandfathered_v2 = crap::is_grandfathered_in_baseline(v2_path, pool, regressed_eval_line50, 5.0, false);
    delete_file(v2_path);
    assert(!grandfathered_v2);

    let v1_path = ".tmp_swarm_ghost_c2_v1.baseline";
    write_file(v1_path, "# goose-crap baseline v1\neval 80.00 3 0.00\n");
    let grandfathered_v1 = crap::is_grandfathered_in_baseline(v1_path, pool, regressed_eval_line50, 5.0, false);
    delete_file(v1_path);
    assert(grandfathered_v1);

    let corrupt_path = ".tmp_swarm_ghost_c2_corrupt.baseline";
    write_file(corrupt_path, "# goose-crap baseline v2\nexpr.goose 10 eval NaN CORRUPT_BCE 0.00\n");
    var funcs: crap::FunctionInfo[>..] = [];
    funcs.push(crap::FunctionInfo {
        name_off:           n_off,
        name_len:           n_len,
        qual_off:           n_off,
        qual_len:           n_len,
        file_off:           f_off,
        file_len:           f_len,
        start_line:         10,
        cov_branch:         0.0,
        uncovered_bce_keep: 1,
        g_crap:             20.0,
    });
    var r_out: u8[>..] = [];
    let corrupt_violations = crap::check_ratchet_gate(corrupt_path, pool, funcs, 5.0, false, r_out);
    delete_file(corrupt_path);
    assert(corrupt_violations == 1);
    assert(!crap::slice_contains(r_out, "increased from 0 to 1"));

    print("CYCLE2_BUG2_RATCHET_STATELESS_AND_FALLBACK_FIXED");
}

fn test_cycle2_bug3_profile_branch_id_desync_and_dead_zero_branch_check() {
    var branches: crap::BranchSite[>..] = [];
    branches.push(crap::BranchSite {
        branch_id: 10,
        func_idx:  0,
        kind:      crap::BRANCH_IF_THEN,
        hits:      0,
        covered:   false,
    });
    branches.push(crap::BranchSite {
        branch_id: 20,
        func_idx:  0,
        kind:      crap::BRANCH_IF_ELSE,
        hits:      0,
        covered:   false,
    });

    let prof_path = ".tmp_swarm_ghost_c2.gcrap-cov";
    write_file(prof_path, "id 10 5\nid 20 18446744073709551615\nid 20 1\n");
    let ok_prof = crap::load_gcrap_profile(prof_path, branches);
    delete_file(prof_path);
    assert(ok_prof);

    assert(branches[0].branch_id == 10);
    assert(branches[0].hits == 5);
    assert(branches[0].covered == true);
    assert(branches[1].branch_id == 20);
    assert(branches[1].hits == 18446744073709551615);
    assert(branches[1].covered == true);

    var functions: crap::FunctionInfo[>..] = [];
    functions.push(crap::FunctionInfo {
        func_idx:         0,
        first_branch:     0,
        branch_count:     0,
        covered_branches: 1,
        cov_branch:       1.0,
    });
    var cfg = crap::default_risk_config();
    cfg.has_coverage_profile = true;
    crap::aggregate_coverage_metrics(cfg, functions, branches);

    assert(functions[0].covered_branches == 1);
    assert(functions[0].cov_branch == 1.0);

    print("CYCLE2_BUG3_PROFILE_DESYNC_AND_DEAD_BRANCH_FIXED");
}

fn test_cycle2_bug4_metrics_safe_primitive_bypass_and_formatter_nan_sort() {
    var pool:      u8[>..]                 = [];
    var functions: crap::FunctionInfo[>..] = [];
    var branches:  crap::BranchSite[>..]   = [];

    let f_off, f_len = crap::pool_add(pool, "math_kernel.goose");
    let n1_off, n1_len = crap::pool_add(pool, "overflow_heavy_kernel");
    let n2_off, n2_len = crap::pool_add(pool, "nan_score_func");

    for bi in 10 {
        let is_cov = bi < 9;
        branches.push(crap::BranchSite {
            branch_id:  bi as i32,
            func_idx:   0,
            kind:       crap::BRANCH_IF_THEN,
            depth:      3,
            start_line: (bi + 1) as i32,
            end_line:   (bi + 1) as i32,
            ovf_ops:    if is_cov { 0 } else { 10 },
            covered:    is_cov,
        });
    }

    functions.push(crap::FunctionInfo {
        func_idx:      0,
        name_off:      n1_off,
        name_len:      n1_len,
        qual_off:      n1_off,
        qual_len:      n1_len,
        file_off:      f_off,
        file_len:      f_len,
        cyclomatic_cc: 19,
        effective_cc:  40,
        first_branch:  0,
        branch_count:  10,
        total_ovf_ops: 10,
    });

    var cfg = crap::default_risk_config();
    cfg.has_coverage_profile = true;
    crap::aggregate_coverage_metrics(cfg, functions, branches);
    crap::compute_crap_metrics(cfg, functions, branches);

    assert(functions[0].g_crap > 450.0);
    assert(functions[0].archetype != crap::ARCHETYPE_SAFE_PRIMITIVE);

    let zero_f:  f64 = 0.0;
    let nan_val: f64 = zero_f / zero_f;
    functions.push(crap::FunctionInfo {
        func_idx: 1,
        name_off: n2_off,
        name_len: n2_len,
        qual_off: n2_off,
        qual_len: n2_len,
        file_off: f_off,
        file_len: f_len,
        g_crap:   nan_val,
    });

    var order: i32[>..] = [];
    crap::sort_functions_by_gcrap(functions, order);
    assert(order.len == 2);
    assert(order[0] == 0);
    assert(order[1] == 1);

    print("CYCLE2_BUG4_SAFE_PRIM_BYPASS_AND_NAN_SORT_FIXED");
}

fn main() {
    test_cycle2_bug1_specs_blob_sname_hijack_and_leaky_state();
    test_cycle2_bug2_ratchet_stateless_duplicate_bypass_and_parse_fallback();
    test_cycle2_bug3_profile_branch_id_desync_and_dead_zero_branch_check();
    test_cycle2_bug4_metrics_safe_primitive_bypass_and_formatter_nan_sort();
    print("SWARM_GHOST_METRIC_CYCLE2: ALL 4 BUGS FIXED");
}

// CHECK: CYCLE2_BUG1_SPECS_HIJACK_AND_LEAK_FIXED
// CHECK: CYCLE2_BUG2_RATCHET_STATELESS_AND_FALLBACK_FIXED
// CHECK: CYCLE2_BUG3_PROFILE_DESYNC_AND_DEAD_BRANCH_FIXED
// CHECK: CYCLE2_BUG4_SAFE_PRIM_BYPASS_AND_NAN_SORT_FIXED
// CHECK: SWARM_GHOST_METRIC_CYCLE2: ALL 4 BUGS FIXED
