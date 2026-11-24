// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s | %FileCheck %s

import std;
import os;
import lit from "..";

fn test_bug1_bridge_bce_guard_depth_hijack_and_colon_drop() {
    let src = "fn packet_handler(buf: const u8[:], idx: i64) -> u8 {\n    guard buf.len > 4 else { return 0; }\n    guard idx >= 0 else { return 0; }\n    if idx > 100 {\n        return buf[idx];\n    }\n    return buf[0];\n}\n";

    var pool:       u8[>..]                 = [];
    var functions:  crap::FunctionInfo[>..] = [];
    var branches:   crap::BranchSite[>..]   = [];
    var call_sites: crap::CallSite[>..]     = [];

    crap::analyze_goose_file_with_calls("test_target.goose", src, pool, functions, branches, call_sites);
    assert(functions.len == 1);

    let bce_blob = "bce-line: test_target.goose:5: 0 elided, 2 kept\n";
    crap::apply_bce_lines_blob(bce_blob, pool, functions, branches);
    assert(functions[0].total_bce_keep == 2);

    var if_then_bce:    i32 = -1;
    var guard_pass_bce: i32 = 0;
    for bi in branches.len {
        if branches[bi].kind == crap::BRANCH_IF_THEN {
            branches[bi].covered = false;
            if_then_bce = branches[bi].bce_keep;
        } else {
            branches[bi].covered = true;
            if branches[bi].kind == crap::BRANCH_GUARD_PASS {
                guard_pass_bce += branches[bi].bce_keep;
            }
        }
    }

    assert(if_then_bce == 2);
    assert(guard_pass_bce == 0);

    var cfg = crap::default_risk_config();
    cfg.has_coverage_profile = true;
    crap::aggregate_coverage_metrics(cfg, functions, branches);
    crap::compute_crap_metrics(cfg, functions, branches);

    assert(functions[0].uncovered_bce_keep == 2);
    assert(functions[0].risk_safety > 0.0);

    var f_out: u8[>..] = [];
    var l_out: i32     = 0;
    var e_out: i32     = 0;
    var k_out: i32     = 0;
    let ok_rel_drive = crap::parse_bce_line("bce-line: ./C:/src/wire.goose:15: 1 elided, 3 kept", f_out, l_out, e_out, k_out);
    f_out.clear();
    let ok_one_char = crap::parse_bce_line("bce-line: a:15: 1 elided, 3 kept", f_out, l_out, e_out, k_out);
    assert(ok_rel_drive);
    assert(ok_one_char);

    print("BUG1_BRIDGE_BCE_FIXED");
}

fn test_bug2_ratchet_bounded_buffer_wildcard_and_rounding_regression() {
    let baseline_path = ".tmp_swarm_ghost_cycle1.baseline";
    var long_path: u8[>..] = [];
    for k in 25 {
        long_path.append("deep_subpackage/");
    }
    long_path.append("module_a.goose");
    assert(long_path.len > 256);

    var base_content: u8[>..] = [];
    base_content.append("# goose-crap baseline v2\n");
    base_content.append(long_path);
    base_content.append(" 10 parse_frame 120.00 5 0.00\n");
    write_file(baseline_path, base_content);

    var pool:      u8[>..]                 = [];
    var functions: crap::FunctionInfo[>..] = [];

    let f_off, f_len = crap::pool_add(pool, "other_dir/module_b.goose");
    let n_off, n_len = crap::pool_add(pool, "parse_frame");
    functions.push(crap::FunctionInfo {
        name_off:           n_off,
        name_len:           n_len,
        qual_off:           n_off,
        qual_len:           n_len,
        file_off:           f_off,
        file_len:           f_len,
        start_line:         99,
        cov_branch:         0.0,
        uncovered_bce_keep: 4,
        g_crap:             100.0,
    });

    var ratchet_out: u8[>..] = [];
    let violations = crap::check_ratchet_gate(baseline_path, pool, functions, 5.0, true, ratchet_out);
    assert(violations == 1);

    functions[0].uncovered_bce_keep = 0;
    functions[0].g_crap = 25.004;
    functions[0].cov_branch = 0.85;

    let saved_ok = crap::save_baseline_file(baseline_path, ".", pool, functions, true);
    assert(saved_ok);

    ratchet_out.clear();
    let self_violations = crap::check_ratchet_gate(baseline_path, pool, functions, 0.0, true, ratchet_out);
    let is_grandfathered = crap::is_grandfathered_in_baseline(baseline_path, pool, functions[0], 0.0, true);
    delete_file(baseline_path);

    assert(self_violations == 0);
    assert(is_grandfathered);

    print("BUG2_RATCHET_WILDCARD_AND_ROUNDING_FIXED");
}

