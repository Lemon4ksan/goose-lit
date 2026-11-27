// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/swarm_page_fault_cycle1_test.goose
import std;
import cli from "..";

fn test_finding1_analyzer_state_desync(t: lit::T&) {
    let sample_goose = """
        namespace app;

        fn verify_frame<F: fn(i32) -> bool>(wire_buf: const u8[:]) -> bool {
            if check_hdr(Opts { flags: 1 }) {
                return true;
            } else {
                return false;
            }
        }

        fn dispatch_msg(code: i32) -> i32 {
            match make_key(Opts { mode: code }) {
                0 => { return 10; }
                1 => { return 20; }
                _ => { return 30; }
            }
        }
        """;

    var pool:       u8[>..]                 = [];
    var functions:  crap::FunctionInfo[>..] = [];
    var branches:   crap::BranchSite[>..]   = [];
    var call_sites: crap::CallSite[>..]     = [];

    crap::analyze_goose_file_with_calls("app/handler.goose", sample_goose, pool, functions, branches, call_sites);
    lit::assert_eq(t, functions.len, 2);

    let fn_verify = functions[0];
    lit::assert_true(t, fn_verify.takes_wire_slice);
    lit::assert_eq(t, fn_verify.trust_class, crap::TRUST_UNTRUSTED);

    lit::assert_eq(t, fn_verify.branch_count, 3);
    let b_else = branches[fn_verify.first_branch + 2];
    lit::assert_false(t, b_else.needs_synth_else);

    let fn_dispatch = functions[1];
    lit::assert_eq(t, fn_dispatch.match_blocks, 1);
    lit::assert_eq(t, fn_dispatch.match_arms, 3);
    lit::assert_eq(t, fn_dispatch.cyclomatic_cc, 4);
}

fn test_finding2_filecheck_seg_truncation_and_starvation(t: lit::T&) {
    var valid_output:     u8[>..] = [];
    var corrupted_output: u8[>..] = [];
    var check_src:        u8[>..] = [];
    check_src.append("// CHK: ");
    for i in 130 {
        valid_output.push('A');
        if i < 128 {
            corrupted_output.push('A');
        }
        check_src.push('A');
    }
    valid_output.append("B 42\n");
    corrupted_output.append("42\n");
    check_src.append("B {{[0-9]+}}\n");

    var diag_valid: u8[>..] = [];
    let ok_valid = lit::run_filecheck(valid_output[..], check_src[..], "CHK", diag_valid);
    lit::assert_true(t, ok_valid);

    var diag_corrupt: u8[>..] = [];
    let ok_corrupt = lit::run_filecheck(corrupted_output[..], check_src[..], "CHK", diag_corrupt);
    lit::assert_false(t, ok_corrupt);

    let var_output = "OPEN id=777\nprefix_text id=777\n";
    let var_rules = """
        // CHK: OPEN id=[[SID:[0-9]+]]
        // CHK: {{.*}}[[SID]]
        """;
    var diag_var: u8[>..] = [];
    let ok_var = lit::run_filecheck(var_output, var_rules, "CHK", diag_var);
    lit::assert_true(t, ok_var);

    let cls_output = "token=99999\n";
    let cls_rules = "// CHK: token={{[abc]+}}\n";
    var diag_cls: u8[>..] = [];
    let ok_cls = lit::run_filecheck(cls_output, cls_rules, "CHK", diag_cls);
    lit::assert_false(t, ok_cls);
}

fn test_finding3_filecheck_not_boundary_desync(t: lit::T&) {
    let same_line_out = "status: FATAL_ERROR [done]\n";
    let same_line_rules = """
        // CHK: status:
        // CHK-NOT: FATAL_ERROR
        // CHK-SAME: [done]
        """;
    var diag_same: u8[>..] = [];
    let ok_same = lit::run_filecheck(same_line_out, same_line_rules, "CHK", diag_same);
    lit::assert_false(t, ok_same);

    let next_out = "header\nbody_ok\ntrailing_FORBIDDEN_after_next\n";
    let next_rules = """
        // CHK: header
        // CHK-NOT: FORBIDDEN
        // CHK-NEXT: body_ok
        """;
    var diag_next: u8[>..] = [];
    let ok_next = lit::run_filecheck(next_out, next_rules, "CHK", diag_next);
    lit::assert_true(t, ok_next);
}

fn test_finding4_sys_bytes_bugs(t: lit::T&) {
    var long_dec: u8[>..] = [];
    long_dec.append("1.5");
    for i in 310 {
        long_dec.push('0');
    }
    let parsed_f, ok_f = crap::parse_f64_slice(long_dec[..]);
    lit::assert_true(t, ok_f);
    lit::assert_true(t, parsed_f == 1.5);

    var rel_out: u8[>..] = [];
    crap::to_relative_path("src_backup/module.goose", "src", rel_out);
    lit::assert_true(t, rel_out[..] == "src_backup/module.goose");

    let matched_distinct = crap::paths_match("pkg_a/src/lib.goose", "pkg_b/src/lib.goose");
    lit::assert_false(t, matched_distinct);
}

fn main() {
    var runner = lit::new_runner("swarm_page_fault_cycle1", lit::Verbosity.Verbose);
    runner.run_case("finding1_analyzer_state_desync", test_finding1_analyzer_state_desync);
    runner.run_case("finding2_filecheck_seg_truncation_and_starvation", test_finding2_filecheck_seg_truncation_and_starvation);
    runner.run_case("finding3_filecheck_not_boundary_desync", test_finding3_filecheck_not_boundary_desync);
    runner.run_case("finding4_sys_bytes_bugs", test_finding4_sys_bytes_bugs);
    let ok = runner.finish();
    assert(ok);
}