fn test_bug3_lcov_profile_untaken_branch_corruption_and_checksum_drop() {
    let src = "fn check_bounds(buf: const u8[:], x: i64) -> u8 {\n    guard x == 0 else { return buf[x]; }\n    return 0;\n}\n";

    var pool:       u8[>..]                 = [];
    var functions:  crap::FunctionInfo[>..] = [];
    var branches:   crap::BranchSite[>..]   = [];
    var call_sites: crap::CallSite[>..]     = [];

    crap::analyze_goose_file_with_calls("lcov_target.goose", src, pool, functions, branches, call_sites);
    crap::apply_bce_lines_blob("bce-line: lcov_target.goose:2: 0 elided, 1 kept\n", pool, functions, branches);

    let lcov_path = ".tmp_swarm_ghost_cycle1.info";
    let lcov_data = "SF:lcov_target.goose\nBRDA:1,0,0,10\nBRDA:2,0,0,0\nBRDA:2,0,1,10\nend_of_record\n";
    write_file(lcov_path, lcov_data);

    let ok_lcov = crap::load_lcov_profile(lcov_path, pool, functions, branches);
    assert(ok_lcov);

    var cfg = crap::default_risk_config();
    cfg.has_coverage_profile = true;
    crap::aggregate_coverage_metrics(cfg, functions, branches);

    assert(functions[0].cov_branch < 1.0);
    assert(functions[0].uncovered_bce_keep == 1);

    for bi in branches.len {
        branches[bi].hits = 0;
        branches[bi].covered = false;
    }
    let lcov_checksum_data = "SF:lcov_target.goose\nDA:1,10,d41d8cd98f00b204e9800998ecf8427e\nDA:2,10,e2fc714c4727ee9395f324cd2e7f331f\nend_of_record\n";
    write_file(lcov_path, lcov_checksum_data);
    crap::load_lcov_profile(lcov_path, pool, functions, branches);
    delete_file(lcov_path);

    crap::aggregate_coverage_metrics(cfg, functions, branches);
    assert(functions[0].covered_branches > 0);
    assert(functions[0].cov_branch > 0.0);

    print("BUG3_LCOV_CORRUPTION_AND_CHECKSUM_FIXED");
}

fn test_bug4_metrics_archetype_suppression_and_formatter_defects() {
    var pool:      u8[>..]                 = [];
    var functions: crap::FunctionInfo[>..] = [];
    var branches:  crap::BranchSite[>..]   = [];

    let f_off, f_len = crap::pool_add(pool, "dir\"quote/hazard.goose");
    let n_off, n_len = crap::pool_add(pool, "dispatch_table");

    for bi in 100 {
        let is_cov = bi < 99;
        branches.push(crap::BranchSite {
            branch_id:  bi as i32,
            func_idx:   0,
            kind:       crap::BRANCH_MATCH_ARM,
            depth:      2,
            start_line: (bi + 1) as i32,
            end_line:   (bi + 1) as i32,
            bce_keep:   if is_cov { 0 } else { 3 },
            covered:    is_cov,
        });
    }

    functions.push(crap::FunctionInfo {
        func_idx:       0,
        name_off:       n_off,
        name_len:       n_len,
        qual_off:       n_off,
        qual_len:       n_len,
        file_off:       f_off,
        file_len:       f_len,
        start_line:     1,
        end_line:       100,
        cyclomatic_cc:  100,
        effective_cc:   10,
        first_branch:   0,
        branch_count:   100,
        total_bce_keep: 3,
        ignored:        true,
    });

    var cfg = crap::default_risk_config();
    cfg.has_coverage_profile = true;
    crap::aggregate_coverage_metrics(cfg, functions, branches);
    crap::compute_crap_metrics(cfg, functions, branches);

    assert(functions[0].uncovered_bce_keep == 3);
    assert(functions[0].cov_branch == 0.99);
    assert(functions[0].archetype == crap::ARCHETYPE_PANIC_HAZARD);

    var json_out: u8[>..] = [];
    crap::render_json_report(pool, functions, branches, json_out);
    assert(!crap::slice_contains(json_out, "dispatch_table"));

    var md_out: u8[>..] = [];
    crap::render_markdown_report(pool, functions, branches, cfg, md_out);
    assert(!crap::slice_contains(md_out, "### `dispatch_table`"));

    functions[0].ignored = false;
    json_out.clear();
    crap::render_json_report(pool, functions, branches, json_out);
    assert(crap::slice_contains(json_out, "dir\\\"quote/hazard.goose"));

    print("BUG4_METRICS_ARCHETYPE_AND_FORMATTER_FIXED");
}

fn main() {
    test_bug1_bridge_bce_guard_depth_hijack_and_colon_drop();
    test_bug2_ratchet_bounded_buffer_wildcard_and_rounding_regression();
    test_bug3_lcov_profile_untaken_branch_corruption_and_checksum_drop();
    test_bug4_metrics_archetype_suppression_and_formatter_defects();
    print("SWARM_GHOST_METRIC_CYCLE1: ALL 4 BUGS FIXED");
}

// CHECK: BUG1_BRIDGE_BCE_FIXED
// CHECK: BUG2_RATCHET_WILDCARD_AND_ROUNDING_FIXED
// CHECK: BUG3_LCOV_CORRUPTION_AND_CHECKSUM_FIXED
// CHECK: BUG4_METRICS_ARCHETYPE_AND_FORMATTER_FIXED
// CHECK: SWARM_GHOST_METRIC_CYCLE1: ALL 4 BUGS FIXED
